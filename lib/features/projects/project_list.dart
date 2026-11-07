import 'package:flit/l10n/strings.dart';
import 'package:flutter/foundation.dart';

import '../../services/file_ops.dart';
import '../../services/paths.dart';
import '../../services/shell.dart';
import '../workspace/project_session.dart' show ProjectKind;

/// 工程根下的一个顶层目录。kind 由目录里的 pubspec.yaml 现场判定(与打开后的
/// ProjectSession.kind 同一枚举); 没有 pubspec 的目录 kind 为 null, 仍可作为工作区打开。
class ProjectEntry {
  const ProjectEntry({
    required this.name,
    required this.path,
    required this.kind,
    this.modified,
  });
  final String name;
  final String path;
  final ProjectKind? kind;

  /// 源码树里最新一次改动(排除 build/.dart_tool/.git/.gradle); 空目录为 null
  final DateTime? modified;

  bool get isProject => kind != null;

  String get kindLabel => switch (kind) {
    ProjectKind.flutter => strings.flutterProject,
    ProjectKind.dart => strings.dartProject,
    null => strings.folder,
  };
}

/// 工程目录名校验: 不能含路径分隔符, 不能是 . 或 ..
String? validateProjectName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return strings.nameCannotBeEmpty;
  if (name.contains('/') || name.contains('\\')) {
    return strings.nameCannotContainPathSeparators;
  }
  if (name == '.' || name == '..') return strings.nameCannotBeOr;
  return null;
}

/// 列表副标题用的相对时间
String relativeTime(DateTime time, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(time);
  if (diff.inMinutes < 1) return strings.justNow;
  if (diff.inHours < 1) return strings.pMinutesAgo(diff.inMinutes);
  if (diff.inDays < 1) return strings.pHoursAgo(diff.inHours);
  if (diff.inDays < 30) return strings.pDaysAgo(diff.inDays);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)}';
}

/// 首页工程列表: 只看工程根下一层, 一条 shell 拿齐名字/类型/最近改动。
/// 重命名/删除经 FileOps(shell 侧 realpath 守界), 所有路径由本类拼接。
class ProjectList extends ChangeNotifier {
  ProjectList({required this.root, this.beforeMutation});

  final String root;

  /// 变更前守卫(如: 正打开的工程不许改名/删除), 抛 StateError 即拒绝
  final void Function(String path)? beforeMutation;

  List<ProjectEntry> entries = const [];
  bool loading = false;
  String? error;
  bool _disposed = false;
  int _request = 0;

  /// 一次 shell 调用: 顶层目录 → 类型(pubspec 有无/是否 flutter) → 源码树最新 mtime
  static String scanCommand(String root) {
    final quoted = shQuote(root);
    return 'mkdir -p $quoted && cd $quoted || exit 9\n'
        r"find . -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | sort "
        r'| while IFS= read -r name; do '
        r'kind=folder; '
        r'if [ -f "$name/pubspec.yaml" ]; then kind=dart; '
        r"""grep -qsE '^[[:space:]]*(flutter:|sdk:[[:space:]]*flutter)' "$name/pubspec.yaml" && kind=flutter; """
        r'fi; '
        r'mtime=$(find "$name" \( -name build -o -name .dart_tool -o -name .git -o -name .gradle \) -prune '
        r"-o -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -n 1); "
        r"""printf '%s\t%s\t%s\n' "$name" "$kind" "${mtime%.*}"; """
        'done';
  }

  /// 解析扫描输出(name\tkind\tepoch); 最近改动的在前, 其余按名
  static List<ProjectEntry> parseListing(String output, String root) {
    final list = <ProjectEntry>[];
    for (final raw in output.split('\n')) {
      final parts = raw.replaceAll('\r', '').split('\t');
      if (parts.length < 2 || parts[0].isEmpty) continue;
      // 只认扫描协议里的三种类型, 混进输出的别的行(如警告)直接丢
      final ProjectKind? kind;
      switch (parts[1]) {
        case 'flutter':
          kind = ProjectKind.flutter;
        case 'dart':
          kind = ProjectKind.dart;
        case 'folder':
          kind = null;
        default:
          continue;
      }
      final seconds = parts.length > 2 ? int.tryParse(parts[2]) : null;
      list.add(
        ProjectEntry(
          name: parts[0],
          path: joinPath(root, parts[0]),
          kind: kind,
          modified: seconds == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
        ),
      );
    }
    list.sort((a, b) {
      final am = a.modified, bm = b.modified;
      if (am != null && bm != null && am != bm) return bm.compareTo(am);
      if (am == null && bm != null) return 1;
      if (am != null && bm == null) return -1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final request = ++_request;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final res = await Shell.instance.exec(
        scanCommand(root),
        timeoutMs: 30000,
      );
      if (_disposed || request != _request) return;
      if (res['exitCode'] != 0) {
        error = strings.projectDirectoryIsNotReadable;
        entries = const [];
      } else {
        entries = List.unmodifiable(
          parseListing(res['output'] as String? ?? '', root),
        );
      }
    } catch (e) {
      if (_disposed || request != _request) return;
      error = '$e';
      entries = const [];
    } finally {
      if (!_disposed && request == _request) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> rename(ProjectEntry entry, String newName) => _mutate(
    entry.path,
    () => FileOps.instance.rename(entry.path, newName, allowedRoot: root),
  );

  Future<void> delete(ProjectEntry entry) => _mutate(
    entry.path,
    () => FileOps.instance.delete(entry.path, allowedRoot: root),
  );

  Future<void> _mutate(String path, Future<OpResult> Function() op) async {
    beforeMutation?.call(path);
    final result = await op();
    if (!result.ok) throw StateError(result.msg);
    await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
