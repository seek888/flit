import 'dart:io';

import 'toolchain/archive.dart';
import 'toolchain/component_probe.dart';
import 'toolchain/download.dart';
import 'toolchain/installer.dart';
import 'toolchain/layout.dart';
import 'toolchain/probe.dart';
import 'toolchain/process.dart';
import 'toolchain/sdk_manager.dart';

export 'toolchain/component_probe.dart'
    show ComponentRequest, DesktopComponentProbe, MissingComponent;
export 'toolchain/errors.dart' show ToolchainException;
export 'toolchain/installer.dart' show ToolchainInstaller;
export 'toolchain/layout.dart' show ToolchainLayout;
export 'toolchain/probe.dart'
    show ToolchainStageMarker, ToolchainStatus, stageMarkerTextOf;

/// 桌面端（Windows）工具链门面。
///
/// 所有东西只落在应用私有目录里，不写注册表、不改系统 PATH。真正的实现
/// 在 `lib/services/toolchain/` 分层里：layout / download / archive /
/// process / probe / sdk_manager / installer / component_probe。
///
/// 对外保持向后兼容：路径 getter、`childEnvironment`、`status()`、
/// `install()`、`versionOf()` 的旧调用点无需改动。
class DesktopToolchain {
  DesktopToolchain({
    String? home,
    ToolchainLayout? layout,
    ToolchainInstaller? installer,
  }) : layout =
           layout ??
           ToolchainLayout(home: home ?? ToolchainLayout.defaultHome()),
       _installer = installer;

  /// 进程级共享实例：窗口几何/原生文件选择器只需要目录布局，
  /// 不持有任何有状态资源，可安全复用。
  static final DesktopToolchain instance = DesktopToolchain();

  final ToolchainLayout layout;

  ToolchainInstaller? _installer;
  ToolchainProbe? _probe;
  DesktopComponentProbe? _components;
  ToolchainProcessGateway? _process;

  static String defaultHome() => ToolchainLayout.defaultHome();

  static const String cmdlineToolsBuild = ToolchainLayout.cmdlineToolsBuild;
  static const String defaultBuildTools = ToolchainLayout.defaultBuildTools;
  static const String defaultPlatform = ToolchainLayout.defaultPlatform;
  static const String defaultPlatformVersion =
      ToolchainLayout.defaultPlatformVersion;

  ToolchainProcessGateway get process =>
      _process ??= const SystemToolchainProcess();
  ToolchainInstaller get installer =>
      _installer ??= ToolchainInstaller(layout: layout, process: process);
  ToolchainProbe get probe => _probe ??= ToolchainProbe(layout: layout);
  DesktopComponentProbe get componentProbe =>
      _components ??= DesktopComponentProbe(layout: layout);

  SdkManager get sdkManager => installer.sdkManager;
  Downloader get downloader => installer.downloader;
  ArchiveExtractor get archive => installer.archive;

  String get home => layout.home;
  bool get isWindows => layout.windows;

  String get jdkDir => layout.jdkDir;
  String get sdkDir => layout.sdkDir;
  String get flutterDir => layout.flutterDir;
  String get gradleHome => layout.gradleHome;
  String get pubCache => layout.pubCache;
  String get projectsDir => layout.projectsDir;
  String get gitDir => layout.gitDir;
  String get cacheDir => layout.cacheDir;

  String get javaExe => layout.javaExe;
  String get adbExe => layout.adbExe;
  String get flutterExe => layout.flutterBat;
  String get gitExe => layout.gitExe;
  String get gitCmdDir => layout.gitCmdDir;

  /// 子进程要注入的环境（完全隔离）。保留 getter 形态以兼容旧调用点。
  Map<String, String> get childEnvironment => layout.childEnvironment();

  /// 带额外变量的子进程环境（如代理/测试用）。
  Map<String, String> childEnvironmentWith({
    Map<String, String> extra = const <String, String>{},
  }) => layout.childEnvironment(extra: extra);

  // ---------- 状态检测 ----------

