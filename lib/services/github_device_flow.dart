import 'dart:convert';
import 'dart:io';

/// GitHub OAuth Device Flow（**可选增强，默认关闭**）。
///
/// 设备流需要注册一个 GitHub OAuth App，把 client_id 通过
/// `--dart-define=FLIT_GH_CLIENT_ID=...` 注入构建。没有 client_id 时
/// [configuredClientId] 为空，UI 不应显示设备流入口；Windows 版默认走
/// 「个人访问令牌（PAT）」（见 [GithubAccount.loginWithToken]）。
///
/// 注意：不要复用 gh CLI 的 client_id（第三方应用凭据，未经授权不应使用）。
class GithubDeviceFlow {
  GithubDeviceFlow({
    required this.clientId,
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  /// OAuth App 的 client_id（公开信息，设备流不需要 client_secret）。
  final String clientId;

  /// 可注入的 HttpClient 工厂（单测用 fake 传输层）。
  final HttpClient Function() _clientFactory;

  /// 构建时注入：`--dart-define=FLIT_GH_CLIENT_ID=...`
  static const String configuredClientId = String.fromEnvironment(
    'FLIT_GH_CLIENT_ID',
  );

  /// 当前构建是否配置了 client_id。
  static bool get available => configuredClientId.trim().isNotEmpty;

  static const String _deviceCodeUrl = 'https://github.com/login/device/code';
  static const String _tokenUrl = 'https://github.com/login/oauth/access_token';

  bool get enabled => clientId.trim().isNotEmpty;

  /// 申请设备码与用户码。
  Future<DeviceCode> requestCode({
    List<String> scopes = const ['repo', 'read:org', 'workflow'],
  }) async {
    if (!enabled) throw StateError('未配置 FLIT_GH_CLIENT_ID，设备流不可用');
    final data = await _postForm(_deviceCodeUrl, {
      'client_id': clientId,
      'scope': scopes.join(' '),
    });
    final interval = (data['interval'] as num?)?.toInt() ?? 5;
    final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 900;
    return DeviceCode(
      deviceCode: data['device_code'] as String? ?? '',
      userCode: data['user_code'] as String? ?? '',
      verificationUri: data['verification_uri'] as String? ?? '',
      interval: interval < 1 ? 1 : interval,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
    );
  }

  /// 轮询一次令牌端点；调用方按 [DeviceTokenResult] 决定等待/减速/结束。
  Future<DeviceTokenResult> poll(DeviceCode code) async {
    if (!enabled) throw StateError('未配置 FLIT_GH_CLIENT_ID，设备流不可用');
    if (DateTime.now().isAfter(code.expiresAt)) {
      return const DeviceTokenExpired();
    }
    final data = await _postForm(_tokenUrl, {
      'client_id': clientId,
      'device_code': code.deviceCode,
      'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
    });
    final token = data['access_token'] as String?;
    if (token != null && token.isNotEmpty) return DeviceToken(token);
    switch (data['error'] as String? ?? '') {
      case 'authorization_pending':
        return const DeviceTokenPending();
      case 'slow_down':
        return DeviceTokenSlowDown(
          (data['interval'] as num?)?.toInt() ?? code.interval + 5,
        );
      case 'expired_token':
        return const DeviceTokenExpired();
      case 'access_denied':
        return const DeviceTokenDenied();
      default:
        return DeviceTokenError(
          data['error_description'] as String? ??
              data['error'] as String? ??
              'GitHub 设备流失败',
        );
    }
  }

  /// 完整流程（申请 → 按 interval 轮询到终态）。设备码通过 [onCode] 交给 UI。
  Future<DeviceTokenResult> run({
    required void Function(DeviceCode code) onCode,
    List<String> scopes = const ['repo', 'read:org', 'workflow'],
    Future<void>? Function(Duration wait)? sleep,
  }) async {
    var code = await requestCode(scopes: scopes);
    onCode(code);
    while (true) {
      await (sleep?.call(Duration(seconds: code.interval)) ??
          Future<void>.delayed(Duration(seconds: code.interval)));
      final result = await poll(code);
      if (result is DeviceTokenSlowDown) {
        code = code.withInterval(result.interval);
        continue;
      }
      if (result is DeviceTokenPending) continue;
      return result;
    }
  }

  Future<Map<String, dynamic>> _postForm(
    String url,
    Map<String, String> fields,
  ) async {
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.postUrl(Uri.parse(url));
      request.headers.set('Accept', 'application/json');
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      request.write(Uri(queryParameters: fields).query);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw StateError('GitHub 返回了意外内容（HTTP ${response.statusCode}）');
      }
      return decoded;
    } finally {
      client.close(force: true);
    }
  }
}

/// 设备码 + 用户码（15 分钟有效）。
class DeviceCode {
  const DeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.interval,
    required this.expiresAt,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int interval;
  final DateTime expiresAt;

  DeviceCode withInterval(int value) => DeviceCode(
    deviceCode: deviceCode,
    userCode: userCode,
    verificationUri: verificationUri,
    interval: value,
    expiresAt: expiresAt,
  );
}

/// 设备流轮询结果。
sealed class DeviceTokenResult {
  const DeviceTokenResult();
}

class DeviceToken extends DeviceTokenResult {
  const DeviceToken(this.value);
  final String value;
}

class DeviceTokenPending extends DeviceTokenResult {
  const DeviceTokenPending();
}

class DeviceTokenSlowDown extends DeviceTokenResult {
  const DeviceTokenSlowDown(this.interval);
  final int interval;
}

class DeviceTokenExpired extends DeviceTokenResult {
  const DeviceTokenExpired();
}

class DeviceTokenDenied extends DeviceTokenResult {
  const DeviceTokenDenied();
}

class DeviceTokenError extends DeviceTokenResult {
  const DeviceTokenError(this.message);
  final String message;
}
