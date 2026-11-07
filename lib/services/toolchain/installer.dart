import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../github_mirror.dart';
import 'archive.dart';
import 'component_probe.dart';
import 'download.dart';
import 'errors.dart';
import 'layout.dart';
import 'probe.dart';
import 'process.dart';
import 'sdk_manager.dart';

typedef JsonFetcher = Future<Object?> Function(Uri uri);

typedef _AdoptiumAsset = ({
  String url,
  String? sha256,
  int? size,
  String version,
});

typedef _MinGitAsset = ({String url, String? sha256, int size, String version});

typedef _FlutterRelease = ({
  String url,
  String archiveName,
  String? sha256,
  int? size,
  String version,
});

/// 按阶段安装各组件：解析清单（镜像）→ 下载（进度/SHA-256/超时）→ 解压
/// （tar/PowerShell）→ 发布到私有目录 → 结构校验。每步 yield 日志；
/// 已装且结构通过则跳过；失败抛 [ToolchainException]（可重试）。
class ToolchainInstaller {
  ToolchainInstaller._({
    required this.layout,
    required this.downloader,
    required this.archive,
    required this.probe,
    required this.sdkManager,
    required this.process,
    required this.fetchJson,
  });

  factory ToolchainInstaller({
    required ToolchainLayout layout,
    Downloader? downloader,
    ArchiveExtractor? archive,
    ToolchainProbe? probe,
    SdkManager? sdkManager,
    ToolchainProcessGateway? process,
    JsonFetcher? fetchJson,
  }) {
    final gateway = process ?? const SystemToolchainProcess();
    return ToolchainInstaller._(
      layout: layout,
      downloader: downloader ?? Downloader(),
      archive:
          archive ??
          ArchiveExtractor(process: gateway, windows: layout.windows),
      probe: probe ?? ToolchainProbe(layout: layout),
      sdkManager: sdkManager ?? SdkManager(layout: layout, process: gateway),
      process: gateway,
      fetchJson: fetchJson ?? defaultFetchJson,
    );
  }

  final ToolchainLayout layout;
  final Downloader downloader;
  final ArchiveExtractor archive;
  final ToolchainProbe probe;
  final SdkManager sdkManager;
  final ToolchainProcessGateway process;
  final JsonFetcher fetchJson;

  String get cmdlineToolsUrl =>
      'https://dl.google.com/android/repository/'
      'commandlinetools-win-${ToolchainLayout.cmdlineToolsBuild}_latest.zip';

  // ---------- 编排 ----------

  Stream<String> installAll({
    bool flutter = true,
    bool androidSdk = true,
    String platform = ToolchainLayout.defaultPlatform,
    String buildTools = ToolchainLayout.defaultBuildTools,
  }) async* {
    Directory(layout.home).createSync(recursive: true);
    Directory(layout.cacheDir).createSync(recursive: true);
    yield '[1/5] 准备 JDK 17 ...';
    yield* installJdk();
    if (androidSdk) {
      yield '[2/5] 准备 Android 命令行工具 ...';
      yield* installCmdlineTools();
      yield '[3/5] 接受许可并安装 platform-tools / platforms / build-tools ...';
      yield* installSdkPackages(<String>[
        'platform-tools',
        _platformPackage(platform),
        'build-tools;$buildTools',
      ]);
    }
    if (flutter) {
      yield '[4/5] 准备 Git 与 Flutter SDK ...';
      yield* installGit();
      yield* installFlutter();
      yield '[5/5] 预热 Flutter 工具链 ...';
      yield* warmUp();
    }
    yield probe.inspect().summary;
  }

  Stream<String> installAndroidSdk({
    String platform = ToolchainLayout.defaultPlatform,
    String buildTools = ToolchainLayout.defaultBuildTools,
  }) async* {
    yield* installCmdlineTools();
    yield* installSdkPackages(<String>[
      'platform-tools',
      _platformPackage(platform),
      'build-tools;$buildTools',
    ]);
  }

  // ---------- JDK ----------