  /// 结构判据（默认）：只看文件/目录，不 exec，可高频调用。
  ///
  /// `structuralOnly: false` 时额外用 25s 超时校验 java/adb/git 能执行；
  /// Flutter 永不在这里 exec（首次运行可能是分钟级，用 [warmUp]）。
  Future<ToolchainStatus> status({bool structuralOnly = true}) async {
    final structural = probe.inspect();
    if (structuralOnly) return structural;
    final jdk =
        structural.jdk &&
        await _canRun(layout.javaExe, const <String>['-version']);
    final adb =
        structural.androidSdk &&
        await _canRun(layout.adbExe, const <String>['version']);
    final gitPath = File(layout.gitExe).existsSync()
        ? layout.gitExe
        : layout.which('git');
    final git =
        structural.git &&
        gitPath != null &&
        await _canRun(gitPath, const <String>['--version']);
    return structural.copyWith(jdk: jdk, androidSdk: adb, git: git);
  }

  /// `.bat/.cmd` 由 `cmd.exe /c` 启动（见 ToolchainProcessGateway），
  /// 裸名先按 PATH 解析；超时可配（默认 25s）。
  Future<bool> _canRun(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final path = _resolveExecutable(executable);
    if (path == null) return false;
    try {
      final result = await process.run(
        path,
        arguments,
        environment: childEnvironment,
        timeout: timeout,
      );
      final output = '${result.stdout}${result.stderr}'.trim();
      return result.exitCode == 0 || output.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  String? _resolveExecutable(String executable) {
    if (File(executable).existsSync()) return executable;
    if (executable.contains('/') || executable.contains('\\')) return null;
    return layout.which(executable);
  }

  // ---------- 安装 ----------

  /// 按阶段安装；yield 日志行，供 UI 终端展示。已装且结构通过则跳过。
  Stream<String> install({
    bool flutter = true,
    bool androidSdk = true,
    String platform = ToolchainLayout.defaultPlatform,
    String buildTools = ToolchainLayout.defaultBuildTools,
  }) => installer.installAll(
    flutter: flutter,
    androidSdk: androidSdk,
    platform: platform,
    buildTools: buildTools,
  );

  /// 预热：跑一次 `flutter --version`（流式、长超时），成功后写标记文件。
  /// 状态检测不依赖它；离线环境可 [skipWarmup]。
  Stream<String> warmUpLines({
    Duration timeout = const Duration(minutes: 30),
  }) => installer.warmUp(timeout: timeout);

  Future<void> warmUp({
    required void Function(String line) log,
    Duration timeout = const Duration(minutes: 30),
  }) async {
    await for (final line in warmUpLines(timeout: timeout)) {
      log(line);
    }
  }

  /// 离线跳过预热：写标记，结构判据视为完成。
  Future<void> skipWarmup() => installer.skipWarmup();

  /// 安装单个 Android SDK 组件（供 D4 构建链补齐用）。
  Future<void> installComponent(
    ComponentRequest component, {
    void Function(String line)? log,
  }) async {
    await for (final line in installer.installComponent(component)) {
      log?.call(line);
    }
  }

  /// 补齐一组缺失组件（一次 sdkmanager 调用；自动装 cmdline-tools + 接受许可）。
  Future<void> ensureComponents(
    List<ComponentRequest> components, {
    void Function(String line)? log,
  }) async {
    await for (final line in installer.ensureComponents(components)) {
      log?.call(line);
    }
  }

  /// 裸 sdkmanager 包名（如 `build-tools;36.0.0`）安装。
  Future<void> installSdkPackages(
    List<String> packages, {
    void Function(String line)? log,
  }) async {
    await for (final line in installer.installSdkPackages(packages)) {
      log?.call(line);
    }
  }

  /// 构建前组件检查：纯目录扫描，等价 `android_components.sh`。
  Future<List<MissingComponent>> checkComponents(
    List<ComponentRequest> declared, {
    bool baseline = false,
    bool device = false,
  }) => componentProbe.check(declared, baseline: baseline, device: device);

  /// 组件版本（从文件读，不 exec；读不到返回空串）。
  Future<String> versionOf(String component) async =>
      probe.componentVersion(component) ?? '';
}