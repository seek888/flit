import 'package:flit/l10n/strings.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../services/desktop_toolchain.dart';
import '../../services/github_mirror.dart';
import '../../services/shell.dart';
import '../../services/toolchain/installer.dart' show FlutterReleaseInfo;
import '../../services/toolchain/sdk_manager.dart';

/// Queries GitHub Releases for the configured repositories (Android side), and
/// the Android SDK repository / Flutter mirror on desktop.
///
/// 桌面端**不使用 GitHub 目录**：CMake/Ninja、NDK、Platforms、Build Tools 的
/// 可安装版本来自 `sdkmanager --list`（走国内镜像），Flutter 来自
/// `storage.flutter-io.cn` 的 Windows 清单。GitHub 上那些
/// `*-aarch64-linux-android.tar.xz` 产物在 Windows 上根本装不了。
class ToolchainCatalog {
  ToolchainCatalog({Map<String, CatalogSource>? sources, ToolchainLayout? layout})
    : sources = sources ?? (isDesktopPlatform ? desktopSources : components),
      _layout = layout;

  final Map<String, CatalogSource> sources;
  final ToolchainLayout? _layout;

  /// 可注入测试
  Future<Object?> Function(String url) fetchJson = _fetchJsonDefault;

  final errors = <String, String>{};
  bool get configured => sources.values.any((source) => source.repo.isNotEmpty);

  final _cache = <String, List<CatalogEntry>>{};
  Future<Map<String, List<CatalogEntry>>>? _collecting;
  Map<String, List<CatalogEntry>>? _snapshot;

  // Only repository names, release tags and asset naming rules are bundled.
  // URLs, hashes and sizes always come from GitHub at installation time
  // (routed through GithubMirror for mainland China reachability).
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

  /// 桌面端目录：repo 留空表示「不查 GitHub」，由 SDK 仓库 / Flutter 镜像提供版本。
  /// `defaultTag` 与 [desktopEntries] / [desktopFlutterEntries] 生成的 tag 一致。
  static const desktopSources = <String, CatalogSource>{
    'platforms': CatalogSource(
      repo: '',
      asset: '',
      install: '',
      tagPattern: r'^platform-[0-9]+(?:\.[0-9]+)?$',
      defaultTag: 'platform-$platformVersion',
    ),
    'build-tools': CatalogSource(
      repo: '',
      asset: '',
      install: '',
      tagPattern: r'^sdk-[0-9]+\.[0-9]+\.[0-9]+$',
      defaultTag: 'sdk-$sdkVersion',
    ),
    'ndk': CatalogSource(
      repo: '',
      asset: '',
      install: '',
      tagPattern: r'^ndk-[0-9]+\.[0-9]+\.[0-9]+$',
      defaultTag: 'ndk-$ndkVersion',
    ),
    'cmake': CatalogSource(
      repo: '',
      asset: '',
      install: '',
      tagPattern: r'^cmake-[0-9]+\.[0-9]+\.[0-9]+$',
      defaultTag: 'cmake-$cmakeVersion',
    ),
    'flutter-sdk': CatalogSource(
      repo: '',
      asset: '',
      install: '',
      tagPattern: r'^flutter-[0-9]+\.[0-9]+\.[0-9]+$',
      defaultTag: 'flutter-$flutterVersion',
    ),
  };

  ToolchainLayout get _desktopLayout => _layout ?? ToolchainLayout.defaultLayout();

  /// `sdkmanager --list` → 版本目录条目（纯函数，单测覆盖）。
  ///
  /// tag 沿用仓库原有的前缀约定，下游 `DesktopSetupRunner` 与 UI 不需要改：
  /// `platforms;android-36` → `platform-36`、`cmake;3.22.1` → `cmake-3.22.1`。
  static List<CatalogEntry> desktopEntries(List<SdkPackage> packages) {
    final result = <CatalogEntry>[];
    for (final package in packages) {
      final path = package.path;
      String? component;
      String? tag;
      if (path.startsWith('platforms;')) {
        final api = path.substring('platforms;'.length);
        if (!RegExp(r'^android-[0-9]+(?:\.[0-9]+)?$').hasMatch(api)) continue;
        component = 'platforms';
        tag = 'platform-${api.replaceFirst('android-', '')}';
      } else if (path.startsWith('build-tools;')) {
        final version = path.substring('build-tools;'.length);
        if (!RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(version)) continue;
        component = 'build-tools';
        tag = 'sdk-$version';
      } else if (path.startsWith('ndk;')) {
        final version = path.substring('ndk;'.length);
        if (!RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(version)) continue;
        component = 'ndk';
        tag = 'ndk-$version';
      } else if (path.startsWith('cmake;')) {
        final version = path.substring('cmake;'.length);
        if (!RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(version)) continue;
        component = 'cmake';
        tag = 'cmake-$version';
      } else {
        continue;
      }
      result.add(
        CatalogEntry(
          component: component,
          repo: 'android-sdk',
          tag: tag,
          name: package.description.isEmpty ? path : package.description,
          // 安装走 sdkmanager 包路径；这里没有可直接 wget 的 https 地址。
          url: 'sdkmanager:$path',
          size: 0,
          sha256: null,
        ),
      );
    }
    result.sort(
      (a, b) => _compareVersions(
        b.tag.split('-').skip(1).join('-'),
        a.tag.split('-').skip(1).join('-'),
      ),
    );
    return result;
  }

