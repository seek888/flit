import 'dart:io';

import '../github_mirror.dart';

/// 桌面工具链的单一布局来源：所有路径、版本常量、子进程环境都从这里取。
///
/// 目录布局（全部在应用私有目录里，不写注册表、不改系统 PATH）：
///   `<home>/jdk/`            Temurin 17（解压版）
///   `<home>/android-sdk/`    cmdline-tools + platform-tools + platforms + build-tools + ndk + cmake
///   `<home>/flutter/`        官方 Flutter SDK
///   `<home>/gradle-home/`    GRADLE_USER_HOME
///   `<home>/pub-cache/`      PUB_CACHE
///   `<home>/projects/`       工程
///   `<home>/cache/`          下载缓存
///   `<home>/git/`            MinGit 便携版
///   `<home>/.flit/`          标记文件（预热完成/Git 版本）
///
/// [windows] 可注入：单测里用 `ToolchainLayout(home: r'C:\FlitDesk', windows: true)`
/// 断言反斜杠路径，与宿主平台无关。
class ToolchainLayout {
  ToolchainLayout({
    required String home,
    bool? windows,
    Map<String, String>? baseEnvironment,
    Map<String, String> Function()? proxyEnvironment,
    String? pubHostedUrl,
    String? flutterStorageBaseUrl,
    String? adoptiumBaseUrl,
    String? jdkMirrorBaseUrl,
    String? androidSdkRepoBase,
  }) : home = normalizeHome(home),
       windows = windows ?? Platform.isWindows,
       baseEnvironment = Map<String, String>.unmodifiable(
         baseEnvironment ?? Platform.environment,
       ),
       _proxyEnvironment = proxyEnvironment,
       pubHostedUrl =
           pubHostedUrl ??
           _runtimeOverride('FLIT_PUB_HOSTED_URL', defaultPubHostedUrl),
       flutterStorageBaseUrl =
           flutterStorageBaseUrl ??
           _runtimeOverride(
             'FLIT_FLUTTER_STORAGE_BASE_URL',
             defaultFlutterStorageBaseUrl,
           ),
       adoptiumBaseUrl =
           adoptiumBaseUrl ??
           _runtimeOverride('FLIT_ADOPTIUM_BASE', defaultAdoptiumBaseUrl),
       jdkMirrorBaseUrl =
           jdkMirrorBaseUrl ??
           _runtimeOverride('FLIT_JDK_MIRROR_BASE', defaultJdkMirrorBase),
       androidSdkRepoBase =
           androidSdkRepoBase ??
           _runtimeOverride('FLIT_ANDROID_SDK_BASE', defaultAndroidSdkBase);

  /// Flutter 官方 Windows 清单 / 产物镜像（可配，默认国内镜像）。
  static const String defaultFlutterStorageBaseUrl = String.fromEnvironment(
    'FLIT_FLUTTER_STORAGE_BASE_URL',
    defaultValue: 'https://storage.flutter-io.cn',
  );

  /// pub 镜像；与 Android 侧 env.sh 一致。
  static const String defaultPubHostedUrl = String.fromEnvironment(
    'FLIT_PUB_HOSTED_URL',
    defaultValue: 'https://pub.flutter-io.cn',
  );

  /// Adoptium（Temurin JDK）API；国内直连常超时，镜像优先，API 作回退。
  static const String defaultAdoptiumBaseUrl = String.fromEnvironment(
    'FLIT_ADOPTIUM_BASE',
    defaultValue: 'https://api.adoptium.net',
  );

  /// JDK 的国内镜像（TUNA 的 Adoptium 目录镜像：按目录结构直接取 zip）。
  /// 设为空字符串可关闭，只用 Adoptium 官方 API。
  static const String defaultJdkMirrorBase = String.fromEnvironment(
    'FLIT_JDK_MIRROR_BASE',
    defaultValue: 'https://mirrors.tuna.tsinghua.edu.cn/Adoptium',
  );

