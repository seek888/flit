import 'dart:io';

import '../../services/desktop_toolchain.dart';
import '../../services/paths.dart';
import 'toolchain_catalog.dart';

/// 精确的 SDK 包标识；version 是项目要求的版本，不是“可替代”的最新版。
class AndroidComponent {
  const AndroidComponent(this.id, [this.version = '']);
  final String id;
  final String version;
  String get key => '$id:$version';
  String get title =>
      '${const {'platforms': 'Android Platform', 'build-tools': 'Build Tools', 'ndk': 'NDK', 'cmake': 'CMake / Ninja', 'platform-tools': 'Platform Tools', 'cmdline-tools': 'Command-line Tools'}[id] ?? id}${version.isEmpty ? '' : ' $version'}';
}

/// 桌面端 Android 构建组件的探测：`android_components.sh` + `component_checks.sh`
/// 的纯 Dart 等价物。
///
/// 只读 SDK 目录结构与 `source.properties` 的 `Pkg.Revision`，**不执行子进程**
/// （Windows 上 `aapt2 version` 会被杀毒软件拖慢、25s 超时不可控），不下载、
/// 不接受许可证、不修改工程。Android 侧仍走原来的 bash 探测（脚本与 termux
/// 工具链绑定），由 [AndroidBuildWrapper] 按平台分流。
class AndroidComponentProbe {
  AndroidComponentProbe({String? sdkDir, String? javaExe})
    : sdkDir = sdkDir ?? DesktopToolchain().sdkDir,
      javaExe = javaExe ?? DesktopToolchain().javaExe;

  /// `<home>/android-sdk`（DesktopToolchain.sdkDir）。
  final String sdkDir;

  /// JDK 的可执行文件；baseline 要求它存在（对齐脚本 `die` 的语义）。
  final String javaExe;

  /// baseline 缺 AAPT2 时报这个版本（`SDK_VERSION` 缺省值）。
  static const defaultBuildToolsVersion = ToolchainCatalog.sdkVersion;

  /// 与 `android_components.sh` 相同的调用协议：
  /// - [baseline]：JDK 可用（存在）+ 任一 build-tools 下有可用 aapt2；
  /// - [device]：只要求 platform-tools；
  /// - [declared]：按项目声明逐项精确匹配版本。
  ///
  /// JDK 缺失直接抛 [StateError]，与脚本非零退出等价（检查失败不能当成环境正常）。
  Future<List<AndroidComponent>> check(
    List<AndroidComponent> declared, {
    bool baseline = false,
    bool device = false,
  }) async {
    final missing = <AndroidComponent>[];
    if (baseline) {
      if (!File(javaExe).existsSync()) {
        throw StateError(
          'Java 无法运行：JDK 未安装或路径无效（$javaExe）。'
          '请先在开发环境页安装 JDK 17。',
        );
      }
      // 基础环境只要有一套可用 AAPT2；项目声明的 Build Tools 版本在下面逐项校验。
      if (!_hasAnyAapt2()) {
        missing.add(
          const AndroidComponent('build-tools', defaultBuildToolsVersion),
        );
      }
    }
    if (device && !usable(const AndroidComponent('platform-tools'))) {
      missing.add(const AndroidComponent('platform-tools'));
    }
    for (final component in declared) {
      if (!usable(component)) missing.add(component);
    }
    return missing;
  }

