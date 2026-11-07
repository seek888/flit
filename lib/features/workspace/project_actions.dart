import 'package:flit/l10n/strings.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../services/adb_ops.dart';
import '../../services/paths.dart';
import '../../services/shell.dart';
import '../run/web_runner.dart';
import '../environment/android_build_wrapper.dart';
import '../terminal/run_sessions.dart';
import 'project_documents.dart';

/// 构建命令的唯一拼装点（纯函数，平台分支显式可见、可单测）。
///
/// 桌面端直接执行 flutter（cmd.exe / PTY 能解析 flutter.bat，环境由
/// `DesktopToolchain.childEnvironment` 注入）；Android 端必须先 source 工具链
/// 环境脚本（termux 的 PATH 在 PTY 启动时冻结），保留既有行为。
String buildApkCommand({required bool release, required bool desktop}) {
  final mode = release ? '--release' : '--debug';
  final build = 'flutter build apk $mode --target-platform android-arm64 2>&1';
  if (desktop) return build;
  return 'bash "\$HOME/.flit/scripts/android_build.sh" $build';
}

/// Web 构建命令：两平台同构（flutter build web 自带 pub get，不需要 JDK/Android SDK）。
const String buildWebCommand = 'flutter build web --release 2>&1';

/// 设备运行命令：桌面端没有 bash 前置脚本。
String flutterRunCommand(String target, {required bool desktop}) {
  if (desktop) return 'flutter run -d "$target" 2>&1';
  return 'bash "\$HOME/.flit/scripts/android_build.sh" '
      'flutter run -d ${shQuote(target)} 2>&1';
}

/// `dart compile exe` 命令：输出目录 build/ 由 Dart 侧先建好，不再 `mkdir -p`。
///
/// 工程名可能含空格/中文：桌面用 cmd 与 sh 都认的双引号，Android 保持 POSIX 单引号。
String dartExeCommand(String projectPath, {required bool desktop}) {
  final name = baseName(projectPath);
  final quote = desktop ? (String value) => '"$value"' : shQuote;
  return 'dart compile exe ${quote('bin/$name.dart')} '
      '-o ${quote('build/$name')} 2>&1';
}

/// `dart compile exe` 任务 id（[ProjectActions._prepare] 据此预建输出目录）。
const String dartExeConfigurationId = 'build-dart-exe';

enum ProjectBuild {
  debugApk(
    id: 'build-apk',
    artifactPath: 'build/app/outputs/flutter-apk/app-debug.apk',
    release: false,
  ),
  releaseApk(
    id: 'build-apk-release',
    artifactPath: 'build/app/outputs/flutter-apk/app-release.apk',
    release: true,
  ),
  web(id: 'build-web', artifactPath: null, release: false);

  const ProjectBuild({
    required this.id,
    required this.artifactPath,
    required this.release,
  });

  final String id;

  /// 构建产物的相对路径；Web 的产物是目录（见 [resolvedArtifactPath]）。
  final String? artifactPath;

  /// APK 是否 release 变体。
  final bool release;

  String get title => switch (this) {
    debugApk => strings.buildApkDebug,
    releaseApk => strings.buildApkRelease,
    web => strings.buildWebRelease,
  };

  String get command => switch (this) {
    debugApk ||
    releaseApk => buildApkCommand(release: release, desktop: isDesktopPlatform),
    web => buildWebCommand,
  };

  /// 传给 `builtArtifacts`/文件卡的入口路径。
  ///
  /// Web 产物是目录：桌面端文件卡能识别目录（文件数/总大小/导出/打开文件夹），
  /// Android 端没有目录文件卡，用 `index.html` 作为入口最稳。
  String? get resolvedArtifactPath => switch (this) {
    web => isDesktopPlatform ? 'build/web' : 'build/web/index.html',
    _ => artifactPath,
  };

  RunConfiguration get configuration => RunConfiguration(
    id: id,
    title: title,
    command: command,
    artifactPath: resolvedArtifactPath,
    flutterLogs: true,
  );
}

/// 内置 Flutter/Dart 命令(AS Flutter 插件 Tools 菜单的对应)。
/// 改写源码的命令(dart format / dart fix)暂不内置: 要先解决打开中缓冲区的回读。
enum ProjectTool {
  pubGet('pub-get'),
  pubUpgrade('pub-upgrade'),
  pubOutdated('pub-outdated'),
  clean('clean', exclusive: true),
  analyze('analyze'),
  test('test'),
  doctor('doctor');

  const ProjectTool(this.id, {this.exclusive = false});
  final String id;
  String get title => switch (this) {
    pubGet => strings.getDependencies,
    pubUpgrade => strings.upgradeDependencies,
    pubOutdated => strings.checkOutdatedDependencies,
    clean => strings.cleanBuildOutputs,
    analyze => strings.analyzeCode,
    test => strings.runTests,
    doctor => strings.environmentDiagnostics,
  };

