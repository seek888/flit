import 'dart:io';

import '../core/host_platform.dart';
import 'desktop_toolchain.dart';
import 'paths.dart';

/// GitHub（以及任意 HTTPS git 主机）的凭据落盘。
///
/// 两个文件，都在 `<DesktopToolchain.home>\.flit\`（app 私有目录）里：
///
/// - `gitconfig`：通过 `credential.helper=store --file=...` 指向下面的
///   `git-credentials`，并写入 `user.name/email` 与 `http.sslVerify=true`；
/// - `git-credentials`：一行一个 `https://<username>:<token>@<host>`。
///
/// 所有 git 进程通过 `GIT_CONFIG_GLOBAL` 指向这份 gitconfig（见
/// [GitProcess.environment]），因此**不会**写用户的 `~/.gitconfig`，也不依赖
/// Git Credential Manager（MinGit 不自带 GCM，见 02-features.md §5.4）。
class GitCredentials {
  GitCredentials({String? home}) : home = home ?? DesktopToolchain().home;

  /// 应用私有根目录（Windows 默认 `%LOCALAPPDATA%\FlitDesk`）。
  final String home;

  /// 默认 GitHub 主机名。
  static const String githubHost = 'github.com';

  /// `<home>\.flit`
  String get configDir => joinPath(home, '.flit');

  /// `<home>\.flit\gitconfig`
  String get globalConfigPath => joinPath(configDir, 'gitconfig');

  /// `<home>\.flit\git-credentials`
  String get storePath => joinPath(configDir, 'git-credentials');

  /// 写 gitconfig + 追加/替换 credentials 行。
  ///
  /// [name]/[email] 为空时保留 gitconfig 里已有的值（`git config --local` 的
  /// 仓库级身份优先，这里只是全局兜底，避免首次 commit 因缺身份失败）。
  Future<void> save({
    required String host,
    required String username,
    required String token,
    String? name,
    String? email,
  }) async {
    final directory = Directory(configDir);
    if (!directory.existsSync()) directory.createSync(recursive: true);

    final current = _readExistingConfig();
    final effectiveName = _clean(name) ?? current.name;
    final effectiveEmail = _clean(email) ?? current.email;
    await _writeConfig(name: effectiveName, email: effectiveEmail);
    await _upsertCredential(host: host, username: username, token: token);
    await _restrictPermissions();
  }

  /// 读回某个主机的凭据；没有则返回 null。
  Future<({String username, String token})?> load(String host) async {
    final file = File(storePath);
    if (!file.existsSync()) return null;
    final lines = await _readLines(file);
    for (final line in lines) {
      final parsed = parseCredentialLine(line, host);
      if (parsed != null) return parsed;
    }
    return null;
  }

  /// 是否已经保存过某主机的凭据。
  Future<bool> has(String host) async => await load(host) != null;

  /// 清掉某主机的凭据行；gitconfig 保留 user 身份。
  ///
  /// 只有 store 里还剩别的凭据时才保留 `[credential] helper`；全清空后
  /// 不再指向一个不存在的凭据文件（否则 git 会报 helper 读取失败）。
  Future<void> clear(String host) async {
    final file = File(storePath);
    var keepHelper = false;
    if (file.existsSync()) {
      final kept = (await _readLines(
        file,
      )).where((line) => parseCredentialLine(line, host) == null).toList();
      if (kept.isEmpty) {
        try {
          await file.delete();
        } catch (_) {}
      } else {
        await file.writeAsString('${kept.join('\n')}\n');
        keepHelper = true;
      }
    }
    final current = _readExistingConfig();
    await _writeConfig(
      name: current.name,
      email: current.email,
      includeCredential: keepHelper,
    );
  }

  /// gitconfig 文本（测试直接断言内容；[storeFile] 默认用 [storePath]）。
  ///
  /// 注意路径一律用 `/`：gitconfig 的双引号值里 `\` 会被当作转义符，
  /// Windows 的 `C:\Users\...` 会破坏 helper 参数。
  String buildGitConfig({
    String? name,
    String? email,
    String? storeFile,
    bool includeCredential = true,
  }) {
    final helper =
        'store --file=${(storeFile ?? storePath).replaceAll(r'\', '/')}';
    final buffer = StringBuffer()
      ..writeln('# 由 Flit 写入：GitHub 凭据与提交身份，不修改系统/用户全局配置。');
    if (includeCredential) {
      buffer
        ..writeln('[credential]')
        ..writeln('\thelper = "$helper"');
    }
    buffer
      ..writeln('[http]')
      ..writeln('\tsslVerify = true');
    final cleanName = _clean(name);
    final cleanEmail = _clean(email);
    if (cleanName != null || cleanEmail != null) {
      buffer.writeln('[user]');
      if (cleanName != null) buffer.writeln('\tname = $cleanName');
      if (cleanEmail != null) buffer.writeln('\temail = $cleanEmail');
    }
    return buffer.toString();
  }