  /// Android SDK 仓库根：官方 `dl.google.com` 在国内常不可达，
  /// 默认走腾讯云镜像（与官方 `repository2-3.xml` 同构、逐包 sha1 校验）。
  /// 设为 `https://dl.google.com/android/repository`（或空串）即回官方源。
  static const String defaultAndroidSdkBase = String.fromEnvironment(
    'FLIT_ANDROID_SDK_BASE',
    defaultValue: 'https://mirrors.cloud.tencent.com/AndroidSDK',
  );

  static const String officialAndroidSdkBase =
      'https://dl.google.com/android/repository';

  /// Google 官方 cmdline-tools 构建号（无公开摘要，升级时同步改 URL）。
  static const String cmdlineToolsBuild = '13114758';

  static const String defaultBuildTools = '36.0.0';
  static const String defaultPlatformVersion = '36';
  static const String defaultPlatform = 'android-$defaultPlatformVersion';

  final String home;
  final bool windows;
  final Map<String, String> baseEnvironment;
  final Map<String, String> Function()? _proxyEnvironment;
  final String pubHostedUrl;
  final String flutterStorageBaseUrl;
  final String adoptiumBaseUrl;

  /// JDK 目录镜像根（TUNA 的 Adoptium 镜像）；空串表示不用镜像。
  final String jdkMirrorBaseUrl;

  /// Android SDK 仓库根；空串等价于官方源。
  final String androidSdkRepoBase;

  /// 非镜像（官方）Flutter 产物根，用于镜像失败后回退。
  static const String officialFlutterStorageBaseUrl =
      'https://storage.googleapis.com';

  /// 归一化后的 JDK 镜像根（去尾斜杠；空串表示关闭）。
  String get jdkMirrorUrl => _trimSlash(jdkMirrorBaseUrl);

  /// 归一化后的 Android SDK 仓库根；空串 → 官方源。
  String get androidSdkRepo =>
      _trimSlash(
        androidSdkRepoBase.isEmpty ? officialAndroidSdkBase : androidSdkRepoBase,
      );

  /// 是否在用国内 Android SDK 镜像（决定是否注入 `SDK_TEST_BASE_URL`）。
  bool get androidSdkMirrored => androidSdkRepo != officialAndroidSdkBase;

  String get cmdlineToolsFileName =>
      'commandlinetools-win-${cmdlineToolsBuild}_latest.zip';

  /// 实际使用的 cmdline-tools 下载地址（镜像优先）。
  String get cmdlineToolsUrl => '$androidSdkRepo/$cmdlineToolsFileName';

  /// 官方 cmdline-tools 地址，镜像失败时回退。
  String get officialCmdlineToolsUrl =>
      '$officialAndroidSdkBase/$cmdlineToolsFileName';

  /// `sdkmanager` 的仓库重定向（`SDK_TEST_BASE_URL`）。
  ///
  /// 只接受**以 `/` 结尾的目录 URL**：写成别的前缀时 sdklib 会打印
  /// `Warning: Ignoring invalid SDK_TEST_BASE_URL` 并静默回退官方源——
  /// 这正是「以为走了镜像、其实在连 dl.google.com」的坑。
  /// 生效后包元数据、包本体与 sha1 校验都来自该目录。
  String? get sdkRepoOverride =>
      androidSdkMirrored ? '$androidSdkRepo/' : null;

  static String _trimSlash(String value) =>
      value.trim().replaceAll(RegExp(r'/+$'), '');

  /// 运行期环境变量优先于编译期默认值（便于高级用户不改构建直接换源）。
  static String _runtimeOverride(String key, String fallback) {
    try {
      final value = Platform.environment[key];
      if (value != null && value.isNotEmpty) return value;
    } catch (_) {}
    return fallback;
  }

  static String defaultHome() {
    final override = Platform.environment['FLIT_DESKTOP_HOME'];
    if (override != null && override.trim().isNotEmpty) {
      return normalizeHome(override);
    }
    if (Platform.isWindows) {
      final local = Platform.environment['LOCALAPPDATA'];
      if (local != null && local.isNotEmpty) {
        return normalizeHome('$local\\FlitDesk');
      }
      final profile = Platform.environment['USERPROFILE'];
      if (profile != null && profile.isNotEmpty) {
        return normalizeHome('$profile\\FlitDesk');
      }
      return normalizeHome('${Directory.current.path}\\FlitDesk');
    }
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return normalizeHome('$home/.flitdesk');
  }