  /// clean 删除正在使用的 build/ 目录, 与一切互斥
  final bool exclusive;

  /// UI 与执行共用配置；analyze 禁止隐式 pub get，才可与打包并行。
  RunConfiguration configuration({required bool flutter}) {
    final cli = flutter ? 'flutter' : 'dart';
    final command = switch (this) {
      pubGet => '$cli pub get',
      pubUpgrade => '$cli pub upgrade',
      pubOutdated => '$cli pub outdated',
      clean => 'flutter clean',
      analyze => '$cli analyze${flutter ? ' --no-pub' : ''}',
      test => '$cli test',
      doctor => 'flutter doctor -v',
    };
    return RunConfiguration(
      id: id,
      title: title,
      command: '$command 2>&1',
      exclusive: exclusive,
      readOnly: this == analyze || this == doctor || this == pubOutdated,
      flutterLogs: flutter,
    );
  }
}

/// Project commands own save/preflight/launch/completion; views only present them.
/// Notifies whenever [starting] changes so the tree can watch it as one object.
class ProjectActions extends ChangeNotifier {
  ProjectActions({
    required this.path,
    required this.documents,
    required this.executions,
    required this.web,
    Future<List<AdbDevice>> Function()? devices,
    bool Function()? gitBusy,
    this.android,
    Future<void> Function(String projectPath)? prepareWeb,
  }) : _devices = devices ?? AdbOps.devices,
       _gitBusy = gitBusy ?? _notBusy,
       _prepareWeb = prepareWeb ?? _prepareWebDefault {
    starting.addListener(notifyListeners);
  }

  static bool _notBusy() => false;

  final String path;
  final ProjectDocuments documents;
  final RunSessions executions;
  final WebRunController web;
  final AndroidBuildWrapper? android;
  final Future<List<AdbDevice>> Function() _devices;
  final bool Function() _gitBusy;

  /// Web 构建前补建 `web/` 平台目录的注入点（测试不 spawn 真实 flutter）。
  final Future<void> Function(String projectPath) _prepareWeb;

  /// Identifier of the action currently preparing a managed session. This
  /// covers the short device lookup/save window before RunSessions has a tab.
  final starting = ValueNotifier<String?>(null);

  /// 构建成功产出的文件(相对工程根): 编辑器据此把产物开成文件卡 tab,
  /// 这就是"构建完显示个位置"的具象——名字/大小/安装/分享都在眼前
  final _artifacts = StreamController<String>.broadcast();
  Stream<String> get builtArtifacts => _artifacts.stream;
  final _starting = <String, Future<RunSession>>{};
  bool _closed = false;

  void _ensureOpen() {
    if (_closed) throw StateError(strings.projectIsClosed);
  }

  Future<void> _save() async {
    _ensureOpen();
    if (AndroidBuildWrapper.installing) {
      throw StateError(strings.theDevelopmentEnvironmentIsBeingInstalledOr);
    }
    if (_gitBusy()) throw StateError(strings.aGitOperationIsInProgressPlease);
    if (!await documents.saveAll()) {
      throw StateError(strings.saveFailedPleaseRetry);
    }
    _ensureOpen();
  }

  Future<RunSession> start(
    RunConfiguration configuration, {
    void Function(String)? onText,
  }) {
    _ensureOpen();
    if (!configuration.readOnly) android?.cancelPending();
    final existing = executions.forConfiguration(configuration.id);
    if (configuration.kind == SessionKind.temp && existing?.alive == true) {
      executions.select(existing!.id);
      return Future.value(existing);
    }
    return _starting[configuration.id] ??=
        _withStarting(
          configuration.id,
          () => _start(configuration, onText),
        ).whenComplete(() {
          _starting.remove(configuration.id);
        });
  }

  Future<T> _withStarting<T>(String id, Future<T> Function() action) async {
    _ensureOpen();
    if (_gitBusy()) throw StateError(strings.aGitOperationIsInProgressPlease);
    final current = starting.value;
    if (current != null && current != id) {
      throw StateError(strings.aTaskIsAlreadyStartingPleaseWait);
    }
    final owner = current == null;
    if (owner) starting.value = id;
    try {
      return await action();
    } finally {
      if (!_closed && owner && starting.value == id) starting.value = null;
    }
  }

  /// 构建前置（纯 Dart 判断 + 进程参数，不拼 POSIX 管道）：
  /// - Web：工程缺 `web/index.html` 时先 `flutter create --platforms=web .`，
  ///   否则 `flutter build web` 会直接报 "not configured to build on the web"；
  /// - `dart compile exe`：先建 build/ 输出目录，代替 `mkdir -p`。
  Future<void> _prepare(RunConfiguration configuration) async {
    if (configuration.id == ProjectBuild.web.id) {
      await _prepareWeb(path);
      _ensureOpen();
      return;
    }
    if (configuration.id == dartExeConfigurationId) {
      await Directory(joinPath(path, 'build')).create(recursive: true);
    }
  }

