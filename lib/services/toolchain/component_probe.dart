import 'dart:io';

import 'errors.dart';
import 'layout.dart';
import 'sdk_manager.dart';

/// 构建前组件检查的输入：与 `AndroidBuildWrapper` 的 `AndroidComponent` 同形，
/// 用 record 解耦（避免服务层反向依赖 features 层）。
typedef ComponentRequest = ({String id, String version});
typedef MissingComponent = ({String id, String version});

/// `assets/scripts/component_checks.sh` + `android_components.sh` 的纯 Dart
/// 对等实现：只扫目录/读 `source.properties`，不 exec。
///
/// 组件 id：`platforms` `build-tools` `ndk` `cmake` `platform-tools`
/// `cmdline-tools`。
class DesktopComponentProbe {
  DesktopComponentProbe({ToolchainLayout? layout})
    : layout = layout ?? ToolchainLayout.defaultLayout();

  final ToolchainLayout layout;

  /// 组件 id + 版本 → sdkmanager 包名；不支持返回 null。
  static String? packageFor(ComponentRequest component) =>
      SdkManager.packageFor(component.id, component.version);

  /// 与 `component_usable()` 等价的判据。
  bool usable(ComponentRequest component) => _usable(component);

  /// 检查一组声明组件，返回缺失项（语义等同 `__MISSING__<id>:<ver>`）。
  ///
  /// [baseline] 对齐 `android_components.sh --baseline`：Java 必须可用
  /// （缺失时抛 [ToolchainException]，脚本里是 `die`），AAPT2 接受任一
  /// build-tools 版本；[device] 只查 platform-tools。
  Future<List<MissingComponent>> check(
    List<ComponentRequest> declared, {
    bool baseline = false,
    bool device = false,
  }) async {
    final missing = <MissingComponent>[];
    if (baseline) {
      if (!_nonEmptyFile(layout.javaExe)) {
        throw const ToolchainException('Java 无法运行，请在开发环境页修复 JDK');
      }
      if (_anyBuildToolsAapt2() == null) {
        missing.add((
          id: 'build-tools',
          version: ToolchainLayout.defaultBuildTools,
        ));
      }
    }
    if (device) {
      if (!_usable((id: 'platform-tools', version: ''))) {
        missing.add((id: 'platform-tools', version: ''));
      }
    }
    for (final component in declared) {
      if (!_usable(component)) missing.add(component);
    }
    return _unique(missing);
  }

  /// 已安装组件目录（相对 home，POSIX 形式），供组件管理页展示。
  List<({String id, String version})> installedComponents() {
    final found = <({String id, String version})>[];
    void scan(String root, String id) {
      final dir = Directory(root);
      if (!dir.existsSync()) return;
      try {
        for (final entry in dir.listSync().whereType<Directory>()) {
          final name = entry.path.split(RegExp(r'[/\\]')).last;
          if (_usable((id: id, version: name))) {
            found.add((id: id, version: name));
          }
        }
      } catch (_) {}
    }

    scan(layout.platformsDir, 'platforms');
    scan(layout.buildToolsDir, 'build-tools');
    scan(layout.ndkDir, 'ndk');
    scan(layout.cmakeDir, 'cmake');
    if (_usable((id: 'platform-tools', version: ''))) {
      found.add((id: 'platform-tools', version: ''));
    }
    if (_usable((id: 'cmdline-tools', version: ''))) {
      found.add((id: 'cmdline-tools', version: ''));
    }
    return found;
  }

  // ---------- 内部 ----------

  String get _exe => layout.windows ? '.exe' : '';

  /// `platforms` 的目录名：允许调用方传 `36` 或 `android-36`。
  static String _platformDir(String version) =>
      version.startsWith('android-') ? version : 'android-$version';

  String get _bat => layout.windows ? '.bat' : '';

  String? _rootFor(String id, String version) => switch (id) {
    // platforms 的目录名本身就带 `android-` 前缀（`platforms/android-36`），
    // 而扫描已装目录时拿到的 version 就是目录名，不能再拼一次。
    'platforms' => layout.join(layout.platformsDir, _platformDir(version)),
    'build-tools' => layout.join(layout.buildToolsDir, version),
    'ndk' => layout.join(layout.ndkDir, version),
    'cmake' => layout.join(layout.cmakeDir, version),
    'platform-tools' => layout.platformToolsDir,
    'cmdline-tools' => layout.cmdlineToolsDir,
    _ => null,
  };

