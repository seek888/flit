import 'package:flit/l10n/strings.dart';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../services/file_ops.dart';
import '../../services/local_fs.dart';
import '../../services/paths.dart';
import '../../services/shell.dart';
import '../editor/file_kind.dart';
import 'project_documents.dart';

/// Coordinates project mutations with autosave and Git worktree changes, and
/// owns the project's file listing (what the tree shows). Notifies when the
/// listing changes.
class ProjectFiles extends ChangeNotifier {
  ProjectFiles(this.documents);
  final ProjectDocuments documents;
  FileOps get _ops => FileOps.instance;
  String get root => documents.projectPath;

  /// 工程文件清单: 相对路径, 目录带尾斜杠, 已排序; 排除 .dart_tool/build/.git
  List<String> get files => _files;
  List<String> _files = const [];

  int _refreshRequest = 0;

  Future<void> refresh() async {
    final request = ++_refreshRequest;
    final List<String> listing;
    if (isDesktopPlatform) {
      // 桌面端不需要 find -printf: LocalFs 直接遍历（语义与 shim 一致）。
      listing = LocalFs.instance.listTree(root);
    } else {
      final res = await Shell.instance.exec(
        "set -o pipefail; cd ${shQuote(root)} && find . -mindepth 1 "
        r"\( -name .dart_tool -o -name build -o -name .git \) -prune -o "
        r"\( -type d -printf '%P/\n' -o -type f -printf '%P\n' \) | sort",
      );
      if (request != _refreshRequest) return;
      if (res['exitCode'] != 0) {
        throw StateError(
          strings.unableToReadProjectDirectoryP(res['output'] ?? ''),
        );
      }
      final out = (res['output'] as String? ?? '').trim();
      listing = out.split('\n').where((l) => l.isNotEmpty).toList();
    }
    if (request != _refreshRequest) return;
    _files = List.unmodifiable(listing);
    notifyListeners();
  }

  /// 文件类型: 按后缀能定的直接定; 未知后缀/无后缀嗅探前 8KB,
  /// 嗅探本身失败按文本处理(编辑器自己会报读不出)
  Future<FileKind> kindOf(String rel) async {
    final byName = fileKindByName(rel);
    if (byName != null) return byName;
    try {
      final absolute = joinPath(root, rel);
      if (isDesktopPlatform) {
        // 目录（如 Web 构建产物 build/web/）没有后缀也读不了文本：
        // 按文件卡展示，交给 FileCard 决定"打开文件夹/导出"。
        if (Directory(absolute).existsSync()) return FileKind.binary;
        return sniffFile(absolute);
      }
      final res = await Shell.instance.exec(sniffCommand(absolute));
      return fileKindFromSniff(res['output'] as String? ?? '');
    } catch (_) {
      return FileKind.code;
    }
  }

  String _relative(String path) {
    final relative = relativeInside(root, path);
    if (relative == null) {
      throw StateError(strings.fileIsOutsideTheCurrentProject);
    }
    return relative;
  }

  Future<void> _checked(Future<OpResult> operation) async {
    final result = await operation;
    if (!result.ok) throw StateError(result.msg);
  }

  Future<void> rename(String path, String name) => documents.renamePath(
    _relative(path),
    _relative(joinPath(dirName(path), name)),
    apply: () => _checked(_ops.rename(path, name, allowedRoot: root)),
  );

  Future<void> delete(String path) => documents.deletePath(
    _relative(path),
    apply: () => _checked(_ops.delete(path, allowedRoot: root)),
  );

  Future<void> create(String parent, String name, {required bool directory}) =>
      documents.withFileChange(
        () => _checked(
          directory
              ? _ops.createDir(parent, name, allowedRoot: root)
              : _ops.createFile(parent, name, allowedRoot: root),
        ),
      );

  Future<void> paste(String target) async {
    final source = _ops.clipPath;
    if (source == null) throw StateError(strings.noFilesToPaste);
    final cut = _ops.clipCut;
    if (cut) {
      if (_ops.clipRoot != root) {
        throw StateError(strings.filesCanOnlyBeMovedWithinThe);
      }
      final destination = joinPath(target, baseName(source));
      await documents.renamePath(
        _relative(source),
        _relative(destination),
        apply: () => _checked(
          _ops.moveInto(
            source,
            target,
            sourceRoot: root,
            destinationRoot: root,
          ),
        ),
      );
    } else {
      await documents.withFileChange(
        () => _checked(_ops.copyInto(source, target, destinationRoot: root)),
      );
    }
    if (cut && _ops.clipPath == source) _ops.clearClip();
  }
}
