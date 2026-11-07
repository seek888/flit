import 'dart:io';

import '../../services/desktop_toolchain.dart';
import '../../services/local_fs.dart';
import 'environment_controller.dart' show partNames, readyStageIds;
import 'installed_toolchain.dart';
import 'setup_event.dart';
import 'toolchain_catalog.dart';

/// 桌面（Windows）安装编排：plan 与 [readyStageIds] 完全一致，check() 输出
/// 8 个结构判据 marker，runStage() 产出类型化事件。Android 的 `SetupRunner`
/// 与 `.sh` 脚本保持原样（桌面不写脚本）。
class DesktopSetupRunner {
  DesktopSetupRunner({
    DesktopToolchain? toolchain,
    ToolchainInstaller? installer,
  }) : toolchain = toolchain ?? DesktopToolchain(installer: installer);

  final DesktopToolchain toolchain;

  ToolchainLayout get layout => toolchain.layout;

  /// 桌面没有 Termux bootstrap。
  bool get needsBootstrap => false;

  /// 与 `readyStageIds` 完全一致（直接引用，避免两份清单漂移）。
  List<String> get plan => List<String>.unmodifiable(readyStageIds);

  /// 建私有目录（不写 `.sh` 脚本）。
  Future<void> prepare() async {
    for (final directory in <String>[
      layout.home,
      layout.cacheDir,
      layout.dotFlitDir,
      layout.projectsDir,
    ]) {
      try {
        Directory(directory).createSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 8 个 `__STAGE__` marker（+ 从文件读的 `__VER__`）。
  List<ToolchainStageMarker> check() =>
      toolchain.probe.inspect().toStageMarkers();

  String checkMarkerText() => toolchain.probe.inspect().stageMarkerText();

  /// 已安装组件列表（组件管理页用；桌面只有单份 Flutter）。
  Future<List<InstalledToolchain>> listInstalled() async {
    final fs = LocalFs.instance;
    final result = <InstalledToolchain>[];
    final status = toolchain.probe.inspect();

    if (status.flutter) {
      final version = toolchain.probe.readFlutterVersion() ?? 'current';
      result.add(
        InstalledToolchain(
          path: 'flutter/$version',
          sizeKb: fs.dirSize(toolchain.flutterDir) ~/ 1024,
          active: true,
          complete: true,
          revision: version,
        ),
      );
    }

    for (final component in toolchain.componentProbe.installedComponents()) {
      final directory = _componentDirectory(component.id, component.version);
      if (directory == null || !Directory(directory).existsSync()) continue;
      result.add(
        InstalledToolchain(
          path: _componentPath(component.id, component.version),
          sizeKb: fs.dirSize(directory) ~/ 1024,
          active: _isActive(component.id, component.version),
          complete: true,
          revision: toolchain.probe.readPkgRevision(directory) ?? '',
        ),
      );
    }
    result.sort((a, b) => a.path.compareTo(b.path));
    return result;
  }

  /// 单阶段安装事件流。
  Stream<SetupEvent> runStage(String id) async* {
    yield StageEvent(id, 'RUNNING');
    try {
      switch (id) {
        case 'android_jdk':
          yield* _logs(toolchain.installer.installJdk());
        case 'android_sdk':
          yield* _logs(toolchain.installer.installAndroidSdk());
        case 'flutter_tools':
          yield* _logs(toolchain.installer.installGit());
        case 'flutter_sdk':
          yield* _logs(toolchain.installer.installFlutter());
        case 'flutter_warmup':
          yield const LogEvent('首次运行 flutter --version 会初始化工具链缓存（需要网络，可能数分钟）');
          yield* _logs(toolchain.warmUpLines());
        case 'android_ndk':
        case 'android_cmake':
        case 'android_gradle':
          yield LogEvent(
            '${partNames[id] ?? id}：桌面端按需安装（'
            '${id == 'android_gradle' ? 'Gradle 由 Wrapper 下载' : '项目需要时再装'}），跳过',
          );
        default:
          throw ToolchainException('未知的桌面安装阶段：$id');
      }
    } on ToolchainException catch (error) {
      yield LogEvent('安装失败：${error.message}');
      yield StageEvent(id, 'FAILED');
      return;
    } catch (error) {
      yield LogEvent('安装失败：$error');
      yield StageEvent(id, 'FAILED');
      return;
    }

    final marker = _markerFor(id);
    if (marker != null && !marker.ok) {
      yield LogEvent('${partNames[id] ?? id} 安装后结构校验未通过');
      yield StageEvent(id, 'FAILED');
      return;
    }
    final version = marker?.version;
    if (version != null && version.isNotEmpty) {
      yield VersionEvent(id, version);
    }
    yield StageEvent(id, 'DONE');
  }

  /// 版本目录里「安装某个版本」（桌面按组件走 sdkmanager / 官方 Flutter 清单）。
  Stream<SetupEvent> installCatalogEntry(CatalogEntry entry) async* {
    if (entry.component == 'flutter-sdk') {
      final version = entry.tag.replaceFirst(RegExp(r'^flutter-'), '');
      yield const LogEvent('桌面端使用 Flutter 官方 Windows 产物安装（不是 Android 自建产物）');
      yield* _logs(toolchain.installer.installFlutter(version: version));
      final installed = toolchain.probe.readFlutterVersion() ?? version;
      yield VersionEvent('flutter_sdk', installed);
      yield const StageEvent('flutter_sdk', 'DONE');
      return;
    }
    final request = _componentRequestFor(entry);
    if (request == null) {
      yield LogEvent(
        '桌面端不支持安装「${entry.component}」整包；请在开发环境页按阶段安装'
        '（JDK / Android SDK / Flutter）',
      );
      return;
    }
    yield* _logs(toolchain.installer.installComponent(request));
    final id = _stageIdFor(request.id);
    if (id != null) {
      final marker = _markerFor(id);
      if (marker != null) {
        final version = marker.version;
        if (marker.ok && version != null && version.isNotEmpty) {
          yield VersionEvent(id, version);
        }
        yield StageEvent(id, marker.ok ? 'DONE' : 'FAILED');
      }
    }
  }

  /// 删除组件目录（桌面单版本，不支持切换）。
  Future<void> uninstall(InstalledToolchain tool) async {
    final target = _installedDirectory(tool);
    if (target == null) {
      throw ToolchainException('无法定位组件目录：${tool.path}');
    }
    final directory = Directory(target);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
    if (tool.isFlutter) {
      try {
        final marker = File(layout.warmupMarkerFile);
        if (marker.existsSync()) marker.deleteSync();
      } catch (_) {}
    }
  }

  /// 离线跳过 Flutter 预热。
  Future<void> skipWarmup() => toolchain.skipWarmup();

  // ---------- 内部 ----------

  ToolchainStageMarker? _markerFor(String id) {
    for (final marker in check()) {
      if (marker.id == id) return marker;
    }
    return null;
  }

  Stream<SetupEvent> _logs(Stream<String> source) async* {
    await for (final line in source) {
      final text = line.trimRight();
      if (text.isEmpty) continue;
      if (text.startsWith('下载 ') && text.contains('%')) {
        yield ProgressEvent(text);
      } else {
        yield LogEvent(text);
      }
    }
  }

  ComponentRequest? _componentRequestFor(CatalogEntry entry) {
    final tag = entry.tag;
    switch (entry.component) {
      case 'platforms':
        return (id: 'platforms', version: tag.replaceFirst('platform-', ''));
      case 'build-tools':
        return (id: 'build-tools', version: tag.replaceFirst('sdk-', ''));
      case 'cmake':
        return (id: 'cmake', version: tag.replaceFirst('cmake-', ''));
      case 'ndk':
        // 发布 tag 是 r 系列，项目要求的完整 Pkg.Revision 来自 AGP 声明
        // （与 Android 一样安装默认 revision）。
        return (id: 'ndk', version: ToolchainCatalog.ndkVersion);
      case 'platform-tools':
        return (id: 'platform-tools', version: '');
      case 'cmdline-tools':
        return (id: 'cmdline-tools', version: '');
      default:
        return null;
    }
  }

  String? _stageIdFor(String componentId) {
    switch (componentId) {
      case 'platforms':
      case 'build-tools':
      case 'platform-tools':
      case 'cmdline-tools':
        return 'android_sdk';
      case 'ndk':
        return 'android_ndk';
      case 'cmake':
        return 'android_cmake';
      default:
        return null;
    }
  }

  String? _componentDirectory(String id, String version) {
    switch (id) {
      case 'platforms':
        return layout.join(layout.platformsDir, 'android-$version');
      case 'build-tools':
        return layout.join(layout.buildToolsDir, version);
      case 'ndk':
        return layout.join(layout.ndkDir, version);
      case 'cmake':
        return layout.join(layout.cmakeDir, version);
      case 'platform-tools':
        return layout.platformToolsDir;
      case 'cmdline-tools':
        return layout.cmdlineToolsDir;
      default:
        return null;
    }
  }

  String _componentPath(String id, String version) {
    switch (id) {
      case 'platforms':
        return 'android-sdk/platforms/android-$version';
      case 'build-tools':
        return 'android-sdk/build-tools/$version';
      case 'ndk':
        return 'ndk/$version';
      case 'cmake':
        return 'cmake/$version';
      case 'platform-tools':
        return 'android-sdk/platform-tools';
      case 'cmdline-tools':
        return 'android-sdk/cmdline-tools/latest';
      default:
        return id;
    }
  }

  bool _isActive(String id, String version) {
    switch (id) {
      case 'build-tools':
        return version == DesktopToolchain.defaultBuildTools;
      case 'platforms':
        return version == DesktopToolchain.defaultPlatformVersion;
      default:
        return true;
    }
  }

  String? _installedDirectory(InstalledToolchain tool) {
    final segments = tool.path.split('/');
    if (segments.isEmpty) return null;
    final first = segments.first;
    if (first == 'flutter') return toolchain.flutterDir;
    if (first == 'ndk' && segments.length > 1) {
      return layout.join(layout.ndkDir, segments[1]);
    }
    if (first == 'cmake' && segments.length > 1) {
      return layout.join(layout.cmakeDir, segments[1]);
    }
    if (first == 'android-sdk') {
      return segments.skip(1).fold<String>(layout.home, layout.join);
    }
    return null;
  }
}