  bool _usable(ComponentRequest component) {
    final root = _rootFor(component.id, component.version);
    if (root == null) return false;
    if (!Directory(root).existsSync()) return false;
    switch (component.id) {
      case 'platforms':
        return _nonEmptyFile(layout.join(root, 'android.jar')) &&
            _nonEmptyFile(layout.join(root, 'source.properties'));
      case 'build-tools':
        final revision = _readPkgRevision(root);
        if (revision == null || revision.isEmpty) return false;
        if (component.version.isNotEmpty && revision != component.version) {
          return false;
        }
        return _nonEmptyFile(layout.join(root, 'lib${_sep}d8.jar')) &&
            _firstExisting(root, <String>['d8$_bat', 'd8']) != null &&
            _firstExisting(root, <String>['apksigner$_bat', 'apksigner']) !=
                null &&
            _firstExisting(root, <String>['aidl$_exe', 'aidl']) != null &&
            _firstExisting(root, <String>['zipalign$_exe', 'zipalign']) !=
                null &&
            _firstExisting(root, <String>['aapt$_exe', 'aapt']) != null &&
            _firstExisting(root, <String>['aapt2$_exe', 'aapt2']) != null;
      case 'platform-tools':
        return _firstExisting(root, <String>['adb$_exe', 'adb']) != null;
      case 'cmdline-tools':
        return _firstExisting(root, <String>[
                  'bin${_sep}sdkmanager$_bat',
                  'bin${_sep}sdkmanager',
                ]) !=
                null &&
            _nonEmptyDir(layout.join(root, 'lib'));
      case 'ndk':
        final revision = _readPkgRevision(root);
        if (revision == null || revision.isEmpty) return false;
        if (component.version.isNotEmpty && revision != component.version) {
          return false;
        }
        final prebuilt = layout.windows
            ? 'toolchains${_sep}llvm${_sep}prebuilt${_sep}windows-x86_64'
            : 'toolchains${_sep}llvm${_sep}prebuilt${_sep}linux-x86_64';
        return _nonEmptyDir(layout.join(root, prebuilt));
      case 'cmake':
        final revision = _readPkgRevision(root);
        if (revision == null || revision.isEmpty) return false;
        if (component.version.isNotEmpty &&
            revision != component.version &&
            !revision.startsWith(component.version)) {
          return false;
        }
        return _firstExisting(root, <String>['bin${_sep}cmake$_exe']) != null &&
            _firstExisting(root, <String>[
                  'bin${_sep}ninja$_exe',
                  'bin${_sep}ninja',
                ]) !=
                null;
      default:
        return false;
    }
  }

  String? _anyBuildToolsAapt2() {
    final dir = Directory(layout.buildToolsDir);
    if (!dir.existsSync()) return null;
    try {
      for (final entry in dir.listSync().whereType<Directory>()) {
        final candidate = _firstExisting(entry.path, <String>[
          'aapt2$_exe',
          'aapt2',
        ]);
        if (candidate != null) return candidate;
      }
    } catch (_) {}
    return null;
  }

  String get _sep => layout.windows ? '\\' : '/';

  String? _firstExisting(String root, List<String> relativePaths) {
    for (final relative in relativePaths) {
      final path = relative
          .split(RegExp(r'[/\\]'))
          .fold<String>(root, layout.join);
      if (_nonEmptyFile(path)) return path;
    }
    return null;
  }

  String? _readPkgRevision(String directory) {
    final file = File(layout.join(directory, 'source.properties'));
    if (!file.existsSync()) return null;
    try {
      final text = file.readAsStringSync();
      final match = RegExp(
        r'^\s*Pkg\.Revision\s*=\s*(.+?)\s*$',
        multiLine: true,
      ).firstMatch(text);
      return match?.group(1)?.trim();
    } catch (_) {
      return null;
    }
  }

  bool _nonEmptyFile(String path) {
    final file = File(path);
    try {
      return file.existsSync() && file.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  bool _nonEmptyDir(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return false;
    try {
      return dir.listSync().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  List<MissingComponent> _unique(List<MissingComponent> input) {
    final seen = <String>{};
    final result = <MissingComponent>[];
    for (final component in input) {
      final key = '${component.id}:${component.version}';
      if (seen.add(key)) result.add(component);
    }
    return result;
  }
}
