import 'package:flit/l10n/strings.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/paths.dart';
import '../../services/shell.dart';
import '../../services/adb_ops.dart';
import '../editor/lsp/lsp_client.dart';
import '../git/project_git.dart';
import '../run/web_runner.dart';
import '../environment/android_build_wrapper.dart';
import '../terminal/run_sessions.dart';
import '../terminal/console_session.dart' show ProcessLauncher;
import 'editor_tabs.dart';
import 'project_documents.dart';
import 'project_files.dart';
import 'project_actions.dart';

/// 工程类型决定运行平台列表: Flutter = Web + 设备; Dart = 仅终端。
enum ProjectKind { flutter, dart }

/// One active project owns its buffers, language service and all executions.
/// Listens as a ChangeNotifier so the tree can watch project facts
/// (kind / run target / closed) without reaching into the ValueNotifiers.
class ProjectSession extends ChangeNotifier {
  ProjectSession(
    this.path, {
    required ProcessLauncher launcher,
    AndroidBuildWrapper Function(RunSessions)? androidWrapper,
  }) : _androidWrapper = androidWrapper,
       documents = ProjectDocuments(path),
       executions = RunSessions(projectPath: path, launcher: launcher);
  final String path;
  String get name => baseName(path);
  final language = LspClient();
  final ProjectDocuments documents;
  late final files = ProjectFiles(documents);

  /// 编辑器打开项(tab): 代码项引用 documents 的缓冲, 文件卡项只记路径
  late final tabs = EditorTabs(documents);
  final RunSessions executions;
  final AndroidBuildWrapper Function(RunSessions)? _androidWrapper;

  /// 默认按 Flutter 呈现(避免闪变), 识别为 Dart 后收窄平台列表
  ProjectKind _kind = ProjectKind.flutter;
  ProjectKind get kind => _kind;
  late final web = WebRunController(executions);
  late final ProjectActions actions = ProjectActions(
    path: path,
    documents: documents,
    executions: executions,
    web: web,
    android:
        _androidWrapper?.call(executions) ??
        AndroidBuildWrapper(executions: executions),
    gitBusy: () => git.busy,
  );
  late final ProjectGit git = ProjectGit(
    documents: documents,
    executions: executions,
    preparing: actions.starting,
  );
  String _runTarget = '';
  String get runTarget => _runTarget;
  set runTarget(String value) {
    if (_runTarget == value) return;
    _runTarget = value;
    notifyListeners();
  }

  /// Only fill an empty selection. Refreshing devices never replaces a choice.
  void selectInitialTarget(List<AdbDevice> devices) {
    if (_closed || kind != ProjectKind.flutter || runTarget.isNotEmpty) return;
    final local = devices
        .where(
          (device) => RegExp(
            r'^(127\.0\.0\.1|localhost|\[::1\]):\d+$',
          ).hasMatch(device.$1),
        )
        .toList();
    if (local.isNotEmpty) {
      runTarget = local
          .firstWhere(
            (device) => device.$1 == '127.0.0.1:5555',
            orElse: () => local.first,
          )
          .$1;
    } else if (devices.length == 1) {
      runTarget = devices.single.$1;
    } else if (devices.isEmpty) {
      runTarget = 'web';
    }
  }

  bool _closed = false;
  bool get closed => _closed;

  /// 工程类型/运行目标变化都算项目事实, 让 watch 项目的组件重建
  void setKind(ProjectKind value) {
    if (kind == value) return;
    _kind = value;
    notifyListeners();
  }

  Future<bool> activate() {
    if (_closed) return Future.value(false);
    unawaited(_detectKind().then((_) => _ensureDependencies()));
    return language.ensureStarted(path);
  }

  /// pubspec 依赖里声明 `sdk: flutter` 的是 Flutter 工程; 其余(含纯 Dart
  /// 模板)按 Dart 处理, 顶栏只留终端运行。
  Future<void> _detectKind() async {
    try {
      final res = await Shell.instance.exec(
        "cat ${shQuote('$path/pubspec.yaml')} 2>/dev/null",
      );
      final text = res['output'] as String? ?? '';
      setKind(
        RegExp(r'sdk:\s*flutter').hasMatch(text)
            ? ProjectKind.flutter
            : ProjectKind.dart,
      );
    } catch (_) {}
  }

  Future<void>? _ensuringDeps;

  /// 像 AS 打开工程时自动 sync: 依赖未解析(新建 --no-pub / 刚克隆 / 上次
  /// pub get 被中断)就起一个「获取依赖」临时会话, 失败或停止工程照样在。
  /// 幂等: activate 可能被 ProjectWorkspace 和 EditorPage 各调一次。
  Future<void> _ensureDependencies() => _ensuringDeps ??= _ensureDeps();

  Future<void> _ensureDeps() async {
    if (_closed) return;
    try {
      final res = await Shell.instance.exec(
        "[ -f ${shQuote('$path/.dart_tool/package_config.json')} ] && echo RESOLVED",
      );
      if (_closed || (res['output'] as String? ?? '').contains('RESOLVED')) {
        return;
      }
      await actions.tool(
        ProjectTool.pubGet,
        flutter: kind == ProjectKind.flutter,
      );
    } catch (_) {}
  }

  Future<bool>? _closing;
  Future<bool> close() =>
      _closing ??= _close().whenComplete(() => _closing = null);

  Future<bool> _close() async {
    if (_closed) return true;
    if (git.busy || documents.synchronizing) return false;
    if (!await documents.saveAll()) return false;
    _closed = true;
    notifyListeners();
    await git.close();
    actions.dispose();
    web.dispose();
    await executions.closeAll();
    await language.dispose();
    tabs.dispose();
    await documents.close();
    return true;
  }
}

/// The one open project. Open/close are serialized so a half-closed project
/// can never be observed; listeners rebuild when the active project changes.
class ProjectWorkspace extends ChangeNotifier {
  ProjectWorkspace({required ProcessLauncher launcher}) : _launcher = launcher;

  final ProcessLauncher _launcher;
  ProjectSession? _active;
  ProjectSession? get active => _active;

  /// 串行化链不预建: 第一个操作立即开始, 之后的接在前一个后面。
  /// 测试会在与创建时不同的 zone 里用到工作区(对象建在 setUp, 用在
  /// FakeAsync 测试体), 持有一条跨 zone 的既有完成链会把传播卡死。
  Future<void>? _operations;

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final previous = _operations;
    final result = previous == null
        ? operation()
        : previous.then((_) => operation());
    _operations = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<ProjectSession> open(String path) => _serialize(() => _open(path));

  Future<ProjectSession> _open(String path) async {
    final active = _active;
    if (active != null && active.path == path && !active.closed) return active;
    if (active != null && !await active.close()) {
      throw StateError(
        active.git.busy
            ? strings.aGitOperationIsRunningWaitOr
            : active.documents.synchronizing
            ? strings.aFileOperationIsRunningWaitBefore
            : strings.failedToSaveTheCurrentProjectRetry,
      );
    }
    final project = _active = ProjectSession(path, launcher: _launcher);
    notifyListeners();
    unawaited(project.activate());
    return project;
  }

  Future<bool> closeActive() => _serialize(_closeActive);

  Future<bool> _closeActive() async {
    final project = _active;
    if (project == null) return true;
    if (!await project.close()) return false;
    if (identical(_active, project)) {
      _active = null;
      notifyListeners();
    }
    return true;
  }
}
