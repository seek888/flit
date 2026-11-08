import 'package:flit/l10n/strings.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/git_credentials.dart';
import '../../services/github_device_flow.dart';
import '../../services/shell.dart';
import '../terminal/console_session.dart';

enum GithubAuth { missing, signedOut, credentialsSaved }

/// gh 的探测结果(命令退出码 + 输出), 与 GitRepo 的 execute 形态一致, 便于测试注入。
typedef GithubProbe = Future<({int code, String out})> Function(String command);

/// 一次 GitHub API 调用的结果（纯 Dart HttpClient，不依赖 gh CLI）。
typedef GithubApiCall =
    Future<({int status, String body})> Function(Uri uri, {String? token});

/// GitHub 账户是全局的, 不属于某个工程。
///
/// **Android**：登录走 gh Device Flow（浏览器授权 → gh 轮询拿令牌 →
/// `gh auth setup-git` 接上 git 凭据助手）。
///
/// **桌面（Windows/Linux/macOS）**：不依赖 gh CLI（DesktopToolchain 不装 gh）。
/// 登录方式以「个人访问令牌（PAT）」为主——设置页/GitHub 卡片提供输入入口,
/// 纯 Dart `GET https://api.github.com/user` 校验；成功后把凭据写入
/// `<home>\.flit\gitconfig` + `<home>\.flit\git-credentials`（见
/// [GitCredentials]），所有 git 进程经 `GIT_CONFIG_GLOBAL` 自动使用。
/// 设备流（OAuth App）需要 `--dart-define=FLIT_GH_CLIENT_ID=...`，默认关闭。
class GithubAccount extends ChangeNotifier {
  GithubAccount({
    required ProcessLauncher launcher,
    GithubProbe? probe,
    GitCredentials? credentials,
    GithubApiCall? api,
  }) : _launcher = launcher,
       _probe = probe ?? _shellProbe,
       _credentials = credentials ?? GitCredentials(),
       _api = api ?? _httpGet;

  final ProcessLauncher _launcher;
  final GithubProbe _probe;
  final GitCredentials _credentials;
  final GithubApiCall _api;

  GithubAuth auth = GithubAuth.signedOut;
  bool busy = false;
  String? error;

  /// 登录账户的展示档案; 离线或未登录时为空
  String? loginName;
  String? name;
  String? avatarUrl;

  /// 登录中的一次性授权码; 非空时调用方弹对话框, 登录结束置空(对话框自动关)
  final deviceCode = ValueNotifier<String?>(null);
  ConsoleSession? _console;
  Future<void>? _refreshing;
  bool _disposed = false;

  /// 桌面端的凭据读取是真实文件 IO：页面销毁后才回来时不能再 notify。
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static const loginCommand =
      'LC_ALL=C gh auth login --hostname github.com --git-protocol https --web </dev/null '
      '&& gh auth setup-git --hostname github.com';
  static const logoutCommand =
      'gh auth logout --hostname github.com </dev/null';

  static const String apiUserUrl = 'https://api.github.com/user';

  /// 桌面端固定的 git 凭据用户名：GitHub 接受「令牌当密码、用户名任意」，
  /// 官方推荐 `x-access-token`。
  static const String tokenUsername = 'x-access-token';

  bool get signedIn => auth == GithubAuth.credentialsSaved;

  /// 桌面端（非 Android）分支。
  bool get isDesktop => isDesktopPlatform;

  /// 设备流入口是否可用（构建时注入了 OAuth App client_id 才显示）。
  bool get deviceFlowAvailable => isDesktop && GithubDeviceFlow.available;

  static Future<({int code, String out})> _shellProbe(String command) async {
    final result = await Shell.instance.exec(
      '$terminalEnvSource$command',
      timeoutMs: 15000,
    );
    return (
      code: result['exitCode'] as int? ?? -1,
      out: result['output'] as String? ?? '',
    );
  }

