import 'package:flit/l10n/strings.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 查询已配置构建仓库的 GitHub Releases，失败时保留本次会话内的缓存。
class ToolchainCatalog {
  ToolchainCatalog({this.sources = components});

  final Map<String, CatalogSource> sources;

  /// 可注入测试
  Future<Object?> Function(String url) fetchJson = _fetchJsonDefault;

  final errors = <String, String>{};
  bool get configured => sources.values.any((source) => source.repo.isNotEmpty);

  final _cache = <String, List<CatalogEntry>>{};
  Future<Map<String, List<CatalogEntry>>>? _collecting;
  Map<String, List<CatalogEntry>>? _snapshot;

  // Only repository names, release tags and asset naming rules are bundled.
  // URLs, hashes and sizes always come from GitHub at installation time.
  static const sdkRepo = String.fromEnvironment(
    'FLIT_ANDROID_SDK_REPO',
    defaultValue: 'lycstar/android-sdk-custom',
  );
  static const packagesRepo = String.fromEnvironment(
    'FLIT_PACKAGES_REPO',
    defaultValue: 'seek888/flit-termux-packages',
  );
  static const sdkVersion = '36.0.0';
  static const platformVersion = '36';
  static const ndkVersion = '28.2.13676358';
  static const cmakeVersion = '3.22.1';
  static const flutterVersion = '3.47.8';
  static const bootstrap = CatalogSource(
    repo: packagesRepo,
    asset: 'bootstrap-aarch64.zip',
    install: r'$PREFIX',
    tagPattern: r'^bootstrap-flit-aarch64-[0-9]+$',
    defaultTag: 'bootstrap-flit-aarch64-40801524107',
  );

  static const components = <String, CatalogSource>{
    'android-sdk': CatalogSource(
      repo: sdkRepo,
      asset: 'android-sdk.tar.xz',
      install: r'$HOME/toolchains/android-sdk',
      tagPattern: r'^sdk-[0-9]+\.[0-9]+\.[0-9]+$',
      defaultTag: 'sdk-$sdkVersion',
    ),
    'build-tools': CatalogSource(
      repo: sdkRepo,
      asset: 'build-tools.tar.xz',
      install: r'$HOME/toolchains/android-sdk/build-tools/<version>',
      tagPattern: r'^sdk-[0-9]+\.[0-9]+\.[0-9]+$',
      defaultTag: 'sdk-$sdkVersion',
    ),
    'platforms': CatalogSource(
      repo: sdkRepo,
      asset: 'platforms.tar.xz',
      install: r'$HOME/toolchains/android-sdk/platforms/android-<API>',
      tagPattern: r'^platform-[0-9]+(?:\.[0-9]+)?$',
      defaultTag: 'platform-$platformVersion',
    ),
    'platform-tools': CatalogSource(
      repo: sdkRepo,
      asset: 'platform-tools.tar.xz',
      install: r'$HOME/toolchains/android-sdk/platform-tools',
      tagPattern: r'^sdk-[0-9]+\.[0-9]+\.[0-9]+$',
      defaultTag: 'sdk-$sdkVersion',
    ),
    'cmdline-tools': CatalogSource(
      repo: sdkRepo,
      asset: 'cmdline-tools.tar.xz',
      install: r'$HOME/toolchains/android-sdk/cmdline-tools/latest',
      tagPattern: r'^sdk-[0-9]+\.[0-9]+\.[0-9]+$',
      defaultTag: 'sdk-$sdkVersion',
    ),
    'ndk': CatalogSource(
      repo: String.fromEnvironment(
        'FLIT_NDK_REPO',
        defaultValue: 'lycstar/android-ndk-custom',
      ),
      asset: 'android-ndk-*-aarch64-linux-android.tar.xz',
      install: r'$HOME/toolchains/ndk/<Pkg.Revision>',
      tagPattern: r'^ndk-r[0-9]+[a-z]?$',
      defaultTag: 'ndk-r28c',
    ),
    'cmake': CatalogSource(
      repo: String.fromEnvironment(
        'FLIT_CMAKE_REPO',
        defaultValue: 'lycstar/cmake-custom',
      ),
      asset: 'cmake-aarch64-linux-android.tar.xz',
      install: r'$HOME/toolchains/cmake/<version>',
      tagPattern: r'^cmake-[0-9]+\.[0-9]+\.[0-9]+$',
      defaultTag: 'cmake-$cmakeVersion',
    ),
    'flutter-sdk': CatalogSource(
      repo: String.fromEnvironment(
        'FLIT_FLUTTER_SDK_REPO',
        defaultValue: 'lycstar/flutter-sdk-custom',
      ),
      asset: 'flutter-*-aarch64-linux-android.tar.xz',
      install: r'$HOME/toolchains/flutter/<version>',
      tagPattern: r'^flutter-[0-9]+\.[0-9]+\.[0-9]+$',
      defaultTag: 'flutter-$flutterVersion',
    ),
  };

