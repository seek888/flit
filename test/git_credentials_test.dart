import 'dart:io';

import 'package:flit/services/git_credentials.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory home;
  late GitCredentials credentials;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('flit-git-credentials-');
    credentials = GitCredentials(home: home.path);
  });

  tearDown(() async {
    if (home.existsSync()) await home.delete(recursive: true);
  });

  test('路径：gitconfig 与 git-credentials 都在 app 私有目录', () {
    expect(credentials.configDir, endsWith('.flit'));
    expect(credentials.globalConfigPath, endsWith('gitconfig'));
    expect(credentials.storePath, endsWith('git-credentials'));
    expect(credentials.globalConfigPath, contains('.flit'));
  });

  test(
    'save 生成 gitconfig：credential.helper=store + user + sslVerify',
    () async {
      await credentials.save(
        host: GitCredentials.githubHost,
        username: 'x-access-token',
        token: 'ghp_token_value',
        name: '张三',
        email: 'zhangsan@example.com',
      );
      final file = File(credentials.globalConfigPath);
      expect(file.existsSync(), true);
      final text = file.readAsStringSync();
      expect(text, contains('[credential]'));
      expect(text, contains('helper = "store --file='));
      // gitconfig 里路径必须是正斜杠：双引号值中的反斜杠是转义符
      expect(
        text,
        contains('store --file=${credentials.storePath.replaceAll(r'\', '/')}'),
      );
      expect(text, contains('[user]'));
      expect(text, contains('name = 张三'));
      expect(text, contains('email = zhangsan@example.com'));
      expect(text, contains('[http]'));
      expect(text, contains('sslVerify = true'));
    },
  );

  test(
    'save 生成 git-credentials：https://x-access-token:<token>@github.com',
    () async {
      await credentials.save(
        host: GitCredentials.githubHost,
        username: 'x-access-token',
        token: 'ghp_abc123',
      );
      final lines = File(credentials.storePath).readAsLinesSync();
      expect(lines, ['https://x-access-token:ghp_abc123@github.com']);
    },
  );

  test('重复 save 只替换同一主机的行，其它主机保留', () async {
    await credentials.save(
      host: GitCredentials.githubHost,
      username: 'x-access-token',
      token: 'first',
    );
    await credentials.save(
      host: 'gitlab.example.com',
      username: 'oauth2',
      token: 'glpat',
    );
    await credentials.save(
      host: GitCredentials.githubHost,
      username: 'x-access-token',
      token: 'second',
    );
    final lines = File(credentials.storePath).readAsLinesSync();
    expect(lines.length, 2);
    expect(
      lines.where((l) => l.contains('github.com')).single,
      'https://x-access-token:second@github.com',
    );
    expect(lines.any((l) => l.contains('gitlab.example.com')), true);
  });

  test('load/has 读回主机凭据；未知主机返回 null', () async {
    expect(await credentials.has(GitCredentials.githubHost), false);
    await credentials.save(
      host: GitCredentials.githubHost,
      username: 'x-access-token',
      token: 'ghp_read_back',
    );
    expect(await credentials.has(GitCredentials.githubHost), true);
    final loaded = await credentials.load(GitCredentials.githubHost);
    expect(loaded?.username, 'x-access-token');
    expect(loaded?.token, 'ghp_read_back');
    expect(await credentials.load('gitlab.example.com'), null);
  });

  test('保存时 name/email 为空则保留上次写入的身份', () async {
    await credentials.save(
      host: GitCredentials.githubHost,
      username: 'x-access-token',
      token: 'one',
      name: 'Flit User',
      email: 'user@example.com',
    );
    await credentials.save(
      host: GitCredentials.githubHost,
      username: 'x-access-token',
      token: 'two',
    );
    final text = File(credentials.globalConfigPath).readAsStringSync();
    expect(text, contains('name = Flit User'));
    expect(text, contains('email = user@example.com'));
  });

  test('clear 删除凭据并去掉 credential 段，保留 user 身份', () async {
    await credentials.save(
      host: GitCredentials.githubHost,
      username: 'x-access-token',
      token: 'ghp_clear_me',
      name: 'Flit User',
      email: 'user@example.com',
    );
    await credentials.clear(GitCredentials.githubHost);
    expect(File(credentials.storePath).existsSync(), false);
    final text = File(credentials.globalConfigPath).readAsStringSync();
    expect(text, isNot(contains('[credential]')));
    expect(text, contains('name = Flit User'));
    expect(await credentials.has(GitCredentials.githubHost), false);
  });

  test('parseCredentialLine 只认 https + 主机 + userinfo', () {
    expect(
      GitCredentials.parseCredentialLine(
        'https://x-access-token:tok@github.com',
        'github.com',
      ),
      (username: 'x-access-token', token: 'tok'),
    );
    expect(
      GitCredentials.parseCredentialLine(
        'https://x-access-token:tok@github.com/',
        'GitHub.com',
      ),
      (username: 'x-access-token', token: 'tok'),
    );
    expect(
      GitCredentials.parseCredentialLine(
        'https://x-access-token:tok@gitlab.com',
        'github.com',
      ),
      null,
    );
    expect(
      GitCredentials.parseCredentialLine('not-a-credential', 'github.com'),
      null,
    );
    expect(
      GitCredentials.parseCredentialLine(
        'https://noseparator@github.com',
        'github.com',
      ),
      null,
    );
  });

  test('credentialLine 与 buildGitConfig 是纯函数（便于跨平台断言）', () {
    expect(
      GitCredentials.credentialLine(
        host: 'github.com',
        username: 'x-access-token',
        token: 't',
      ),
      'https://x-access-token:t@github.com',
    );
    final text = GitCredentials(home: home.path).buildGitConfig(
      name: 'a',
      email: 'b@c',
      storeFile: r'C:\Users\u\.flit\git-credentials',
    );
    expect(text, contains(r'store --file=C:/Users/u/.flit/git-credentials'));
  });
}
