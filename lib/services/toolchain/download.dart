import 'dart:async';
import 'dart:io';

import 'errors.dart';
import 'hash.dart';

/// 一次 HTTP 获取的结果。[body] 是未消费的响应流；消费完（或取消）后
/// 内部 HttpClient 会自动关闭。
class HttpFetchResult {
  const HttpFetchResult({
    required this.statusCode,
    required this.finalUri,
    required this.headers,
    required this.body,
    this.contentLength,
  });

  final int statusCode;
  final Uri finalUri;

  /// 头部名统一小写。
  final Map<String, String> headers;
  final Stream<List<int>> body;
  final int? contentLength;
}

/// 下载传输层（单测注入 fake，完全离线）。
abstract class HttpTransport {
  Future<HttpFetchResult> open(Uri uri, {Map<String, String>? headers});
}

class HttpClientTransport implements HttpTransport {
  HttpClientTransport({
    this.connectionTimeout = const Duration(seconds: 30),
    this.userAgent = 'FlitDesk/1.0',
  });

  final Duration connectionTimeout;
  final String userAgent;

  @override
  Future<HttpFetchResult> open(Uri uri, {Map<String, String>? headers}) async {
    final client = HttpClient()..connectionTimeout = connectionTimeout;
    try {
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', userAgent);
      headers?.forEach((key, value) => request.headers.set(key, value));
      final response = await request.close();
      final headerMap = <String, String>{};
      response.headers.forEach((name, values) {
        headerMap[name.toLowerCase()] = values.join(',');
      });
      final contentLength = response.contentLength >= 0
          ? response.contentLength
          : null;
      final body = () async* {
        try {
          yield* response;
        } finally {
          client.close(force: true);
        }
      }();
      return HttpFetchResult(
        statusCode: response.statusCode,
        finalUri: uri,
        headers: headerMap,
        body: body,
        contentLength: contentLength,
      );
    } catch (error) {
      client.close(force: true);
      rethrow;
    }
  }
}

/// 带进度、重定向、超时、SHA-256 校验的下载器。
///
/// 缓存规则（修复旧实现「>1 MB 就算下好了」的坏包问题）：
/// - 有 sha256 → 必须匹配才复用；
/// - 无 sha256 但有已知大小 → 大小必须相等；
/// - 都没有 → 记录首次摘要作 TOFU（`<file>.sha256`），后续按它校验；
/// - 小于 1 MB 且无大小/摘要的残包一律不复用。
class Downloader {
  Downloader({HttpTransport? transport})
    : transport = transport ?? HttpClientTransport();

  final HttpTransport transport;

  static const int minimumCompleteSize = 1024 * 1024;