  Stream<String> installJdk() async* {
    final status = probe.inspect();
    if (status.jdk) {
      final version = status.versions['jdk'] ?? '';
      yield 'JDK 已就绪${version.isEmpty ? '' : '（$version）'}，跳过';
      return;
    }

    final archivePath = layout.cacheFile('jdk17.zip');
    _AdoptiumAsset? metadata;
    try {
      metadata = await _adoptiumAsset();
      yield 'Temurin JDK ${metadata.version}（${_formatBytes(metadata.size)}）';
    } catch (error) {
      final cached = File(archivePath);
      final cachedUsable =
          cached.existsSync() &&
          cached.lengthSync() >= Downloader.minimumCompleteSize;
      if (!cachedUsable) {
        if (error is ToolchainException) rethrow;
        throw ToolchainException('无法解析 Adoptium JDK 下载信息：$error', cause: error);
      }
      yield '无法获取 JDK 元数据（$error），使用已缓存安装包（未做内容校验）';
    }

    yield* _downloadLogged(
      url: metadata?.url,
      destination: archivePath,
      sha256: metadata?.sha256,
      expectedSize: metadata?.size,
      label: 'JDK 17',
    );
    yield '解压 JDK ...';
    final temp = layout.cacheFile('jdk-extract');
    await archive.extract(archivePath, temp);
    final root = ArchiveExtractor.singleChildDirectory(temp) ?? temp;
    _publish(root, layout.jdkDir);
    _deleteQuietly(temp);
    if (!File(layout.javaExe).existsSync() ||
        !File(layout.jdkReleaseFile).existsSync()) {
      throw ToolchainException(
        'JDK 解压后结构不完整（缺少 bin/java 或 release）：${layout.jdkDir}',
      );
    }
    yield 'JDK 完成${probe.readJdkVersion() == null ? '' : '（${probe.readJdkVersion()}）'}';
  }

  Future<_AdoptiumAsset> _adoptiumAsset() async {
    final base = layout.adoptiumBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse(
      '$base/v3/assets/latest/17/hotspot'
      '?architecture=x64&image_type=jdk&os=windows&vendor=eclipse',
    );
    final Object? data;
    try {
      data = await fetchJson(uri);
    } catch (error) {
      throw ToolchainException(
        '无法获取 Adoptium JDK 元数据（$uri）：$error。'
        '可通过 FLIT_ADOPTIUM_BASE 配置镜像后重试。',
        cause: error,
      );
    }
    if (data is! List || data.isEmpty || data.first is! Map) {
      throw ToolchainException('Adoptium JDK 元数据为空或格式无效：$uri');
    }
    final entry = data.first as Map;
    final binary = entry['binary'] as Map?;
    final package = binary?['package'] as Map?;
    final link = package?['link'] as String?;
    final checksum = (package?['checksum'] as String?)?.toLowerCase();
    final size = package?['size'] as int?;
    if (link == null || link.isEmpty) {
      throw ToolchainException('Adoptium 响应缺少 JDK 下载地址：$uri');
    }
    final versionMap = entry['version'] as Map?;
    final version =
        (versionMap?['openjdk_version'] as String?) ??
        (entry['release_name'] as String?) ??
        '';
    return (
      url: link,
      sha256: checksum != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(checksum)
          ? checksum
          : null,
      size: size,
      version: version,
    );
  }

  // ---------- cmdline-tools ----------

  Stream<String> installCmdlineTools() async* {
    if (File(layout.sdkManagerJar).existsSync() &&
        File(layout.sdkManagerBat).existsSync()) {
      yield 'cmdline-tools 已就绪，跳过';
      return;
    }
    if (!File(layout.javaExe).existsSync()) {
      yield 'JDK 未就绪，先安装 JDK ...';
      yield* installJdk();
    }
    final archivePath = layout.cacheFile('cmdline-tools.zip');
    yield '下载 Android 命令行工具（build ${ToolchainLayout.cmdlineToolsBuild}；'
        'Google 未提供官方 SHA-256，使用大小 + 首次摘要记录校验）...';
    yield* _downloadLogged(
      url: cmdlineToolsUrl,
      destination: archivePath,
      label: 'cmdline-tools',
    );
    yield '解压 cmdline-tools ...';
    final temp = layout.cacheFile('cmdline-tools-extract');
    await archive.extract(archivePath, temp);
    final root = ArchiveExtractor.singleChildDirectory(temp) ?? temp;
    _publish(root, layout.cmdlineToolsDir);
    _deleteQuietly(temp);
    if (!File(layout.sdkManagerBat).existsSync()) {
      throw ToolchainException(
        'cmdline-tools 解压后缺少 bin/sdkmanager.bat：${layout.cmdlineToolsDir}',
      );
    }
    yield 'cmdline-tools 完成';
  }

