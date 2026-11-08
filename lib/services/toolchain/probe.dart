import 'dart:convert';
import 'dart:io';

import 'layout.dart';

/// 一个子任务的判定结果，与 Android `__STAGE__/__VER__` 协议同构。
/// `id` 必须与 `readyStageIds` 完全一致（由 DesktopSetupRunner 保证）。
typedef ToolchainStageMarker = ({
  String id,
  bool ok,
  String? version,
  String? note,
  bool optional,
});

/// 结构判据结果：只看文件/目录，不 exec（首次 `flutter --version` 可能需要
/// 分钟级，不能放进就绪判定）。保留原有字段与 `ready` 语义，`ready` 不再
/// 依赖 flutter 能否执行。
class ToolchainStatus {
  const ToolchainStatus({
    required this.jdk,
    required this.androidSdk,
    required this.aapt2,
    required this.platform,
    required this.flutter,
    required this.git,
    this.commandLineTools = false,
    this.warmup = false,
    this.gitSource,
    this.versions = const <String, String>{},
  });

  final bool jdk;

  /// platform-tools 的 adb 是否存在（旧语义保持不变）。
  final bool androidSdk;
  final bool aapt2;
  final bool platform;
  final bool flutter;
  final bool git;
  final bool commandLineTools;

  /// Flutter SDK 是否已跑过 `flutter --version`（标记文件，不要求本次 exec）。
  final bool warmup;

  /// `private` = 私有 MinGit；`system` = 系统 PATH 里的 git。
  final String? gitSource;

  /// 从文件读出的版本：jdk / flutter / androidSdk / ndk / cmake / git。
  final Map<String, String> versions;

  bool get ready => jdk && androidSdk && aapt2 && platform && flutter;

  ToolchainStatus copyWith({
    bool? jdk,
    bool? androidSdk,
    bool? aapt2,
    bool? platform,
    bool? flutter,
    bool? git,
    bool? commandLineTools,
    bool? warmup,
    String? gitSource,
    Map<String, String>? versions,
  }) => ToolchainStatus(
    jdk: jdk ?? this.jdk,
    androidSdk: androidSdk ?? this.androidSdk,
    aapt2: aapt2 ?? this.aapt2,
    platform: platform ?? this.platform,
    flutter: flutter ?? this.flutter,
    git: git ?? this.git,
    commandLineTools: commandLineTools ?? this.commandLineTools,
    warmup: warmup ?? this.warmup,
    gitSource: gitSource ?? this.gitSource,
    versions: versions ?? this.versions,
  );

  Map<String, dynamic> toMap() => <String, dynamic>{
    'jdk': jdk,
    'androidSdk': androidSdk,
    'aapt2': aapt2,
    'platform': platform,
    'flutter': flutter,
    'git': git,
    'commandLineTools': commandLineTools,
    'warmup': warmup,
    'gitSource': gitSource,
    'versions': versions,
    'ready': ready,
  };

  String get summary =>
      'Git ${git ? 'OK' : '缺失'} / '
      'JDK ${jdk ? 'OK' : '缺失'} / SDK ${androidSdk ? 'OK' : '缺失'} / '
      'aapt2 ${aapt2 ? 'OK' : '缺失'} / platform ${platform ? 'OK' : '缺失'} / '
      'Flutter ${flutter ? 'OK' : '缺失'}';