  /// 默认 API 实现：纯 dart:io HttpClient，Bearer 令牌。
  static Future<({int status, String body})> _httpGet(
    Uri uri, {
    String? token,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(uri);
      request.headers.set('Accept', 'application/vnd.github+json');
      request.headers.set('X-GitHub-Api-Version', '2022-11-28');
      request.headers.set('User-Agent', 'FlitDesk/1.0');
      if (token != null && token.isNotEmpty) {
        request.headers.set('Authorization', 'Bearer $token');
      }
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return (status: response.statusCode, body: body);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    if (isDesktop) return _refreshDesktop();
    try {
      final installed = await _probe('command -v gh >/dev/null 2>&1');
      if (installed.code != 0) {
        auth = GithubAuth.missing;
      } else {
        final token = await _probe(
          'gh auth token --hostname github.com >/dev/null 2>&1',
        );
        auth = token.code == 0
            ? GithubAuth.credentialsSaved
            : GithubAuth.signedOut;
      }
    } catch (_) {
      // 环境未就绪(还没有 bash)等情况保持上次状态
      _notify();
      return;
    }
    // 档案供界面显示头像与名称; 拉取失败不影响登录态
    if (auth == GithubAuth.credentialsSaved) {
      try {
        final profile = await _probe('gh api user');
        _applyProfile(jsonDecode(profile.out) as Map? ?? const {});
      } catch (_) {
        /* 保持已有档案 */
      }
    } else {
      loginName = name = avatarUrl = null;
    }
    _notify();
  }

  /// 桌面端刷新：凭据文件是否存在 → 登录态；有令牌则顺便拉一次档案。
  Future<void> _refreshDesktop() async {
    try {
      final saved = await _credentials.load(GitCredentials.githubHost);
      auth = saved == null ? GithubAuth.signedOut : GithubAuth.credentialsSaved;
      if (saved != null) {
        await _loadProfile(saved.token);
      } else {
        loginName = name = avatarUrl = null;
      }
    } catch (_) {
      // 凭据文件不可读时保持上次状态
      _notify();
      return;
    }
    _notify();
  }

  Future<void> _loadProfile(String token) async {
    try {
      final profile = await _api(Uri.parse(apiUserUrl), token: token);
      if (profile.status != 200) return;
      _applyProfile(jsonDecode(profile.body) as Map? ?? const {});
    } catch (_) {
      /* 保持已有档案 */
    }
  }

  void _applyProfile(Map data) {
    loginName = data['login'] as String?;
    name = data['name'] as String?;
    avatarUrl = data['avatar_url'] as String?;
  }

  /// 桌面端：用个人访问令牌登录。
  ///
  /// 校验 `GET https://api.github.com/user`（Bearer），成功后写
  /// gitconfig/git-credentials。令牌需要 `repo` scope（私有库克隆/推送）。
  Future<bool> loginWithToken(String token) async {
    final value = token.trim();
    if (busy) return false;
    if (!isDesktop) return false; // Android 用 gh 设备流
    if (value.isEmpty) {
      error = stringsDesktopEnterToken;
      _notify();
      return false;
    }
    busy = true;
    error = null;
    _notify();
    try {
      final result = await _api(Uri.parse(apiUserUrl), token: value);
      if (result.status != 200) {
        error = _tokenError(result.status);
        return false;
      }
      final data = jsonDecode(result.body) as Map? ?? const {};
      _applyProfile(data);
      final login = loginName ?? 'github-user';
      final id = data['id'];
      final email = (data['email'] as String?)?.trim().isNotEmpty == true
          ? data['email'] as String
          : (id != null
                ? '$id+$login@users.noreply.github.com'
                : '$login@users.noreply.github.com');
      await _credentials.save(
        host: GitCredentials.githubHost,
        username: tokenUsername,
        token: value,
        name: name ?? login,
        email: email,
      );
      auth = GithubAuth.credentialsSaved;
      return true;
    } catch (e) {
      error = stringsDesktopSignInFailedP(e);
      return false;
    } finally {
      busy = false;
      _notify();
      await _refresh();
    }
  }

  String _tokenError(int status) => switch (status) {
    401 => stringsDesktopTokenInvalid,
    403 => stringsDesktopTokenForbidden, // 权限不足/被限流
    _ => stringsDesktopSignInHttpFailureP(status),
  };

  /// 「登录」按钮入口。
  ///
  /// Android：gh Device Flow。桌面：设备流需要构建时 client_id，默认关闭，
  /// 提示去「设置 → GitHub 账户」粘贴 PAT（[loginWithToken]）。
  Future<bool> login() async {
    if (isDesktop) {
      error = deviceFlowAvailable
          ? stringsDesktopDeviceFlowHint
          : stringsDesktopUseTokenInstead;
      _notify();
      return false;
    }
    if (busy) return false;
    if (auth == GithubAuth.missing) {
      error = strings.ghIsNotInstalledCompleteTheFlutter708;
      _notify();
      return false;
    }
    busy = true;
    error = null;
    deviceCode.value = null;
    _notify();
    final console = _console = ConsoleSession(
      title: strings.githubSignIn,
      launcher: _launcher,
    );
    var output = '';
    final watch = console.textStream.listen((chunk) {
      // 授权码可能被 ANSI 色码和数据块边界切开: 去色后在累计文本上匹配
      output = '$output$chunk'.replaceAll(
        RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'),
        '',
      );
      if (output.length > 8192) output = output.substring(output.length - 8192);
      final match = RegExp(
        r'one-time code:\s*([A-Z0-9]{4}-[A-Z0-9]{4})',
      ).firstMatch(output);
      if (match != null && deviceCode.value != match.group(1)) {
        deviceCode.value = match.group(1);
      }
    });
    try {
      // 授权码 15 分钟过期, gh 轮询到期自行退出; 超时兜底再长一点
      final code = await console.run(
        loginCommand,
        timeout: const Duration(minutes: 16),
      );
      if (code != 0) {
        final tail = output
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .lastOrNull;
        error = console.stopRequested
            ? strings.signInCancelled
            : strings.signInIncompleteExitCodePP(
                code,
                tail == null ? '' : '：$tail',
              );
      }
      return code == 0;
    } catch (e) {
      error = strings.signInFailedP(e);
      return false;
    } finally {
      await watch.cancel();
      deviceCode.value = null;
      _console = null;
      unawaited(console.close());
      busy = false;
      await _refresh();
    }
  }

  /// 对话框「取消登录」: 结束 gh 的轮询
  Future<void> cancelLogin() async => _console?.stop();

  Future<bool> logout() async {
    if (busy) return false;
    busy = true;
    error = null;
    _notify();
    if (isDesktop) {
      try {
        await _credentials.clear(GitCredentials.githubHost);
        auth = GithubAuth.signedOut;
        loginName = name = avatarUrl = null;
        return true;
      } catch (e) {
        error = stringsDesktopSignOutFailedP(e);
        return false;
      } finally {
        busy = false;
        _notify();
        await _refresh();
      }
    }
    final console = ConsoleSession(
      title: strings.githubSignOut,
      launcher: _launcher,
    );
    try {
      final code = await console.run(
        logoutCommand,
        timeout: const Duration(seconds: 30),
      );
      if (code != 0) error = strings.githubSignOutIncompleteExitCodeP(code);
      return code == 0;
    } catch (e) {
      error = strings.githubSignOutFailedP(e);
      return false;
    } finally {
      unawaited(console.close());
      busy = false;
      await _refresh();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    deviceCode.dispose();
    super.dispose();
  }
}

/// 桌面端「粘贴个人访问令牌」对话框：返回令牌文本（用户取消返回 null）。
///
/// 设置页、克隆页、版本控制面板共用；令牌不写日志、不显示明文（obscureText）。
Future<String?> showGithubTokenDialog(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('登录 GitHub（个人访问令牌）'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(stringsDesktopEnterToken),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Personal Access Token',
                  hintText: 'ghp_... 或 github_pat_...',
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                onPressed: () => Shell.instance.openUrl(
                  'https://github.com/settings/tokens/new?scopes=repo&description=Flit',
                ),
                icon: const Icon(Icons.open_in_new, size: 14),
                label: const Text(
                  '在 GitHub 生成令牌（勾选 repo 权限）',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final token = controller.text.trim();
                if (token.isEmpty) return;
                Navigator.pop(context, token);
              },
              child: const Text('登录'),
            ),
          ],
        ),
      );
    },
  );
}

// ---------- 桌面端新增文案（services/features 层暂不依赖 l10n 资源；
// 后续可迁到 strings.xxx，届时删除这组常量）----------

/// 桌面端 PAT 输入框的提示。
const String stringsDesktopEnterToken =
    '请粘贴 GitHub 个人访问令牌（Personal Access Token，需勾选 repo 权限）';

const String stringsDesktopTokenInvalid = '令牌无效或已过期（HTTP 401），请重新生成';

const String stringsDesktopTokenForbidden =
    '令牌权限不足或被限流（HTTP 403），请确认令牌已勾选 repo 权限';

String stringsDesktopSignInHttpFailureP(int status) =>
    'GitHub 校验失败（HTTP $status）';

String stringsDesktopSignInFailedP(Object error) => 'GitHub 登录失败：$error';

const String stringsDesktopUseTokenInstead =
    '桌面版请在 设置 → GitHub 账户 中粘贴个人访问令牌（PAT）登录';

const String stringsDesktopDeviceFlowHint =
    '设备流未启用：请在 设置 → GitHub 账户 中粘贴个人访问令牌（PAT）登录';

String stringsDesktopSignOutFailedP(Object error) => 'GitHub 退出登录失败：$error';