  static ToolchainLayout defaultLayout() =>
      ToolchainLayout(home: defaultHome());

  /// 去掉尾部路径分隔符；盘符根（`C:\`）保留原样。
  static String normalizeHome(String path) {
    var value = path.trim();
    if (value.isEmpty) return value;
    while (value.length > 1) {
      final last = value[value.length - 1];
      if (last != '\\' && last != '/') break;
      final isDriveRoot =
          value.length == 3 && value[1] == ':' && (last == '\\' || last == '/');
      if (isDriveRoot) break;
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  String get pathSeparator => windows ? ';' : ':';

  String get _sep => windows ? '\\' : '/';

  /// 路径拼接（home 已去尾分隔符，这里仍容错外部传入）。
  String join(String root, String leaf) {
    if (root.isEmpty) return leaf;
    if (root.endsWith('\\') || root.endsWith('/')) return '$root$leaf';
    return '$root$_sep$leaf';
  }

  String get dotFlitDir => join(home, '.flit');

  String get jdkDir => join(home, 'jdk');
  String get sdkDir => join(home, 'android-sdk');
  String get flutterDir => join(home, 'flutter');
  String get gradleHome => join(home, 'gradle-home');
  String get pubCache => join(home, 'pub-cache');
  String get projectsDir => join(home, 'projects');
  String get gitDir => join(home, 'git');
  String get cacheDir => join(home, 'cache');

  String get _exe => windows ? '.exe' : '';
  String get _bat => windows ? '.bat' : '';

  String get jdkBinDir => join(jdkDir, 'bin');
  String get javaExe => join(jdkBinDir, 'java$_exe');
  String get jdkReleaseFile => join(jdkDir, 'release');

  String get platformToolsDir => join(sdkDir, 'platform-tools');
  String get adbExe => join(platformToolsDir, 'adb$_exe');
  String get cmdlineToolsDir => join(join(sdkDir, 'cmdline-tools'), 'latest');
  String get sdkManagerBat =>
      join(join(cmdlineToolsDir, 'bin'), 'sdkmanager$_bat');

  /// 新版 cmdline-tools（build 13114758 起）的 classpath jar。
  String get sdkManagerClasspathJar =>
      join(join(cmdlineToolsDir, 'lib'), 'sdkmanager-classpath.jar');

  /// 旧版 cmdline-tools 的 jar 名，仅作兼容回退。
  String get sdkManagerLegacyJar =>
      join(join(cmdlineToolsDir, 'lib'), 'sdkmanager.jar');

  /// 兼容旧调用点：优先返回**实际存在**的 jar，其次返回新版路径。
  ///
  /// 注意：不要把这里的返回值当成「安装完成判据」——目录布局随
  /// cmdline-tools 版本变化，判据请用 [SdkManager.available]。
  String get sdkManagerJar {
    final classpath = sdkManagerClasspathJar;
    if (File(classpath).existsSync()) return classpath;
    final legacy = sdkManagerLegacyJar;
    if (File(legacy).existsSync()) return legacy;
    return classpath;
  }
  String get buildToolsDir => join(sdkDir, 'build-tools');
  String get platformsDir => join(sdkDir, 'platforms');
  String get ndkDir => join(sdkDir, 'ndk');
  String get cmakeDir => join(sdkDir, 'cmake');

  String get flutterBinDir => join(flutterDir, 'bin');
  String get flutterBat => join(flutterBinDir, 'flutter$_bat');

  /// 旧版 Flutter 的版本文件（`<flutter>/version`）。
  String get flutterVersionFile => join(flutterDir, 'version');

  /// 新版 Flutter（3.x 后期起）的版本清单，`version` 文件已被移除。
  String get flutterVersionJson => join(flutterCacheDir, 'flutter.version.json');

  /// SDK 自带的 Dart 可执行文件（zip 内就有，不需要预热）。
  String get flutterDartExe =>
      join(join(join(flutterCacheDir, 'dart-sdk'), 'bin'), 'dart$_exe');
  String get flutterCacheDir => join(flutterBinDir, 'cache');
  String get flutterToolsStamp => join(flutterCacheDir, 'flutter_tools.stamp');
  String get flutterToolsSnapshot =>
      join(flutterCacheDir, 'flutter_tools.snapshot');

  String get gitCmdDir => join(gitDir, 'cmd');
  String get gitExe => join(gitCmdDir, 'git$_exe');

  String cacheFile(String name) => join(cacheDir, name);

  String get warmupMarkerFile => join(dotFlitDir, 'flutter-warm.json');
  String get gitMarkerFile => join(dotFlitDir, 'git.json');
  String get sdkLicenseFile => join(dotFlitDir, 'licenses.json');

  /// PATH 中查找可执行文件（Windows 会补 .exe/.bat/.cmd，返回真实路径）。
  /// 只读文件系统，不 spawn 进程。
  String? which(String name) {
    final pathKey = windows ? 'Path' : 'PATH';
    final raw =
        baseEnvironment[pathKey] ??
        baseEnvironment['PATH'] ??
        baseEnvironment['Path'] ??
        '';
    for (final entry in raw.split(pathSeparator)) {
      final dir = entry.trim().replaceAll('"', '');
      if (dir.isEmpty) continue;
      final hit = _resolveIn(dir, name);
      if (hit != null) return hit;
    }
    return null;
  }

  String? _resolveIn(String dir, String name) {
    final candidates = windows && !name.contains('.')
        ? <String>['$name.exe', '$name.bat', '$name.cmd', name]
        : <String>[name];
    for (final candidate in candidates) {
      final path = join(dir, candidate);
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// 子进程要注入的环境（完全隔离，不污染系统）。
  ///
  /// 顺序：私有 bin 目录优先，然后继承的 Path；不注入 Termux/bionic 专属变量
  /// （LD_* / TMPDIR / JDK_JAVA_OPTIONS / ADB_EMU）。
  Map<String, String> childEnvironment({Map<String, String> extra = const {}}) {
    final environment = <String, String>{...baseEnvironment};
    for (final key in _inheritedNoise) {
      environment.remove(key);
    }
    final pathKey = windows ? 'Path' : 'PATH';
    final inherited =
        environment[pathKey] ??
        environment['PATH'] ??
        environment['Path'] ??
        '';
    final entries = <String>[
      jdkBinDir,
      flutterBinDir,
      platformToolsDir,
      join(cmdlineToolsDir, 'bin'),
      gitCmdDir,
      inherited,
    ].where((entry) => entry.isNotEmpty).toList();
    environment.remove('Path');
    environment.remove('PATH');
    environment['JAVA_HOME'] = jdkDir;
    environment['ANDROID_HOME'] = sdkDir;
    environment['ANDROID_SDK_ROOT'] = sdkDir;
    environment['PUB_CACHE'] = pubCache;
    environment['GRADLE_USER_HOME'] = gradleHome;
    environment['PUB_HOSTED_URL'] = pubHostedUrl;
    environment['FLUTTER_STORAGE_BASE_URL'] = flutterStorageBaseUrl;
    environment['FLIT_GH_PROXY'] = GithubMirror.prefix;
    final sdkRepoOverride = this.sdkRepoOverride;
    if (sdkRepoOverride == null) {
      environment.remove('SDK_TEST_BASE_URL');
    } else {
      environment['SDK_TEST_BASE_URL'] = sdkRepoOverride;
    }
    environment[pathKey] = entries.join(pathSeparator);
    environment.addAll(_proxyEnvironment?.call() ?? const <String, String>{});
    environment.addAll(extra);
    return environment;
  }

  static const List<String> _inheritedNoise = <String>[
    'LD_LIBRARY_PATH',
    'LD_PRELOAD',
    'JDK_JAVA_OPTIONS',
    'TMPDIR',
    'ADB_EMU',
    'PUB_HOSTED_URL',
    'FLUTTER_STORAGE_BASE_URL',
    'SDK_TEST_BASE_URL',
  ];
}