  /// 8 个环境页子任务的统一映射（唯一真值源：controller 与首页都调它）。
  List<ToolchainStageMarker> toStageMarkers({
    String optionalNote = '按需安装',
    String gradleNote = '由 Gradle Wrapper 自动下载',
  }) {
    final ndkVersion = versions['ndk'];
    final cmakeVersion = versions['cmake'];
    return <ToolchainStageMarker>[
      (
        id: 'android_jdk',
        ok: jdk,
        version: versions['jdk'],
        note: null,
        optional: false,
      ),
      (
        id: 'android_sdk',
        ok: androidSdk && aapt2 && platform,
        version: versions['androidSdk'],
        note: null,
        optional: false,
      ),
      (
        id: 'android_ndk',
        ok: true,
        version: ndkVersion ?? optionalNote,
        note: optionalNote,
        optional: true,
      ),
      (
        id: 'android_cmake',
        ok: true,
        version: cmakeVersion ?? optionalNote,
        note: optionalNote,
        optional: true,
      ),
      (
        id: 'android_gradle',
        ok: true,
        version: versions['gradle'] ?? 'Gradle Wrapper',
        note: gradleNote,
        optional: true,
      ),
      (
        id: 'flutter_tools',
        ok: git,
        version: versions['git'],
        note: gitSource == 'system' ? '使用系统 Git' : null,
        optional: false,
      ),
      (
        id: 'flutter_sdk',
        ok: flutter,
        version: versions['flutter'],
        note: null,
        optional: false,
      ),
      (
        id: 'flutter_warmup',
        ok: warmup,
        version: warmup ? versions['flutter'] : null,
        note: warmup ? null : '尚未预热（首次运行需要网络）',
        optional: false,
      ),
    ];
  }

  String stageMarkerText({
    String optionalNote = '按需安装',
    String gradleNote = '由 Gradle Wrapper 自动下载',
  }) => stageMarkerTextOf(
    toStageMarkers(optionalNote: optionalNote, gradleNote: gradleNote),
  );
}

/// marker 列表 → `__STAGE__/__VER__` 文本（controller 与首页共用）。
String stageMarkerTextOf(List<ToolchainStageMarker> markers) {
  final lines = <String>[];
  for (final marker in markers) {
    lines.add('__STAGE__${marker.id}:${marker.ok ? 'DONE' : 'MISSING'}');
  }
  for (final marker in markers) {
    final version = marker.version;
    if (marker.ok && version != null && version.isNotEmpty) {
      lines.add('__VER__${marker.id}:$version');
    }
  }
  return lines.join('\n');
}

/// 纯结构判据：文件/目录/`source.properties`，不 spawn 任何进程。
class ToolchainProbe {
  ToolchainProbe({required this.layout});

  final ToolchainLayout layout;

  ToolchainStatus inspect() {
    final versions = <String, String>{};

    final jdk =
        _nonEmptyFile(layout.javaExe) && _nonEmptyFile(layout.jdkReleaseFile);
    if (jdk) {
      final version = readJdkVersion();
      if (version != null && version.isNotEmpty) versions['jdk'] = version;
    }

    final adb = _nonEmptyFile(layout.adbExe);
    final platformDir = _bestPlatformDir();
    final buildToolsDir = _bestBuildToolsDir();
    final platform = platformDir != null;
    final aapt2 = buildToolsDir != null;
    final buildToolsVersion = buildToolsDir == null
        ? null
        : (_readPkgRevision(buildToolsDir.path) ?? _leaf(buildToolsDir.path));
    final platformLabel = platformDir == null
        ? null
        : _platformLabel(platformDir.path);
    final sdkParts = <String>[
      if (buildToolsVersion != null) 'Build Tools $buildToolsVersion',
      if (platformLabel != null) 'Platform $platformLabel',
    ];
    if (sdkParts.isNotEmpty) versions['androidSdk'] = sdkParts.join(' · ');

    final commandLineTools =
        _nonEmptyFile(layout.sdkManagerBat) &&
        _nonEmptyDir(layout.join(layout.cmdlineToolsDir, 'lib'));

    final flutter = _flutterInstalled();
    if (flutter) {
      final version = readFlutterVersion();
      if (version != null && version.isNotEmpty) versions['flutter'] = version;
    }

    final ndk = _versionedComponent(layout.ndkDir, requiredRelative: null);
    if (ndk != null) versions['ndk'] = ndk.version;
    final cmake = _versionedComponent(
      layout.cmakeDir,
      requiredRelative: layout.join('bin', 'cmake$_exe'),
    );
    if (cmake != null) versions['cmake'] = cmake.version;

    String? gitPath;
    String? gitSource;
    if (_nonEmptyFile(layout.gitExe)) {
      gitPath = layout.gitExe;
      gitSource = 'private';
    } else {
      final systemGit = layout.which('git');
      if (systemGit != null) {
        gitPath = systemGit;
        gitSource = 'system';
      }
    }
    final git = gitPath != null;
    if (git) {
      final recorded = readGitMarkerVersion();
      if (recorded != null && recorded.isNotEmpty) {
        versions['git'] = recorded;
      } else if (gitSource == 'system') {
        versions['git'] = '系统 Git';
      }
    }

    return ToolchainStatus(
      jdk: jdk,
      androidSdk: adb,
      aapt2: aapt2,
      platform: platform,
      flutter: flutter,
      git: git,
      commandLineTools: commandLineTools,
      warmup: flutter && warmupMarked,
      gitSource: gitSource,
      versions: Map<String, String>.unmodifiable(versions),
    );
  }