  // ---------- Android SDK 组件 ----------

  Stream<String> installSdkPackages(List<String> packages) async* {
    final wanted = packages.where((package) => package.isNotEmpty).toList();
    if (wanted.isEmpty) return;
    if (!sdkManager.available) {
      yield 'cmdline-tools 未就绪，先安装 ...';
      yield* installCmdlineTools();
    }
    yield '接受 Android SDK 许可 ...';
    await sdkManager.acceptLicenses();
    yield* sdkManager.install(wanted);
    yield 'Android SDK 组件完成：${wanted.join(' ')}';
  }

  Stream<String> installComponent(
    ComponentRequest component, {
    bool acceptLicenses = true,
  }) async* {
    final package = SdkManager.packageFor(component.id, component.version);
    if (package == null) {
      throw ToolchainException(
        '不支持的 Android 组件：${component.id}:${component.version}',
      );
    }
    final components = DesktopComponentProbe(layout: layout);
    if (components.usable(component)) {
      yield '${component.id} ${component.version} 已安装，跳过';
      return;
    }
    if (!File(layout.javaExe).existsSync()) {
      yield 'JDK 未就绪，先安装 JDK ...';
      yield* installJdk();
    }
    if (!sdkManager.available) {
      yield 'cmdline-tools 未就绪，先安装 ...';
      yield* installCmdlineTools();
    }
    if (acceptLicenses) {
      yield '接受 Android SDK 许可 ...';
      await sdkManager.acceptLicenses();
    }
    yield* sdkManager.install(<String>[package]);
    if (!components.usable(component)) {
      throw ToolchainException(
        '${component.id} ${component.version} 安装后校验未通过（SDK：${layout.sdkDir}）',
      );
    }
    yield '${component.id} ${component.version} 安装完成';
  }

  Stream<String> ensureComponents(List<ComponentRequest> components) async* {
    final probeTool = DesktopComponentProbe(layout: layout);
    final missing = components
        .where(
          (component) =>
              SdkManager.packageFor(component.id, component.version) != null &&
              !probeTool.usable(component),
        )
        .toList();
    if (missing.isEmpty) {
      yield '所需 Android 组件已就绪，跳过安装';
      return;
    }
    yield '缺失组件：${missing.map((c) => '${c.id}:${c.version}').join('、')}';
    if (!File(layout.javaExe).existsSync()) {
      yield 'JDK 未就绪，先安装 JDK ...';
      yield* installJdk();
    }
    if (!sdkManager.available) {
      yield 'cmdline-tools 未就绪，先安装 ...';
      yield* installCmdlineTools();
    }
    yield '接受 Android SDK 许可 ...';
    await sdkManager.acceptLicenses();
    yield* sdkManager.install(<String>[
      for (final component in missing)
        SdkManager.packageFor(component.id, component.version)!,
    ]);
    final stillMissing = missing
        .where((component) => !probeTool.usable(component))
        .toList();
    if (stillMissing.isNotEmpty) {
      throw ToolchainException(
        '以下组件安装后仍不可用：'
        '${stillMissing.map((c) => '${c.id}:${c.version}').join('、')}',
      );
    }
    yield 'Android 组件补齐完成';
  }

  // ---------- Git ----------