  /// 下载到 [destination]，成功返回实际 SHA-256（小写十六进制）。
  Future<String> download(
    String url,
    String destination, {
    String? sha256,
    int? expectedSize,
    void Function(int received, int total)? onProgress,
    Duration idleTimeout = const Duration(seconds: 60),
    Duration totalTimeout = const Duration(minutes: 45),
    bool Function()? isCancelled,
    bool useCache = true,
    String? label,
  }) async {
    final target = File(destination);
    final name = label ?? _fileName(destination);
    final wanted = sha256?.trim().toLowerCase();

    if (useCache) {
      final cached = await _validateCache(
        target,
        sha256: wanted,
        expectedSize: expectedSize,
      );
      if (cached != null) {
        onProgress?.call(target.lengthSync(), target.lengthSync());
        return cached;
      }
      _deleteQuietly(target);
    }

    target.parent.createSync(recursive: true);
    final part = File('$destination.part');
    _deleteQuietly(part);

    final digest = Sha256Digest();
    final sink = part.openWrite();
    int received;
    int total;
    try {
      final result = await _writeBody(
        url: url,
        sink: sink,
        digest: digest,
        onProgress: onProgress ?? (_, _) {},
        idleTimeout: idleTimeout,
        totalTimeout: totalTimeout,
        isCancelled: isCancelled,
        label: name,
      );
      received = result.received;
      total = result.total;
      await sink.flush();
      await sink.close();
    } catch (error) {
      try {
        await sink.close();
      } catch (_) {}
      _deleteQuietly(part);
      rethrow;
    }

    if (received == 0) {
      _deleteQuietly(part);
      throw DownloadException('下载内容为空：$name（$url）');
    }
    if (expectedSize != null && expectedSize > 0 && received != expectedSize) {
      _deleteQuietly(part);
      throw DownloadException(
        '下载大小不符：$name 期望 $expectedSize 字节，实际 $received 字节',
      );
    }
    final actual = digest.close();
    if (wanted != null &&
        wanted.isNotEmpty &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(wanted)) {
      _deleteQuietly(part);
      throw DownloadException('摘要格式无效：$wanted');
    }
    if (wanted != null && wanted.isNotEmpty && actual != wanted) {
      _deleteQuietly(part);
      throw DownloadException(
        'SHA-256 校验失败：$name 期望 $wanted，实际 $actual；'
        '已丢弃坏包，请检查网络（代理/镜像可能被篡改）后重试',
      );
    }

    _deleteQuietly(target);
    part.renameSync(destination);
    _writeSidecar(destination, actual);
    onProgress?.call(received, total == 0 ? received : total);
    return actual;
  }

  /// 按顺序尝试多个候选地址（镜像在前、官方/直连在后），第一个成功即返回。
  ///
  /// 失败会删掉半截包再换下一个源；全部失败时抛出聚合异常，把每个源的
  /// 失败原因带出来（国内常见「这个代理挂了、那个镜像还活着」，需要能解释）。
  /// 缓存校验对每个候选都生效：缓存命中且摘要匹配时不会发起任何请求。
  Future<({String url, String sha256})> downloadFirst(
    List<String> urls,
    String destination, {
    String? sha256,
    int? expectedSize,
    void Function(int received, int total)? onProgress,
    Duration idleTimeout = const Duration(seconds: 60),
    Duration totalTimeout = const Duration(minutes: 45),
    bool Function()? isCancelled,
    bool useCache = true,
    String? label,
  }) async {
    final attempted = <String>[];
    final failures = <String>[];
    Object? lastError;
    for (final url in urls) {
      if (url.isEmpty || attempted.contains(url)) continue;
      attempted.add(url);
      try {
        final digest = await download(
          url,
          destination,
          sha256: sha256,
          expectedSize: expectedSize,
          onProgress: onProgress,
          idleTimeout: idleTimeout,
          totalTimeout: totalTimeout,
          isCancelled: isCancelled,
          useCache: useCache,
          label: label,
        );
        return (url: url, sha256: digest);
      } catch (error) {
        lastError = error;
        failures.add('$url（${_shortError(error)}）');
        _deleteQuietly(File('$destination.part'));
      }
    }
    final name = label ?? _fileName(destination);
    throw DownloadException(
      '$name 的所有下载源均失败：\n${failures.join('\n')}',
      cause: lastError,
    );
  }

  static String _shortError(Object error) {
    final text = error is DownloadException ? error.message : '$error';
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }

  Future<({int received, int total})> _writeBody({
    required String url,
    required IOSink sink,
    required Sha256Digest digest,
    required void Function(int received, int total) onProgress,
    required Duration idleTimeout,
    required Duration totalTimeout,
    required bool Function()? isCancelled,
    required String label,
  }) async {
    var uri = Uri.parse(url);
    var total = 0;
    var received = 0;
    var redirects = 0;
    final stopwatch = Stopwatch()..start();
    var lastPercent = -1;
    var lastProgressMs = -500;

    while (true) {
      final HttpFetchResult response;
      try {
        response = await transport
            .open(uri)
            .timeout(const Duration(seconds: 60));
      } on TimeoutException {
        throw DownloadException('连接下载服务器超时：$uri');
      } catch (error) {
        throw DownloadException('无法连接下载服务器：$uri', cause: error);
      }

      if (_isRedirect(response.statusCode)) {
        final location = response.headers['location'];
        await response.body.drain<void>().catchError((Object _) {});
        if (location == null || location.isEmpty) {
          throw DownloadException(
            '服务器返回 ${response.statusCode} 重定向但没有 Location：$uri',
          );
        }
        redirects++;
        if (redirects > 8) {
          throw DownloadException('重定向次数过多（>8）：$url');
        }
        final next = Uri.parse(location);
        uri = next.isAbsolute ? next : uri.resolveUri(next);
        continue;
      }

      if (response.statusCode >= 400) {
        await response.body.drain<void>().catchError((Object _) {});
        throw DownloadException('HTTP ${response.statusCode}：$uri');
      }

      total = response.contentLength ?? total;
      try {
        final stream = response.body.timeout(
          idleTimeout,
          onTimeout: (EventSink<List<int>> eventSink) {
            eventSink.addError(
              TimeoutException('下载空闲超时（${idleTimeout.inSeconds} 秒无数据）'),
            );
            eventSink.close();
          },
        );
        await for (final chunk in stream) {
          if (isCancelled?.call() ?? false) {
            throw DownloadException('下载已取消：$label');
          }
          if (stopwatch.elapsed > totalTimeout) {
            throw DownloadException(
              '下载超时（超过 ${totalTimeout.inMinutes} 分钟）：$uri',
            );
          }
          sink.add(chunk);
          digest.add(chunk);
          received += chunk.length;
          final percent = total > 0 ? received * 100 ~/ total : 0;
          final now = stopwatch.elapsedMilliseconds;
          if (percent != lastPercent ||
              now - lastProgressMs >= 500 ||
              (total > 0 && received >= total)) {
            lastPercent = percent;
            lastProgressMs = now;
            onProgress(received, total);
          }
        }
      } on TimeoutException {
        throw DownloadException(
          '下载空闲超时（${idleTimeout.inSeconds} 秒没有收到数据）：$uri',
        );
      } on DownloadException {
        rethrow;
      } catch (error) {
        throw DownloadException('下载中断：$uri', cause: error);
      }
      return (received: received, total: total);
    }
  }

  Future<String?> _validateCache(
    File file, {
    required String? sha256,
    required int? expectedSize,
  }) async {
    if (!file.existsSync()) return null;
    final length = file.lengthSync();
    if (length <= 0) return null;

    if (sha256 != null && sha256.isNotEmpty) {
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) return null;
      final actual = await sha256OfFile(file.path);
      return actual == sha256 ? actual : null;
    }

    if (expectedSize != null && expectedSize > 0 && length != expectedSize) {
      return null;
    }

    final sidecar = File('${file.path}.sha256');
    if (sidecar.existsSync()) {
      final expected = sidecar.readAsStringSync().trim().toLowerCase();
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expected)) return null;
      final actual = await sha256OfFile(file.path);
      return actual == expected ? actual : null;
    }

    // 没有摘要也没有已知大小：残包（< 1 MB）不可复用。
    if (expectedSize == null && length < minimumCompleteSize) return null;
    final actual = await sha256OfFile(file.path);
    _writeSidecar(file.path, actual);
    return actual;
  }

  void _writeSidecar(String path, String digest) {
    try {
      File('$path.sha256').writeAsStringSync('$digest\n');
    } catch (_) {}
  }

  static bool _isRedirect(int code) =>
      code == 301 || code == 302 || code == 303 || code == 307 || code == 308;

  static String _fileName(String path) =>
      path
          .split(RegExp(r'[/\\]'))
          .where((part) => part.isNotEmpty)
          .lastOrNull ??
      path;

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}