  bool get warmupMarked {
    final file = File(layout.warmupMarkerFile);
    if (!file.existsSync()) return false;
    try {
      final data = jsonDecode(file.readAsStringSync());
      if (data is! Map) return false;
      return data['ok'] == true || data['skipped'] == true;
    } catch (_) {
      return false;
    }
  }

  String? readGitMarkerVersion() {
    final file = File(layout.gitMarkerFile);
    if (!file.existsSync()) return null;
    try {
      final data = jsonDecode(file.readAsStringSync());
      if (data is! Map) return null;
      final version = data['version'];
      return version is String ? version : null;
    } catch (_) {
      return null;
    }
  }

  String? readJdkVersion() {
    final text = _readText(layout.jdkReleaseFile);
    return text == null ? null : parseJdkRelease(text);
  }

  String? readFlutterVersion() {
    // 旧布局：`<flutter>/version`；新布局：`bin/cache/flutter.version.json`
    // （Flutter 3.x 后期移除了 version 文件，只认旧的会把已装 SDK 判成缺失）。
    final legacy = _readText(layout.flutterVersionFile)?.trim();
    if (legacy != null && legacy.isNotEmpty) return legacy;
    final json = _readText(layout.flutterVersionJson);
    if (json == null) return null;
    try {
      final data = jsonDecode(json);
      if (data is Map) {
        final version = data['frameworkVersion'] ?? data['flutterVersion'];
        if (version is String && version.trim().isNotEmpty) {
          return version.trim();
        }
      }
    } catch (_) {}
    return null;
  }

  /// Flutter SDK 是否完整：`bin/flutter.bat` + 版本信息或 SDK 自带产物。
  ///
  /// zip 里本来就带 `bin/cache/dart-sdk` 与 `flutter_tools.snapshot`，因此
  /// 未预热也能判定为已安装；预热只影响 `flutter_warmup` 这个独立 marker。
  bool _flutterInstalled() {
    if (!_nonEmptyFile(layout.flutterBat)) return false;
    if (readFlutterVersion() != null) return true;
    return _nonEmptyFile(layout.flutterDartExe) ||
        _nonEmptyFile(layout.flutterToolsSnapshot);
  }

  String? readPkgRevision(String directory) => _readPkgRevision(directory);

  /// 组件 id → 版本文本（从文件读，不 exec）；读不到返回 null。
  String? componentVersion(String component) {
    switch (component) {
      case 'jdk':
        return readJdkVersion();
      case 'flutter':
        return readFlutterVersion();
      case 'adb':
      case 'platform-tools':
        return _readPkgRevision(layout.platformToolsDir);
      case 'cmdline-tools':
        return _readPkgRevision(layout.cmdlineToolsDir);
      case 'build-tools':
        final dir = _bestBuildToolsDir();
        return dir == null
            ? null
            : (_readPkgRevision(dir.path) ?? _leaf(dir.path));
      case 'platforms':
        final dir = _bestPlatformDir();
        return dir == null ? null : _platformLabel(dir.path);
      case 'ndk':
        return _versionedComponent(
          layout.ndkDir,
          requiredRelative: null,
        )?.version;
      case 'cmake':
        return _versionedComponent(
          layout.cmakeDir,
          requiredRelative: layout.join('bin', 'cmake$_exe'),
        )?.version;
      case 'git':
        return readGitMarkerVersion() ??
            (layout.which('git') != null ? '系统 Git' : null);
      default:
        return null;
    }
  }

  // ---------- 纯解析（公开给单测） ----------

