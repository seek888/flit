import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 桌面端（Windows 优先）工具链管理：
/// 所有东西只落在应用私有目录里，不写注册表、不改系统 PATH。
///
/// 目录布局：
///   <home>/jdk/            Temurin 17（解压版）
///   <home>/android-sdk/    cmdline-tools + platform-tools + platforms + build-tools
///   <home>/flutter/        官方 Flutter SDK（给用户项目用）
///   <home>/gradle-home/    GRADLE_USER_HOME
///   <home>/pub-cache/      PUB_CACHE
///   <home>/projects/       工程
///   <home>/cache/          下载缓存
class DesktopToolchain {
  DesktopToolchain({String? home}) : home = home ?? defaultHome();

  final String home;

  static String defaultHome() {
    final override = Platform.environment['FLIT_DESKTOP_HOME'];
    if (override != null && override.trim().isNotEmpty) return override.trim();
    if (Platform.isWindows) {
      final local = Platform.environment['LOCALAPPDATA'];
      if (local != null && local.isNotEmpty) return '$local\\FlitDesk';
      return '${Directory.current.path}\\FlitDesk';
    }
    final h = Platform.environment['HOME'] ?? Directory.current.path;
    return '$h/.flitdesk';
  }

  static const String cmdlineToolsBuild = '13114758';
  static const String defaultBuildTools = '36.0.0';
  static const String defaultPlatform = 'android-36';

  String get jdkDir => _p('jdk');
  String get sdkDir => _p('android-sdk');
  String get flutterDir => _p('flutter');
  String get gradleHome => _p('gradle-home');
  String get pubCache => _p('pub-cache');
  String get projectsDir => _p('projects');
  String get cacheDir => _p('cache');

  String _p(String name) => home.endsWith(Platform.pathSeparator)
      ? '$home$name'
      : '$home${Platform.pathSeparator}$name';

  String get _sep => Platform.pathSeparator;

  String get javaExe => '$jdkDir${_sep}bin${_sep}java${_exe}';
  String get adbExe => '$sdkDir${_sep}platform-tools${_sep}adb${_exe}';
  String get flutterExe => '$flutterDir${_sep}bin${_sep}flutter$_bat';

  String get _exe => Platform.isWindows ? '.exe' : '';
  String get _bat => Platform.isWindows ? '.bat' : '';

  /// 子进程要注入的环境（完全隔离）。
  Map<String, String> get childEnvironment {
    final env = Map<String, String>.from(Platform.environment);
    final pathKey = Platform.isWindows ? 'Path' : 'PATH';
    final parts = <String>[
      '$jdkDir${_sep}bin',
      '$flutterDir${_sep}bin',
      '$sdkDir${_sep}platform-tools',
      '$sdkDir${_sep}cmdline-tools${_sep}latest${_sep}bin',
      env[pathKey] ?? '',
    ].where((e) => e.isNotEmpty).toList();
    env['JAVA_HOME'] = jdkDir;
    env['ANDROID_HOME'] = sdkDir;
    env['ANDROID_SDK_ROOT'] = sdkDir;
    env['PUB_CACHE'] = pubCache;
    env['GRADLE_USER_HOME'] = gradleHome;
    env[pathKey] = parts.join(Platform.isWindows ? ';' : ':');
    return env;
  }

  // ---------- 状态检测 ----------

  Future<ToolchainStatus> status() async {
    final jdkOk = await _canRun(javaExe, const <String>['-version']);
    final adbOk = await _canRun(adbExe, const <String>['version']);
    final aapt2 =
        '$sdkDir${_sep}build-tools${_sep}$defaultBuildTools${_sep}aapt2$_exe';
    final jar =
        '$sdkDir${_sep}platforms${_sep}$defaultPlatform${_sep}android.jar';
    final flutterOk = await _canRun(flutterExe, const <String>['--version']);
    return ToolchainStatus(
      jdk: jdkOk,
      androidSdk: adbOk,
      aapt2: File(aapt2).existsSync(),
      platform: File(jar).existsSync(),
      flutter: flutterOk,
    );
  }

  Future<bool> _canRun(String exe, List<String> args) async {
    if (!File(exe).existsSync()) return false;
    try {
      final r = await Process.run(
        exe,
        args,
        environment: childEnvironment,
        runInShell: false,
      ).timeout(const Duration(seconds: 25));
      return r.exitCode == 0 ||
          (r.stdout.toString().isNotEmpty || r.stderr.toString().isNotEmpty);
    } catch (_) {
      return false;
    }
  }

  // ---------- 安装 ----------

