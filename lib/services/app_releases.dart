import 'dart:convert';
import 'dart:io';

import 'github_mirror.dart';

/// 应用自身的 GitHub Releases:检查更新与历史版本浏览/安装。
/// 与工具链版本目录同一姿态:匿名 API、按需拉取、失败由调用方降级。
/// 注意 /releases/latest 会排除 prerelease(本项目发布全是 preview),
/// 所以列表接口取首个,不做"latest"特判。
class AppReleases {
  AppReleases({this.repo = defaultRepo});

  static const defaultRepo = String.fromEnvironment(
    'FLIT_APP_REPO',
    defaultValue: 'lycstar/flit',
  );

  /// 构建期注入的提交号(发布资产名带其前 7 位);本地构建为 development
  static const buildSha = String.fromEnvironment(
    'BUILD_SHA',
    defaultValue: 'development',
  );

  final String repo;

  /// 可注入测试
  Future<Object?> Function(String url) fetchJson = _fetchJsonDefault;

  Future<List<AppRelease>> collect({int perPage = 30}) async {
    final releases =
        await fetchJson(
              GithubMirror.wrap(
                'https://api.github.com/repos/$repo/releases?per_page=$perPage',
              ),
            )
            as List? ??
        const [];
    return [
      for (final release in releases)
        AppRelease(
          tag: release['tag_name'] as String? ?? '',
          name: release['name'] as String? ?? '',
          prerelease: release['prerelease'] as bool? ?? false,
          publishedAt: DateTime.tryParse(
            release['published_at'] as String? ?? '',
          ),
          assets: [
            for (final asset in release['assets'] as List? ?? const [])
              AppAsset(
                name: asset['name'] as String? ?? '',
                size: asset['size'] as int? ?? 0,
                url: GithubMirror.wrap(
                  asset['browser_download_url'] as String? ?? '',
                ),
              ),
          ],
        ),
    ];
  }

  /// 当前构建是否就是 [release] 的产物(发布资产名含构建号前 7 位);
  /// 本地构建(development)无法比对,恒为 false。
  static bool shippedIn(AppRelease release) =>
      buildSha.length >= 7 && matchesBuild(release, buildSha);

  /// 资产是否由给定构建号产出(资产名内嵌构建号前 7 位)
  static bool matchesBuild(AppRelease release, String sha) =>
      sha.length >= 7 &&
      release.assets.any(
        (asset) => asset.name.contains('-${sha.substring(0, 7)}.'),
      );

  /// 下载产物到 $HOME/.flit/updates(FileProvider 的 files-path 覆盖范围,
  /// 可直接授权给系统安装器/分享面板);home 不可用时落系统临时目录。
  Future<String> download(
    AppAsset asset, {
    required String home,
    void Function(double progress)? onProgress,
  }) async {
    final base = home.isEmpty
        ? Directory.systemTemp
        : Directory('$home/.flit/updates');
    await base.create(recursive: true);
    final file = File('${base.path}/${asset.name}');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(asset.url));
      request.headers.set('User-Agent', 'Flit');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException(
          'HTTP ${response.statusCode}',
          uri: Uri.parse(asset.url),
        );
      }
      final total = response.contentLength;
      var received = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in response) {
          received += chunk.length;
          if (total > 0) onProgress?.call(received / total);
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      return file.path;
    } finally {
      client.close();
    }
  }

  static Future<Object?> _fetchJsonDefault(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'Flit');
      request.headers.set('Accept', 'application/vnd.github+json');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      return jsonDecode(await response.transform(utf8.decoder).join());
    } finally {
      client.close();
    }
  }
}

/// 一条发布(含 prerelease 标记与产物列表)
class AppRelease {
  const AppRelease({
    required this.tag,
    required this.name,
    required this.prerelease,
    required this.assets,
    this.publishedAt,
  });
  final String tag;
  final String name;
  final bool prerelease;
  final DateTime? publishedAt;
  final List<AppAsset> assets;
}

/// 发布产物;APK 可安装,其余只提供下载
class AppAsset {
  const AppAsset({required this.name, required this.size, required this.url});
  final String name;
  final int size;
  final String url;

  bool get isApk => name.toLowerCase().endsWith('.apk');
}