  /// `<jdk>/release` 里的 `JAVA_VERSION="17.0.11"` → `17.0.11`。
  static String? parseJdkRelease(String text) {
    final match = RegExp(r'JAVA_VERSION="?([^"\r\n]+)"?').firstMatch(text);
    return match?.group(1)?.trim();
  }

  /// `source.properties` 里的 `Pkg.Revision = 36.0.0` → `36.0.0`。
  static String? parsePkgRevision(String text) =>
      parseSourceProperty(text, 'Pkg.Revision');

  static String? parseSourceProperty(String text, String key) {
    final pattern = RegExp(
      '^\\s*${RegExp.escape(key)}\\s*=\\s*(.+?)\\s*\$',
      multiLine: true,
    );
    return pattern.firstMatch(text)?.group(1)?.trim();
  }

  // ---------- 内部 ----------

  String get _exe => layout.windows ? '.exe' : '';

  String? _readText(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      return file.readAsStringSync();
    } catch (_) {
      return null;
    }
  }

  String? _readPkgRevision(String directory) {
    final text = _readText(layout.join(directory, 'source.properties'));
    return text == null ? null : parsePkgRevision(text);
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

  List<Directory> _listDirs(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return const <Directory>[];
    try {
      return dir.listSync().whereType<Directory>().toList();
    } catch (_) {
      return const <Directory>[];
    }
  }

  String _leaf(String path) =>
      path
          .split(RegExp(r'[/\\]'))
          .where((part) => part.isNotEmpty)
          .lastOrNull ??
      path;

  Directory? _bestPlatformDir() {
    final candidates =
        _listDirs(layout.platformsDir)
            .where(
              (dir) =>
                  _leaf(dir.path).startsWith('android-') &&
                  _nonEmptyFile(layout.join(dir.path, 'android.jar')),
            )
            .toList()
          ..sort((a, b) => _compareVersions(_leaf(a.path), _leaf(b.path)));
    return candidates.isEmpty ? null : candidates.last;
  }

  Directory? _bestBuildToolsDir() {
    final candidates =
        _listDirs(layout.buildToolsDir)
            .where((dir) => _nonEmptyFile(layout.join(dir.path, 'aapt2$_exe')))
            .toList()
          ..sort((a, b) => _compareVersions(_leaf(a.path), _leaf(b.path)));
    return candidates.isEmpty ? null : candidates.last;
  }

  String _platformLabel(String directory) {
    final text = _readText(layout.join(directory, 'source.properties'));
    if (text != null) {
      final api = parseSourceProperty(text, 'AndroidVersion.ApiLevel');
      if (api != null && api.isNotEmpty) return 'API $api';
    }
    final name = _leaf(directory);
    return name.startsWith('android-') ? 'API ${name.substring(8)}' : name;
  }

  ({String path, String version})? _versionedComponent(
    String root, {
    required String? requiredRelative,
  }) {
    final candidates = _listDirs(root).where((dir) {
      if (!_nonEmptyFile(layout.join(dir.path, 'source.properties'))) {
        return false;
      }
      if (requiredRelative != null) {
        return _nonEmptyFile(layout.join(dir.path, requiredRelative));
      }
      return true;
    }).toList()..sort((a, b) => _compareVersions(_leaf(a.path), _leaf(b.path)));
    if (candidates.isEmpty) return null;
    final dir = candidates.last;
    final revision = _readPkgRevision(dir.path) ?? _leaf(dir.path);
    return (path: dir.path, version: revision);
  }

  static int _compareVersions(String a, String b) {
    final left = a.split(RegExp(r'[^0-9]+')).where((part) => part.isNotEmpty);
    final right = b.split(RegExp(r'[^0-9]+')).where((part) => part.isNotEmpty);
    final leftParts = left.toList();
    final rightParts = right.toList();
    final length = leftParts.length > rightParts.length
        ? leftParts.length
        : rightParts.length;
    for (var i = 0; i < length; i++) {
      final leftValue = i < leftParts.length
          ? int.tryParse(leftParts[i]) ?? 0
          : 0;
      final rightValue = i < rightParts.length
          ? int.tryParse(rightParts[i]) ?? 0
          : 0;
      if (leftValue != rightValue) return leftValue.compareTo(rightValue);
    }
    return a.compareTo(b);
  }
}
