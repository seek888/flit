import 'dart:async';
import 'dart:io';

import 'github_mirror.dart';
import 'toolchain/layout.dart';

typedef NetProbeTarget = ({String name, String url});
typedef NetProbeFunction = Future<int> Function(Uri uri, Duration timeout);

class NetProbeResult {
  const NetProbeResult({
    required this.name,
    required this.url,
    required this.code,
    required this.seconds,
  });

  final String name;
  final String url;

  /// HTTP 状态码；`0` 表示超时/无响应（脚本里是 `000`）。
  final int code;
  final double seconds;

  bool get ok => code != 0;

  /// 与 `net_probe.sh` 相同的协议：`__NET__<目标>:<HTTP码>|<耗时秒>`。
  String get marker => '__NET__$name:$code|${seconds.toStringAsFixed(2)}';

  String get detail => ok
      ? 'HTTP $code（${seconds.toStringAsFixed(2)}s）'
      : '请求失败/超时（${seconds.toStringAsFixed(2)}s）';
}

/// `net_probe.sh` 的纯 Dart 对等实现：探测 pub 镜像 / Flutter 镜像 /
/// Gradle / Maven / GitHub / 基础出网，输出同一 `__NET__` 协议。
///
/// 任何 HTTP 应答都算通路存在（包括 3xx/4xx）；超时或连接失败记 `0`。
class NetProbe {
  NetProbe({
    NetProbeFunction? probe,
    this.timeout = const Duration(seconds: 8),
    List<NetProbeTarget>? targets,
    String? githubMirrorPrefix,
    String? pubHostedUrl,
    String? flutterStorageBaseUrl,
  }) : _probe = probe ?? _defaultProbe,
       targets =
           targets ??
           defaultTargets(
             githubMirrorPrefix: githubMirrorPrefix ?? GithubMirror.prefix,
             pubHostedUrl: pubHostedUrl ?? ToolchainLayout.defaultPubHostedUrl,
             flutterStorageBaseUrl:
                 flutterStorageBaseUrl ??
                 ToolchainLayout.defaultFlutterStorageBaseUrl,
           );

  final NetProbeFunction _probe;
  final Duration timeout;
  final List<NetProbeTarget> targets;

  Stream<NetProbeResult> probeAll() async* {
    for (final target in targets) {
      yield await probeOne(target);
    }
  }

  Future<NetProbeResult> probeOne(NetProbeTarget target) async {
    final stopwatch = Stopwatch()..start();
    var code = 0;
    try {
      code = await _probe(Uri.parse(target.url), timeout);
    } catch (_) {
      code = 0;
    }
    return NetProbeResult(
      name: target.name,
      url: target.url,
      code: code,
      seconds: stopwatch.elapsedMicroseconds / 1000000,
    );
  }

  static List<NetProbeTarget> defaultTargets({
    required String githubMirrorPrefix,
    required String pubHostedUrl,
    required String flutterStorageBaseUrl,
  }) {
    final pub = pubHostedUrl.replaceAll(RegExp(r'/+$'), '');
    final storage = flutterStorageBaseUrl.replaceAll(RegExp(r'/+$'), '');
    return <NetProbeTarget>[
      (name: 'Google', url: 'https://www.google.com/generate_204'),
      (name: 'GitHub', url: 'https://github.com'),
      if (githubMirrorPrefix.isNotEmpty)
        (name: 'GitHub镜像', url: '${githubMirrorPrefix}https://github.com'),
      (name: 'pub镜像', url: pub),
      (
        name: 'Flutter镜像',
        url: '$storage/flutter_infra_release/releases/releases_windows.json',
      ),
      (name: 'Gradle', url: 'https://services.gradle.org/distributions/'),
      (name: 'Maven', url: 'https://repo.maven.apache.org/maven2/'),
      (
        name: 'Google Maven',
        url: 'https://dl.google.com/android/repository/repository2-3.xml',
      ),
      (name: '百度', url: 'https://www.baidu.com'),
    ];
  }

  static Future<int> _defaultProbe(Uri uri, Duration timeout) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'FlitDesk/1.0');
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }
}