  /// 等价 `component_checks.sh` 的 `component_usable`（可执行性用存在性近似：
  /// 桌面端结构判据 + 真正的构建会给出准确的失败诊断）。
  bool usable(AndroidComponent component) {
    final root = _root(component);
    if (root.isEmpty) return false;
    return switch (component.id) {
      'platforms' =>
        _nonEmpty(joinPath(root, 'android.jar')) &&
            _nonEmpty(joinPath(root, 'source.properties')),
      // Build Tools 必须整套齐全：d8/apksigner/aidl/zipalign/aapt/aapt2。
      'build-tools' =>
        _revision(root) == component.version &&
            _nonEmpty(joinPath(root, 'lib/d8.jar')) &&
            _findEntry(root, 'd8') != null &&
            _findEntry(root, 'apksigner') != null &&
            _findEntry(root, 'aidl') != null &&
            _findEntry(root, 'zipalign') != null &&
            _findEntry(root, 'aapt') != null &&
            _findEntry(root, 'aapt2') != null,
      'platform-tools' => _findEntry(root, 'adb') != null,
      'cmdline-tools' =>
        (_nonEmpty(joinPath(root, 'bin/sdkmanager')) ||
                _nonEmpty(joinPath(root, 'bin/sdkmanager.bat'))) &&
            _hasEntries(joinPath(root, 'lib')),
      'ndk' => _revision(root) == component.version && _hasNdkClang(root),
      'cmake' =>
        _revision(root) == component.version &&
            _findEntry(joinPath(root, 'bin'), 'cmake') != null &&
            _findEntry(joinPath(root, 'bin'), 'ninja') != null,
      _ => false,
    };
  }

  String _root(AndroidComponent component) => switch (component.id) {
    'platforms' => joinPath(sdkDir, 'platforms/${_platformDir(component.version)}'),
    'build-tools' ||
    'ndk' ||
    'cmake' => joinPath(sdkDir, '${component.id}/${component.version}'),
    'platform-tools' => joinPath(sdkDir, 'platform-tools'),
    'cmdline-tools' => joinPath(sdkDir, 'cmdline-tools/latest'),
    _ => '',
  };

  /// `platforms` 的目录名：调用方可能传 `36`，也可能传扫描到的目录名 `android-36`。
  static String _platformDir(String version) =>
      version.startsWith('android-') ? version : 'android-$version';

  /// `source.properties` 里的 `Pkg.Revision`（脚本用 sed 取第一行）。
  String? _revision(String root) {
    try {
      final file = File(joinPath(root, 'source.properties'));
      if (!file.existsSync()) return null;
      final match = RegExp(
        r'^Pkg\.Revision\s*=\s*(\S+)',
        multiLine: true,
      ).firstMatch(file.readAsStringSync());
      return match?[1]?.trim().replaceAll('\r', '');
    } catch (_) {
      return null;
    }
  }

  /// 任一 build-tools 版本下有 aapt2 即可（baseline 不绑定版本）。
  bool _hasAnyAapt2() {
    final directory = Directory(joinPath(sdkDir, 'build-tools'));
    if (!directory.existsSync()) return false;
    try {
      for (final entity in directory.listSync(followLinks: false)) {
        if (entity is Directory && _findEntry(entity.path, 'aapt2') != null) {
          return true;
        }
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// NDK 的 clang 在 `toolchains/llvm/prebuilt/<host>/bin/` 下，宿主目录随平台变化，
  /// 不写死 linux-arm64 / windows-x86_64，任一 prebuilt 有 clang 即视为可用。
  bool _hasNdkClang(String root) {
    final prebuilt = Directory(joinPath(root, 'toolchains/llvm/prebuilt'));
    if (!prebuilt.existsSync()) return false;
    try {
      for (final entity in prebuilt.listSync(followLinks: false)) {
        if (entity is Directory &&
            _findEntry(joinPath(entity.path, 'bin'), 'clang') != null) {
          return true;
        }
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// 可执行文件的存在性检查：桌面端按平台带 `.exe/.bat/.cmd` 后缀，
  /// 测试里可以只造裸名文件，因此四种都查。
  String? _findEntry(String root, String name) {
    if (root.isEmpty) return null;
    for (final candidate in [name, '$name.exe', '$name.bat', '$name.cmd']) {
      final path = joinPath(root, candidate);
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  bool _nonEmpty(String path) {
    try {
      final file = File(path);
      return file.existsSync() && file.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  bool _hasEntries(String path) {
    final directory = Directory(path);
    try {
      return directory.existsSync() && directory.listSync().isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