  Map<String, List<CatalogEntry>> get lastGood => Map.unmodifiable(_cache);

  CatalogSource sourceFor(String component) => component == 'bootstrap'
      ? bootstrap
      : sources[component] ??
            (throw StateError(strings.unknownComponentP(component)));

  /// Exact-tag lookup avoids depending on /latest or release ordering.
  Future<CatalogEntry> resolve(String component, {String? tag}) async {
    final source = sourceFor(component);
    final selected = tag ?? source.defaultTag;
    if (source.repo.isEmpty || !source.acceptsTag(selected)) {
      throw StateError(strings.noValidPReleaseConfiguredP(component, selected));
    }
    final data = await fetchJson(
      'https://api.github.com/repos/${source.repo}/releases/tags/${Uri.encodeComponent(selected)}',
    );
    if (data is! Map || data['tag_name'] != selected || data['draft'] == true) {
      throw StateError(strings.releaseUnavailableP(selected));
    }
    final matches = _entries(component, source, data).toList();
    if (matches.length != 1) {
      throw StateError(strings.noUniquePFoundInP(selected, source.asset));
    }
    final entry = matches.single;
    if (entry.sha256 == null || Uri.tryParse(entry.url)?.scheme != 'https') {
      throw StateError(strings.pPIsMissingAValidDownload(selected, entry.name));
    }
    return entry;
  }

  Iterable<CatalogEntry> _entries(
    String id,
    CatalogSource source,
    Map release,
  ) sync* {
    final tag = release['tag_name'] as String? ?? '';
    if (release['draft'] == true ||
        release['prerelease'] == true ||
        !source.acceptsTag(tag)) {
      return;
    }
    for (final asset in release['assets'] as List? ?? const []) {
      final name = asset['name'] as String? ?? '';
      if (!matchesAsset(name, source.asset)) continue;
      yield CatalogEntry(
        component: id,
        repo: source.repo,
        tag: tag,
        name: name,
        url: asset['browser_download_url'] as String? ?? '',
        size: asset['size'] as int? ?? 0,
        sha256: parseSha256(asset['digest'] as String?),
        publishedAt: DateTime.tryParse(
          release['published_at'] as String? ?? '',
        ),
      );
    }
  }

  Future<List<dynamic>> _releases(String repo) async {
    final all = <dynamic>[];
    for (var page = 1; ; page++) {
      final data = await fetchJson(
        'https://api.github.com/repos/$repo/releases?per_page=100&page=$page',
      );
      if (data is! List) {
        throw FormatException(strings.invalidGithubReleasesResponse);
      }
      all.addAll(data);
      if (data.length < 100) return all;
    }
  }