  Stream<String> installGit() async* {
    if (File(layout.gitExe).existsSync()) {
      final version = probe.readGitMarkerVersion() ?? '';
      yield 'Git 已就绪（私有 MinGit${version.isEmpty ? '' : ' $version'}），跳过';
      return;
    }
    final systemGit = layout.which('git');
    if (systemGit != null) {
      final version = await _gitVersion(systemGit);
      yield '采用系统 Git：$systemGit'
          '${version == null ? '' : '（$version）'}（不改系统 PATH）';
      _writeJson(layout.gitMarkerFile, <String, Object?>{
        'source': 'system',
        'path': systemGit,
        'version': version,
      });
      return;
    }

    final metadata = await _minGitAsset();
    yield '下载 MinGit ${metadata.version}（${_formatBytes(metadata.size)}）...';
    final archivePath = layout.cacheFile('mingit.zip');
    yield* _downloadLogged(
      url: metadata.url,
      destination: archivePath,
      sha256: metadata.sha256,
      expectedSize: metadata.size > 0 ? metadata.size : null,
      label: 'MinGit',
    );
    yield '解压 MinGit ...';
    final temp = layout.cacheFile('mingit-extract');
    await archive.extract(archivePath, temp);
    final root = ArchiveExtractor.singleChildDirectory(temp) ?? temp;
    _publish(root, layout.gitDir);
    _deleteQuietly(temp);
    if (!File(layout.gitExe).existsSync()) {
      throw ToolchainException('MinGit 解压后缺少 cmd/git.exe：${layout.gitDir}');
    }
    final version = await _gitVersion(layout.gitExe) ?? metadata.version;
    _writeJson(layout.gitMarkerFile, <String, Object?>{
      'source': 'private',
      'version': version,
    });
    yield 'Git 完成${version.isEmpty ? '' : '（$version）'}';
  }

  Future<_MinGitAsset> _minGitAsset() async {
    final apiUrl = GithubMirror.wrap(
      'https://api.github.com/repos/git-for-windows/git/releases/latest',
    );
    final Object? data;
    try {
      data = await fetchJson(Uri.parse(apiUrl));
    } catch (error) {
      throw ToolchainException(
        '无法获取 MinGit 下载地址（GitHub API 经镜像 ${GithubMirror.prefix} 仍失败）：'
        '$error。可安装系统 Git 后重试。',
        cause: error,
      );
    }
    if (data is! Map) {
      throw ToolchainException('MinGit 版本信息格式无效：$apiUrl');
    }
    final tag = data['tag_name'] as String? ?? '';
    final assets = (data['assets'] as List? ?? const <dynamic>[])
        .whereType<Map>();
    for (final asset in assets) {
      final name = (asset['name'] as String? ?? '').toLowerCase();
      if (!name.contains('mingit') ||
          !name.contains('64-bit') ||
          !name.endsWith('.zip')) {
        continue;
      }
      final rawUrl = asset['browser_download_url'] as String? ?? '';
      if (rawUrl.isEmpty) continue;
      final digest = (asset['digest'] as String?)?.toLowerCase();
      final sha256 =
          digest != null && RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(digest)
          ? digest.substring(7)
          : null;
      return (
        url: GithubMirror.wrap(rawUrl),
        sha256: sha256,
        size: asset['size'] as int? ?? 0,
        version: tag.replaceFirst(RegExp(r'^v'), ''),
      );
    }
    throw ToolchainException(
      'GitHub 最新 release 中未找到 MinGit 64-bit zip（镜像 ${GithubMirror.prefix}）',
    );
  }