  Future<RunSession> _start(
    RunConfiguration configuration,
    void Function(String)? onText,
  ) async {
    await _save();
    await _prepare(configuration);
    final session = await executions.start(configuration, onText: onText);
    final artifact = configuration.artifactPath;
    if (artifact != null) {
      unawaited(
        session.done.then((code) {
          if (!_closed && code == 0 && !session.stopRequested) {
            _artifacts.add(artifact);
          }
        }),
      );
    }
    return session;
  }

  Future<void> run(String target, {ConfirmAndroidRepair? confirmRepair}) async {
    _ensureOpen();
    android?.cancelPending();
    await _withStarting('run:$target', () async {
      if (target == 'web') {
        await _save();
        await web.start();
        if (web.error != null) throw StateError(web.error!);
        return;
      }
      final devices = await _devices();
      _ensureOpen();
      final matches = devices.where((device) => device.$1 == target);
      if (matches.isEmpty) {
        throw StateError(strings.targetPIsNotConnected(target));
      }
      final device = matches.first;
      final configuration = RunConfiguration(
        id: 'run:$target',
        title: device.$2.isEmpty ? target : device.$2,
        command: flutterRunCommand(target, desktop: isDesktopPlatform),
        kind: SessionKind.run,
        hotReload: true,
        target: target,
        flutterLogs: true,
      );
      if (android != null && confirmRepair != null) {
        await android!.start(
          configuration,
          launch: _start,
          confirm: confirmRepair,
          save: _save,
          device: true,
        );
      } else {
        await start(configuration);
      }
    });
  }

  /// 纯 Dart 工程: 平台只有终端, 运行即 console 模板的 dart run。
  Future<void> runDart() => start(
    RunConfiguration(
      id: 'run:dart',
      title: strings.runDart,
      command: 'dart run 2>&1',
      kind: SessionKind.run,
      target: 'dart',
    ),
  );

  /// 纯 Dart 工程的构建 = dart compile exe(原生可执行)。
  /// console 模板入口固定为 bin/<包名>.dart, 包名 = 工程目录名; 产物放 build/。
  RunConfiguration get dartExeConfiguration => RunConfiguration(
    id: dartExeConfigurationId,
    title: strings.compileExecutable,
    command: dartExeCommand(path, desktop: isDesktopPlatform),
  );

  Future<RunSession> buildDartExe() => start(dartExeConfiguration);

  /// 内置命令都是临时会话: 只读输出, 只能关。pub/analyze/test 按工程类型
  /// 走 flutter 或 dart 前缀(flutter 工程的 pub 必须用 flutter pub)。
  Future<RunSession> tool(ProjectTool tool, {required bool flutter}) =>
      start(tool.configuration(flutter: flutter));

  Future<void> reload(String target, {required bool fullRestart}) async {
    final run = executions.forConfiguration('run:$target');
    if (run == null) return;
    if (executions.hasWritingTask || starting.value != null) {
      throw StateError(strings.waitForTheBuildOrDependencyUpdate);
    }
    await _save();
    if (executions.hasWritingTask || starting.value != null) {
      throw StateError(strings.waitForTheBuildOrDependencyUpdate);
    }
    // A rerun during save must not receive an action intended for the old process.
    if (!identical(run, executions.forConfiguration('run:$target'))) return;
    if (target == 'web') {
      if (!await web.reload(fullRestart: fullRestart) && web.error != null) {
        throw StateError(web.error!);
      }
    } else if (run.supportsReload) {
      run.write(fullRestart ? 'R' : 'r');
    }
  }

  Future<RunSession> build(
    ProjectBuild kind, {
    ConfirmAndroidRepair? confirmRepair,
  }) {
    // 桌面端 `android == null`（D1 在 project_session 里按平台置空）：
    // 直接启动构建会话，不再过 AndroidBuildWrapper 的 bash 前置检查。
    if (kind == ProjectBuild.web || android == null || confirmRepair == null) {
      return start(kind.configuration);
    }
    final configuration = kind.configuration;
    final existing = executions.forConfiguration(configuration.id);
    if (existing?.alive == true) {
      executions.select(existing!.id);
      return Future.value(existing);
    }
    return _starting[configuration.id] ??= _withStarting(
      configuration.id,
      () => android!.start(
        configuration,
        launch: _start,
        confirm: confirmRepair,
        save: _save,
      ),
    ).whenComplete(() => _starting.remove(configuration.id));
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    android?.dispose();
    starting.removeListener(notifyListeners);
    starting.dispose();
    _artifacts.close();
    super.dispose();
  }
}

/// 默认的 Web 引导实现：与 Web 预览共用 [ensureWebPlatform]（同一套 Dart 判断）。
Future<void> _prepareWebDefault(String projectPath) async {
  await ensureWebPlatform(projectPath);
}