  /// 按阶段安装；yield 日志行，供 UI 终端展示。
  Stream<String> install({
    bool flutter = true,
    bool androidSdk = true,
    String platform = defaultPlatform,
    String buildTools = defaultBuildTools,
  }) async* {
    Directory(home).createSync(recursive: true);
    Directory(cacheDir).createSync(recursive: true);

    yield '[1/4] 准备 JDK 17 ...';
    if (File(javaExe).existsSync()) {
      yield 'JDK 已存在，跳过';
    } else {
      final zip = '$cacheDir${_sep}jdk17.zip';
      await _download(
        'https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse',
        zip,
        (got, total) => null,
      );
      yield '解压 JDK ...';
      final tmp = '$cacheDir${_sep}jdk-tmp';
      _rmrf(tmp);
      _extract(zip, tmp);
      final children = Directory(tmp)
          .listSync()
          .whereType<Directory>()
          .toList();
      _rmrf(jdkDir);
      if (children.isNotEmpty) {
        children.first.renameSync(jdkDir);
      } else {
        Directory(tmp).renameSync(jdkDir);
      }
      _rmrf(tmp);
      yield 'JDK 完成';
    }

    if (androidSdk) {
      yield '[2/4] 准备 Android cmdline-tools ...';
      final toolsBin =
          '$sdkDir${_sep}cmdline-tools${_sep}latest${_sep}bin${_sep}sdkmanager$_bat';
      if (!File(toolsBin).existsSync()) {
        final zip = '$cacheDir${_sep}cmdline-tools.zip';
        await _download(
          'https://dl.google.com/android/repository/commandlinetools-win-$cmdlineToolsBuild_latest.zip',
          zip,
          (got, total) => null,
        );
        final tmp = '$cacheDir${_sep}tools-tmp';
        _rmrf(tmp);
        _extract(zip, tmp);
        final children = Directory(tmp)
            .listSync()
            .whereType<Directory>()
            .toList();
        _rmrf('$sdkDir${_sep}cmdline-tools');
        Directory('$sdkDir${_sep}cmdline-tools').createSync(recursive: true);
        if (children.isNotEmpty) {
          children.first.renameSync('$sdkDir${_sep}cmdline-tools${_sep}latest');
        }
        _rmrf(tmp);
      }

      yield '[3/4] 接受许可并安装 platform-tools / platforms / build-tools ...';
      await _acceptLicenses(toolsBin);
      final r = await Process.run(
        toolsBin,
        <String>[
          '--sdk_root=$sdkDir',
          'platform-tools',
          'platforms;$platform',
          'build-tools;$buildTools',
        ],
        environment: childEnvironment,
        runInShell: true,
      ).timeout(const Duration(minutes: 20));
      final out = '${r.stdout}${r.stderr}'.trim();
      if (out.isNotEmpty) yield out.split('\n').last;
      yield r.exitCode == 0
          ? 'Android SDK 组件就绪'
          : 'sdkmanager 退出码 ${r.exitCode}';
    }

    if (flutter) {
      yield '[4/4] 准备 Flutter SDK ...';
      if (File(flutterExe).existsSync()) {
        yield 'Flutter 已存在，跳过';
      } else {
        final ver = await _resolveFlutterWindowsZip();
        if (ver == null) {
          yield '无法解析 Flutter 版本清单';
        } else {
          final zip = '$cacheDir${_sep}flutter.zip';
          await _download(ver, zip, (got, total) => null);
          yield '解压 Flutter（约 1 GB，慢一点）...';
          final tmp = '$cacheDir${_sep}flutter-tmp';
          _rmrf(tmp);
          _extract(zip, tmp);
          final children = Directory(tmp)
              .listSync()
              .whereType<Directory>()
              .toList();
          _rmrf(flutterDir);
          if (children.isNotEmpty) {
            children.first.renameSync(flutterDir);
          }
          _rmrf(tmp);
          yield 'Flutter 完成';
        }
      }
    }

    final st = await status();
    yield st.summary;
  }

  Future<void> _acceptLicenses(String sdkmanager) async {
    try {
      final p = await Process.start(
        sdkmanager,
        <String>['--sdk_root=$sdkDir', '--licenses'],
        environment: childEnvironment,
        runInShell: true,
      );
      p.stdin.write('${List<String>.filled(60, 'y').join('\n')}\n');
      await p.stdin.flush();
      await p.stdin.close();
      await p.stdout.drain<void>();
      await p.stderr.drain<void>();
      await p.exitCode.timeout(const Duration(minutes: 5), onTimeout: () => -1);
    } catch (_) {}
  }

  /// 从官方清单解析当前 stable 的 Windows 包地址。
  Future<String?> _resolveFlutterWindowsZip() async {
    try {
      final body = await _getText(
        'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json',
      );
      final json = jsonDecode(body) as Map<String, dynamic>;
      final base = json['base_url'] as String? ?? '';
      final current = json['current_release'] as Map<String, dynamic>?;
      final hash = current?['stable'] as String?;
      final releases = (json['releases'] as List<dynamic>? ?? const <dynamic>[])
          .cast<Map<String, dynamic>>();
      for (final r in releases) {
        if (hash != null && r['hash'] == hash) {
          final archive = r['archive'] as String?;
          if (archive != null) return '$base/$archive';
        }
      }
      if (releases.isNotEmpty) {
        final archive = releases.first['archive'] as String?;
        if (archive != null) return '$base/$archive';
      }
    } catch (_) {}
    return null;
  }