  Future<String?> _gitVersion(String gitPath) async {
    try {
      final result = await process.run(
        gitPath,
        <String>['--version'],
        environment: layout.childEnvironment(),
        timeout: const Duration(seconds: 20),
      );
      final match = RegExp(
        r'git version\s+(\S+)',
      ).firstMatch('${result.stdout}');
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }

  // ---------- Flutter ----------

  Stream<String> installFlutter({String? version}) async* {
    final status = probe.inspect();
    final installed = status.versions['flutter'] ?? '';
    if (status.flutter &&
        (version == null || (installed.isNotEmpty && installed == version))) {
      yield 'Flutter SDK 已就绪${installed.isEmpty ? '' : '（$installed）'}，跳过';
      return;
    }
    final manifest = await _flutterManifest();
    final release = _selectFlutterRelease(manifest, version: version);
    yield 'Flutter ${release.version}（Windows x64）';
    final archivePath = layout.cacheFile(release.archiveName);
    yield* _downloadLogged(
      url: release.url,
      destination: archivePath,
      sha256: release.sha256,
      expectedSize: release.size,
      label: 'Flutter SDK',
    );
    yield '解压 Flutter（约 1 GB，慢一点）...';
    final temp = layout.cacheFile('flutter-extract');
    await archive.extract(archivePath, temp);
    final root = ArchiveExtractor.singleChildDirectory(temp) ?? temp;
    _publish(root, layout.flutterDir);
    _deleteQuietly(temp);
    if (!File(layout.flutterBat).existsSync()) {
      throw ToolchainException(
        'Flutter 解压后缺少 bin/flutter.bat：${layout.flutterDir}',
      );
    }
    yield 'Flutter SDK 完成'
        '${probe.readFlutterVersion() == null ? '' : '（${probe.readFlutterVersion()}）'}';
  }

  Future<Map<String, dynamic>> _flutterManifest() async {
    final base = layout.flutterStorageBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse(
      '$base/flutter_infra_release/releases/releases_windows.json',
    );
    final Object? data;
    try {
      data = await fetchJson(uri);
    } catch (error) {
      throw ToolchainException(
        '无法获取 Flutter 版本清单（$uri）：$error。'
        '可通过 FLIT_FLUTTER_STORAGE_BASE_URL 配置镜像后重试。',
        cause: error,
      );
    }
    if (data is! Map) {
      throw ToolchainException('Flutter 版本清单格式无效：$uri');
    }
    return Map<String, dynamic>.from(data);
  }

  _FlutterRelease _selectFlutterRelease(
    Map<String, dynamic> manifest, {
    String? version,
  }) {
    final releases = (manifest['releases'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .toList();
    final baseUrlRaw =
        manifest['base_url'] as String? ??
        'https://storage.googleapis.com/flutter_infra_release/releases';
    final baseUrl = _rewriteStorageBase(baseUrlRaw);

    Map? release;
    if (version != null) {
      for (final candidate in releases) {
        if (candidate['version'] == version) {
          release = candidate;
          break;
        }
      }
    }
    if (release == null) {
      final current = manifest['current_release'] as Map?;
      final stableHash = current?['stable'] as String?;
      if (stableHash != null) {
        for (final candidate in releases) {
          if (candidate['hash'] == stableHash) {
            release = candidate;
            break;
          }
        }
      }
    }
    if (release == null) {
      for (final candidate in releases) {
        if ((candidate['archive'] as String? ?? '').endsWith('.zip')) {
          release = candidate;
          break;
        }
      }
    }
    if (release == null) {
      throw const ToolchainException('Flutter Windows 清单里没有可用的 zip 包');
    }
    final archive = release['archive'] as String? ?? '';
    final sha = (release['sha256'] as String?)?.toLowerCase();
    return (
      url: _resolveStorageUrl(baseUrl, archive),
      archiveName: archive.split('/').last,
      sha256: sha != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)
          ? sha
          : null,
      size: null,
      version: (release['version'] as String?) ?? '',
    );
  }

  String _rewriteStorageBase(String baseUrl) {
    const official = 'https://storage.googleapis.com';
    final mirror = layout.flutterStorageBaseUrl.replaceAll(RegExp(r'/+$'), '');
    if (baseUrl.startsWith(official) && !mirror.startsWith(official)) {
      return '$mirror${baseUrl.substring(official.length)}';
    }
    return baseUrl;
  }

  String _resolveStorageUrl(String base, String archive) {
    if (archive.startsWith('http')) return archive;
    final cleanBase = base.replaceAll(RegExp(r'/+$'), '');
    return '$cleanBase/${archive.replaceFirst(RegExp(r'^/+'), '')}';
  }

  // ---------- 预热 ----------

  Stream<String> warmUp({
    Duration timeout = const Duration(minutes: 30),
  }) async* {
    Directory(layout.home).createSync(recursive: true);
    if (!File(layout.flutterBat).existsSync()) {
      throw ToolchainException('Flutter SDK 未安装，无法预热：${layout.flutterDir}');
    }
    yield '首次运行 flutter --version 会初始化工具链缓存（需要网络，可能数分钟）...';
    final tail = <String>[];
    var exitCode = -1;
    String? versionFromOutput;
    try {
      final lines = process.stream(
        layout.flutterBat,
        const <String>['--version'],
        environment: layout.childEnvironment(),
        timeout: timeout,
        workingDirectory: layout.home,
        onClosed: (code) => exitCode = code,
      );
      await for (final line in lines) {
        tail.add(line);
        if (tail.length > 40) tail.removeAt(0);
        final match = RegExp(
          r'^Flutter\s+(\d+\.\d+\.\d+)',
        ).firstMatch(line.trim());
        if (match != null) versionFromOutput = match.group(1);
        yield line;
      }
    } on ToolchainException catch (error) {
      throw ToolchainException(
        'Flutter 预热失败：${error.message}。离线环境可点「跳过预热」继续。',
        cause: error,
      );
    }
    if (exitCode != 0) {
      throw ToolchainException(
        'Flutter 预热失败（退出码 $exitCode）。'
        '${tail.isEmpty ? '' : '\n${tail.join('\n')}'}'
        '离线环境可点「跳过预热」继续，或联网后重试。',
      );
    }
    final version = versionFromOutput ?? probe.readFlutterVersion() ?? '';
    _writeJson(layout.warmupMarkerFile, <String, Object?>{
      'ok': true,
      'version': version,
      'at': DateTime.now().toIso8601String(),
    });
    yield 'Flutter 预热完成${version.isEmpty ? '' : '：$version'}';
  }

  /// 离线环境跳过预热：写标记，结构判据视为完成（UI 可显示「已跳过」）。
  Future<void> skipWarmup() async {
    _writeJson(layout.warmupMarkerFile, <String, Object?>{
      'skipped': true,
      'at': DateTime.now().toIso8601String(),
    });
  }

  // ---------- 日志/下载桥接 ----------

  Stream<String> _downloadLogged({
    required String? url,
    required String destination,
    String? sha256,
    int? expectedSize,
    required String label,
    bool useCache = true,
  }) async* {
    if (url == null) {
      final cached = File(destination);
      if (!cached.existsSync() ||
          cached.lengthSync() < Downloader.minimumCompleteSize) {
        throw DownloadException('没有可用的 $label 安装包，且无法获取下载地址');
      }
      yield '使用已缓存的 $label 安装包（未做内容校验）：$destination';
      return;
    }
    final lines = StreamController<String>();
    String? digest;
    Object? failure;
    final future = downloader
        .download(
          url,
          destination,
          sha256: sha256,
          expectedSize: expectedSize,
          useCache: useCache,
          label: label,
          onProgress: (received, total) {
            if (lines.isClosed) return;
            lines.add(_progressLine(label, received, total));
          },
        )
        .then<void>(
          (value) {
            digest = value;
          },
          onError: (Object error) {
            failure = error;
          },
        )
        .whenComplete(() {
          if (!lines.isClosed) lines.close();
        });
    await for (final line in lines.stream) {
      yield line;
    }
    await future;
    final error = failure;
    if (error != null) {
      if (error is ToolchainException) throw error;
      throw DownloadException('下载 $label 失败', cause: error);
    }
    if (digest != null) {
      yield '$label 下载完成（SHA-256 ${digest!.substring(0, 12)}…）';
    }
  }

  // ---------- 工具 ----------

  String _platformPackage(String platform) {
    final value = platform.trim();
    if (value.isEmpty)
      return 'platforms;android-${ToolchainLayout.defaultPlatformVersion}';
    return value.startsWith('android-')
        ? 'platforms;$value'
        : 'platforms;android-$value';
  }

  static String _progressLine(String label, int received, int total) {
    if (total > 0) {
      final percent = (received * 100 ~/ total).clamp(0, 100);
      return '下载 $label $percent%（${_formatBytes(received)} / ${_formatBytes(total)}）';
    }
    return '下载 $label ${_formatBytes(received)}';
  }

  static String _formatBytes(int? bytes) {
    final value = bytes ?? 0;
    if (value <= 0) return '未知大小';
    if (value >= 1024 * 1024 * 1024) {
      return '${(value / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    if (value >= 1024 * 1024) {
      return '${(value / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (value >= 1024) return '${(value / 1024).toStringAsFixed(0)} KB';
    return '$value B';
  }

  void _publish(String source, String destination) {
    final target = Directory(destination);
    if (target.existsSync()) target.deleteSync(recursive: true);
    final parent = target.parent;
    if (!parent.existsSync()) parent.createSync(recursive: true);
    Directory(source).renameSync(destination);
  }

  void _deleteQuietly(String path) {
    try {
      final dir = Directory(path);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
        return;
      }
    } catch (_) {}
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  void _writeJson(String path, Map<String, Object?> data) {
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(data));
    } catch (_) {}
  }

  /// 默认 JSON 获取（走 dart:io HttpClient，自动跟随系统代理 HttpOverrides）。
  static Future<Object?> defaultFetchJson(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'FlitDesk/1.0');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode >= 400) {
        await response.drain<void>();
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
      return jsonDecode(text);
    } finally {
      client.close(force: true);
    }
  }
}