  /// Flutter 镜像清单 → 版本目录条目（纯函数）。
  static List<CatalogEntry> desktopFlutterEntries(
    List<FlutterReleaseInfo> releases,
  ) => <CatalogEntry>[
    for (final release in releases)
      CatalogEntry(
        component: 'flutter-sdk',
        repo: 'flutter',
        tag: 'flutter-${release.version}',
        name: 'Flutter ${release.version}（Windows x64）',
        url: release.url,
        size: 0,
        sha256: release.sha256,
      ),
  ];

  static int _compareVersions(String a, String b) {
    final left = a
        .split(RegExp(r'[^0-9]+'))
        .where((part) => part.isNotEmpty)
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    final right = b
        .split(RegExp(r'[^0-9]+'))
        .where((part) => part.isNotEmpty)
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    final length = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < length; i++) {
      final l = i < left.length ? left[i] : 0;
      final r = i < right.length ? right[i] : 0;
      if (l != r) return l.compareTo(r);
    }
    return a.compareTo(b);
  }

  /// 桌面端版本目录：SDK 仓库（镜像）里的包 + Flutter 镜像清单。
  Future<Map<String, List<CatalogEntry>>> _collectDesktop() async {
    final result = <String, List<CatalogEntry>>{};
    errors.clear();
    final toolchain = DesktopToolchain(layout: _desktopLayout);
    final manager = toolchain.installer.sdkManager;

    const sdkComponents = <String>[
      'platforms',
      'build-tools',
      'ndk',
      'cmake',
    ];
    if (manager.available) {
      try {
        final packages = await manager.listPackages();
        for (final id in sdkComponents) {
          result[id] = List<CatalogEntry>.unmodifiable(
            desktopEntries(packages).where((e) => e.component == id),
          );
          if (result[id]!.isEmpty) {
            errors[id] = strings.noDownloadableCompanionVersionsInTheRepository;
          }
          _cache[id] = result[id]!;
        }
      } catch (error) {
        for (final id in sdkComponents) {
          errors[id] = '$error';
          result[id] = _cache[id] ?? const <CatalogEntry>[];
        }
      }
    } else {
      for (final id in sdkComponents) {
        errors[id] = '需要先完成 Android 工具链（JDK 与 cmdline-tools），'
            '然后再刷新版本列表';
        result[id] = _cache[id] ?? const <CatalogEntry>[];
      }
    }

    try {
      final releases = await toolchain.installer.flutterReleases();
      result['flutter-sdk'] = List<CatalogEntry>.unmodifiable(
        desktopFlutterEntries(releases),
      );
      _cache['flutter-sdk'] = result['flutter-sdk']!;
    } catch (error) {
      errors['flutter-sdk'] = '$error';
      result['flutter-sdk'] = _cache['flutter-sdk'] ?? const <CatalogEntry>[];
    }
    return Map.unmodifiable(result);
  }

  Map<String, List<CatalogEntry>> get lastGood => Map.unmodifiable(_cache);

  CatalogSource sourceFor(String component) => component == 'bootstrap'
      ? bootstrap
      : sources[component] ??
            (throw StateError(strings.unknownComponentP(component)));

  /// Exact-tag lookup avoids depending on /latest or release ordering.
  Future<CatalogEntry> resolve(String component, {String? tag}) async {
    if (isDesktopPlatform) {
      final versions = await collect();
      final entries = versions[component] ?? const <CatalogEntry>[];
      final selected = tag ?? sources[component]?.defaultTag ?? '';
      for (final entry in entries) {
        if (entry.tag == selected) return entry;
      }
      throw StateError(
        '桌面端版本目录里没有 $component:$selected'
        '（请在「版本目录」里刷新后重试）',
      );
    }
    final source = sourceFor(component);
    final selected = tag ?? source.defaultTag;
    if (source.repo.isEmpty || !source.acceptsTag(selected)) {
      throw StateError(strings.noValidPReleaseConfiguredP(component, selected));
    }
    final data = await fetchJson(
      GithubMirror.wrap(
        'https://api.github.com/repos/${source.repo}/releases/tags/${Uri.encodeComponent(selected)}',
      ),
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
        url: GithubMirror.wrap(
          asset['browser_download_url'] as String? ?? '',
        ),
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
        GithubMirror.wrap(
          'https://api.github.com/repos/$repo/releases?per_page=100&page=$page',
        ),
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
    if (isDesktopPlatform) {
      if (_collecting != null) return _collecting!;
      if (!forceRefresh && _snapshot != null) return Future.value(_snapshot!);
      return _collecting = _collectDesktop()
          .then((result) {
            _snapshot = result;
            return result;
          })
          .whenComplete(() => _collecting = null);
    }
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