  // ---------- 网络 ----------

  Future<String> _getText(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final body = await _request(client, url, const <String>[]);
      return utf8.decode(body, allowMalformed: true);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _download(
    String url,
    String dest,
    void Function(int got, int total) onProgress,
  ) async {
    final file = File(dest);
    if (file.existsSync() && file.lengthSync() > 1024 * 1024) return; // 已有缓存
    file.parent.createSync(recursive: true);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final bytes = await _request(
        client,
        url,
        const <String>[],
        sink: file.openWrite(),
      );
      if (bytes.isEmpty) throw StateError('下载为空: $url');
      if (file.existsSync() && file.lengthSync() < 1024)
        throw StateError('下载过小: $url');
    } finally {
      client.close(force: true);
    }
  }

  /// 手动跟随 3xx（Dart HttpClient 默认不跟随），支持流式写入 sink。
  Future<List<int>> _request(
    HttpClient client,
    String url,
    List<String> _, {
    IOSink? sink,
  }) async {
    var current = Uri.parse(url);
    for (var i = 0; i < 8; i++) {
      final req = await client.getUrl(current);
      req.headers.set('User-Agent', 'FlitDesk/1.0');
      final res = await req.close();
      if (res.statusCode >= 300 && res.statusCode < 400) {
        final loc = res.headers.value('location');
        await res.drain<void>();
        if (loc == null) throw StateError('重定向缺少 location');
        current = current.resolve(loc);
        continue;
      }
      if (res.statusCode >= 400) {
        await res.drain<void>();
        throw StateError('HTTP ${res.statusCode}: $url');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res) {
        builder.add(chunk);
        sink?.add(chunk);
      }
      await sink?.flush();
      await sink?.close();
      return builder.takeBytes();
    }
    throw StateError('重定向次数过多: $url');
  }

  // ---------- 解压 ----------

  void _extract(String zip, String dest) {
    Directory(dest).createSync(recursive: true);
    if (Platform.isWindows) {
      // Windows 10 1803+ 自带 bsdtar，能解 zip 且比 Expand-Archive 快
      final r = Process.runSync('tar.exe', <String>['-xf', zip, '-C', dest]);
      if (r.exitCode == 0) return;
      final ps = Process.runSync('powershell.exe', <String>[
        '-NoProfile',
        '-Command',
        'Expand-Archive -LiteralPath "$zip" -DestinationPath "$dest" -Force',
      ]);
      if (ps.exitCode != 0) {
        throw StateError('解压失败: ${ps.stderr}');
      }
      return;
    }
    final r = Process.runSync('unzip', <String>['-q', zip, '-d', dest]);
    if (r.exitCode != 0) throw StateError('解压失败: ${r.stderr}');
  }

  void _rmrf(String path) {
    final d = Directory(path);
    if (d.existsSync()) d.deleteSync(recursive: true);
  }

  // ---------- 版本信息 ----------

  Future<String> versionOf(String component) async {
    try {
      switch (component) {
        case 'jdk':
          final r = await Process.run(javaExe, const <String>[
            '-version',
          ], environment: childEnvironment);
          return '${r.stderr}${r.stdout}'.split('\n').first.trim();
        case 'flutter':
          final r = await Process.run(flutterExe, const <String>[
            '--version',
          ], environment: childEnvironment);
          return '${r.stdout}'.split('\n').first.trim();
        case 'adb':
          final r = await Process.run(adbExe, const <String>[
            'version',
          ], environment: childEnvironment);
          return '${r.stdout}'.split('\n').first.trim();
      }
    } catch (_) {}
    return '';
  }
}

class ToolchainStatus {
  const ToolchainStatus({
    required this.jdk,
    required this.androidSdk,
    required this.aapt2,
    required this.platform,
    required this.flutter,
  });

  final bool jdk;
  final bool androidSdk;
  final bool aapt2;
  final bool platform;
  final bool flutter;

  bool get ready => jdk && androidSdk && aapt2 && platform && flutter;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'jdk': jdk,
    'androidSdk': androidSdk,
    'aapt2': aapt2,
    'platform': platform,
    'flutter': flutter,
    'ready': ready,
  };

  String get summary =>
      'JDK ${jdk ? 'OK' : '缺失'} / SDK ${androidSdk ? 'OK' : '缺失'} / '
      'aapt2 ${aapt2 ? 'OK' : '缺失'} / platform ${platform ? 'OK' : '缺失'} / '
      'Flutter ${flutter ? 'OK' : '缺失'}';
}