  /// `https://<username>:<token>@<host>`（GitHub 的 PAT 用户名用
  /// `x-access-token`，密码位置放令牌）。
  static String credentialLine({
    required String host,
    required String username,
    required String token,
  }) => 'https://$username:$token@$host';

  /// 解析一行 credentials；主机不匹配返回 null。
  static ({String username, String token})? parseCredentialLine(
    String line,
    String host,
  ) {
    final value = line.trim();
    if (value.isEmpty) return null;
    final prefix = 'https://';
    if (!value.startsWith(prefix)) return null;
    final at = value.lastIndexOf('@');
    if (at <= prefix.length) return null;
    final userInfo = value.substring(prefix.length, at);
    final hostPart = value.substring(at + 1).split('/').first;
    if (hostPart.toLowerCase() != host.toLowerCase()) return null;
    final colon = userInfo.indexOf(':');
    if (colon <= 0) return null;
    return (
      username: userInfo.substring(0, colon),
      token: userInfo.substring(colon + 1),
    );
  }

  Future<void> _writeConfig({
    String? name,
    String? email,
    bool includeCredential = true,
  }) async {
    final file = File(globalConfigPath);
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    await file.writeAsString(
      buildGitConfig(
        name: name,
        email: email,
        includeCredential: includeCredential,
      ),
    );
  }

  Future<void> _upsertCredential({
    required String host,
    required String username,
    required String token,
  }) async {
    final file = File(storePath);
    final kept = file.existsSync()
        ? (await _readLines(
            file,
          )).where((line) => parseCredentialLine(line, host) == null).toList()
        : <String>[];
    kept.add(credentialLine(host: host, username: username, token: token));
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    await file.writeAsString('${kept.join('\n')}\n');
  }

  Future<List<String>> _readLines(File file) async {
    try {
      return (await file.readAsString())
          .split(RegExp(r'\r?\n'))
          .where((line) => line.trim().isNotEmpty)
          .toList();
    } catch (_) {
      return const <String>[];
    }
  }

  /// 从已有 gitconfig 里取 user.name / user.email（保存/清除时保留身份）。
  ///
  /// 逐行解析而不是用正则切 section：Dart 的 ECMAScript 正则没有 `\z`，
  /// `(?=^\[|\z)` 这类写法永远不匹配（踩过一次）。
  ({String? name, String? email}) _readExistingConfig() {
    final file = File(globalConfigPath);
    if (!file.existsSync()) return (name: null, email: null);
    try {
      String? name;
      String? email;
      var section = '';
      for (final raw in file.readAsStringSync().split(RegExp(r'\r?\n'))) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
          continue;
        }
        if (line.startsWith('[')) {
          final close = line.indexOf(']');
          section = (close > 0 ? line.substring(1, close) : '')
              .split(RegExp(r'[\s"]'))
              .first
              .toLowerCase();
          continue;
        }
        if (section != 'user') continue;
        final equals = line.indexOf('=');
        if (equals <= 0) continue;
        final key = line.substring(0, equals).trim().toLowerCase();
        final value = _clean(line.substring(equals + 1));
        if (key == 'name') name = value;
        if (key == 'email') email = value;
      }
      return (name: name, email: email);
    } catch (_) {
      return (name: null, email: null);
    }
  }

  static String? _clean(String? value) {
    if (value == null) return null;
    var cleaned = value.trim();
    if (cleaned.length >= 2 &&
        cleaned.startsWith('"') &&
        cleaned.endsWith('"')) {
      cleaned = cleaned.substring(1, cleaned.length - 1);
    }
    return cleaned.isEmpty ? null : cleaned;
  }

  /// POSIX 上收紧文件权限（Windows 由 app 私有目录 ACL 兜底）。
  Future<void> _restrictPermissions() async {
    if (isWindowsPlatform) return;
    for (final path in [globalConfigPath, storePath]) {
      try {
        await Process.run('chmod', ['600', path]);
      } catch (_) {}
    }
  }
}