  /// 目录属于应用会话，不属于列表项。滚动销毁、重新进入页面以及同时打开
  /// 多个入口都复用同一结果/请求；空目录和失败也缓存，避免滚动触发重试风暴。
  /// 安装仍用 resolve 校验最新资产；用户通过刷新显式更新版本列表。
  Future<Map<String, List<CatalogEntry>>> collect({bool forceRefresh = false}) {
    if (_collecting != null) return _collecting!;
    if (!forceRefresh && _snapshot != null) return Future.value(_snapshot!);
    return _collecting = _collect()
        .then((result) {
          _snapshot = result;
          return result;
        })
        .whenComplete(() => _collecting = null);
  }

  /// 同仓库的 SDK 分包共用分页请求，不同仓库并行读取。
  Future<Map<String, List<CatalogEntry>>> _collect() async {
    final result = <String, List<CatalogEntry>>{};
    final repositories = <String, Future<List<dynamic>>>{};
    errors.clear();
    await Future.wait(
      sources.entries.map((source) async {
        final id = source.key;
        if (source.value.repo.isEmpty) {
          result[id] = const [];
          return;
        }
        try {
          final releases = await (repositories[source.value.repo] ??= _releases(
            source.value.repo,
          ));
          final found =
              [
                for (final release in releases)
                  ..._entries(id, source.value, release as Map),
              ]..sort(
                (a, b) => (b.publishedAt ?? DateTime(0)).compareTo(
                  a.publishedAt ?? DateTime(0),
                ),
              );
          result[id] = List.unmodifiable(found);
          _cache[id] = result[id]!;
        } on Exception catch (error) {
          errors[id] = error.toString();
          result[id] = _cache[id] ?? const [];
        }
      }),
    );
    return Map.unmodifiable(result);
  }

  /// 只接受 GitHub 明确提供的 SHA-256，不把其他算法或空值当作摘要。
  static String? parseSha256(String? digest) {
    if (digest == null ||
        !RegExp(r'^sha256:[0-9a-fA-F]{64}$').hasMatch(digest)) {
      return null;
    }
    return digest.substring(7).toLowerCase();
  }

  /// 资产名通配符匹配(只支持 '*', 够用: 组件资产模式固定); 公开供测试
  static bool matchesAsset(String name, String pattern) {
    // 资产名通配符只支持 '*'(够用: 组件资产模式固定)
    final segments = pattern.split('*');
    var start = 0;
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      if (segment.isEmpty) continue;
      final found = name.indexOf(segment, start);
      if (found < 0) return false;
      start = found + segment.length;
    }
    if (segments.first.isNotEmpty && !name.startsWith(segments.first)) {
      return false;
    }
    if (segments.last.isNotEmpty && !name.endsWith(segments.last)) {
      return false;
    }
    return true;
  }

  static Future<Object?> _fetchJsonDefault(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'Flit');
      request.headers.set('Accept', 'application/vnd.github+json');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      return jsonDecode(
        await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 20)),
      );
    } finally {
      client.close();
    }
  }
}

/// 一个可下载的工具链产物
class CatalogEntry {
  const CatalogEntry({
    required this.component,
    required this.repo,
    required this.tag,
    required this.name,
    required this.url,
    required this.size,
    required this.sha256,
    this.publishedAt,
  });

  final String component;
  final String repo;
  final String tag;
  final String name;

  /// browser_download_url(匿名可下)
  final String url;
  final int size;

  /// GitHub 资产自带的 sha256(安装前校验); 旧资产可能没有
  final String? sha256;
  final DateTime? publishedAt;
}

/// 构建仓与资产匹配模式
class CatalogSource {
  const CatalogSource({
    required this.repo,
    required this.asset,
    required this.install,
    this.tagPattern = r'.+',
    this.defaultTag = '',
  });
  final String repo;
  final String asset;
  final String install;
  final String tagPattern;
  final String defaultTag;
  bool acceptsTag(String tag) =>
      tag.isNotEmpty && RegExp(tagPattern).hasMatch(tag);
}
