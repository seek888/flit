import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flit/services/git_process.dart';
import 'package:flit/services/git_repo.dart';

/// 测试用的真实执行器：argv 直启 git，跟 [GitProcess] 一样带输出稳定化参数。
/// 注入 GitRepo 时绕过 GitProcess 的可执行文件解析（CI 上 git 在 PATH 里）。
Future<GitResult> localGit(List<String> args) async {
  final result = await Process.run(
    'git',
    [...GitProcess.globalArgs, ...args],
    stdoutEncoding: const Utf8Codec(allowMalformed: true),
    stderrEncoding: const Utf8Codec(allowMalformed: true),
    environment: {
      'GIT_CONFIG_NOSYSTEM': '1',
      // 指向不存在的文件 = 空全局配置，不读用户的 ~/.gitconfig
      'GIT_CONFIG_GLOBAL':
          '${Directory.systemTemp.path}/flit-test-no-gitconfig',
      'GIT_TERMINAL_PROMPT': '0',
    },
  );
  return (code: result.exitCode, out: '${result.stdout}${result.stderr}');
}

void main() {
  test(
    'NUL status preserves leading spaces, Chinese, arrows, CR/LF and rename sources',
    () {
      final snapshot = GitRepo.parseStatus(
        '## main...origin/main [ahead 1]\x00'
        ' M 中文 -> 文本 \x00M  staged.txt\x00?? line\r\nbreak.txt\x00'
        'R  new name\x00old name\x00UU conflict.txt\x00',
      );
      expect(snapshot.branch, 'main');
      expect(snapshot.upstream, 'origin/main');
      expect(snapshot.changes[0].path, '中文 -> 文本 ');
      expect(snapshot.changes[0].staged, false);
      expect(snapshot.changes[1].staged, true);
      expect(snapshot.changes[2].path, 'line\r\nbreak.txt');
      expect(snapshot.changes[3].originalPath, 'old name');
      expect(snapshot.changes[3].path, 'new name');
      expect(snapshot.hasConflicts, true);
    },
  );

  test(
    'real repository handles paths literally, both diffs, branch listing and worktree HEAD',
    () async {
      final temp = await Directory.systemTemp.createTemp('flit-git-');
      final repo = GitRepo(temp.path, execute: localGit);
      try {
        expect((await repo.snapshot()).exists, false);
        await repo.checked(['init', '--initial-branch=main', '--template=']);
        await repo.checked(['config', 'user.name', 'Test']);
        await repo.checked(['config', 'user.email', 'test@example.invalid']);
        final names = [
          '普通.txt',
          'weird -> name.txt',
          'line\r\nbreak.txt',
          ':(glob)*.txt',
          "quote'\$(touch SHOULD_NOT_EXIST).txt",
        ];
        for (final name in names) {
          await File('${temp.path}/$name').writeAsString('original\n');
        }
        expect(
          (await repo.snapshot()).changes.map((c) => c.path).toSet(),
          names.toSet(),
        );
        await repo.checked(['add', '--', names.first]);
        var state = await repo.snapshot();
        expect(state.changes.where((c) => c.staged).length, 1);
        expect(
          await repo.diff(
            state.changes.firstWhere((c) => c.staged),
            staged: true,
          ),
          contains('+original'),
        );
        await repo.checked(['add', '-A']);
        await repo.checked([
          '-c',
          'commit.gpgsign=false',
          'commit',
          '-m',
          'initial',
        ]);
        await File('${temp.path}/${names.first}').writeAsString('updated\n');
        state = await repo.snapshot();
        expect(state.changes.single.y, 'M');
        expect(
          await repo.diff(state.changes.single, staged: false),
          contains('+updated'),
        );
        expect(await repo.branches(), ['main']);
        await repo.checked(['mv', '--', names[1], 'renamed.txt']);
        final rename = (await repo.snapshot()).changes.firstWhere(
          (c) => c.x == 'R',
        );
        expect(rename.originalPath, names[1]);
        expect(rename.path, 'renamed.txt');
        expect(File('${temp.path}/SHOULD_NOT_EXIST').existsSync(), false);
        final linked = '${temp.path}/linked';
        await repo.checked(['worktree', 'add', '-b', 'feature', linked]);
        expect(File('$linked/.git').existsSync(), true);
        expect(
          (await GitRepo(linked, execute: localGit).snapshot()).branch,
          'feature',
        );
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );

  test('status failure is an error, never a clean worktree', () async {
    final repo = GitRepo(
      '/project',
      execute: (_) async => (code: 127, out: 'git: command not found'),
    );
    await expectLater(repo.snapshot(), throwsStateError);
  });

  test('nested project cannot silently manage its parent repository', () async {
    final temp = await Directory.systemTemp.createTemp('flit-nested-repo-');
    try {
      final parent = GitRepo(temp.path, execute: localGit);
      await parent.checked(['init', '--template=']);
      await Directory('${temp.path}/app').create();
      final nested = GitRepo('${temp.path}/app', execute: localGit);
      await expectLater(nested.snapshot(), throwsStateError);
      expect(nested.supported, false);
      // Android 端仍把 argv 渲染成 POSIX 命令串（仅 Android 使用）；
      // 桌面端这道执行路径不存在，参数走 Process.run argv。
      final android = GitRepo.androidCommand(parent.root, ['push']);
      expect(android, contains('GIT_TERMINAL_PROMPT=0'));
      expect(android, contains('BatchMode=yes'));
      expect(android, contains('StrictHostKeyChecking=yes'));
      expect(android, contains("'push'"));
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
