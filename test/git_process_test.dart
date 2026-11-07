import 'dart:async';
import 'dart:io';

import 'package:flit/services/desktop_toolchain.dart';
import 'package:flit/services/git_credentials.dart';
import 'package:flit/services/git_process.dart';
import 'package:flutter_test/flutter_test.dart';

/// 捕获一次调用的 argv / env / cwd，不真的启动 git。
class _FakeRunner {
  _FakeRunner({this.answer, this.hang = false});

  final ({int code, String stdout, String stderr})? answer;

  /// 永不完成（用于验证超时分支，且不留下 pending timer）。
  final bool hang;
  String? executable;
  List<String>? arguments;
  String? workingDirectory;
  Map<String, String>? environment;

  Future<ProcessResult> call(
    String exe,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    executable = exe;
    arguments = args;
    this.workingDirectory = workingDirectory;
    this.environment = environment;
    if (hang) return Completer<ProcessResult>().future;
    final a = answer ?? (code: 0, stdout: '', stderr: '');
    return ProcessResult(0, a.code, a.stdout, a.stderr);
  }
}

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('flit-git-process-');
  });

  tearDown(() async {
    if (home.existsSync()) await home.delete(recursive: true);
  });

  GitProcess process(_FakeRunner runner, {String root = '/project'}) =>
      GitProcess(
        root,
        executable: 'git',
        environment: const {'PATH': '/usr/bin', 'CUSTOM': '1'},
        credentials: GitCredentials(home: home.path),
        runner: runner.call,
        timeoutMs: 5000,
      );

  test('argv 拼装：全局稳定化参数在前，业务参数原样跟在后', () async {
    final runner = _FakeRunner();
    await process(runner).run(['status', '--porcelain=v1', '-z']);
    expect(runner.executable, 'git');
    expect(runner.arguments, [
      '--no-pager',
      '--literal-pathspecs',
      '-c',
      'core.quotepath=false',
      '-c',
      'color.ui=false',
      '-c',
      'color.advice=false',
      'status',
      '--porcelain=v1',
      '-z',
    ]);
    // 参数里不允许出现 shell 拼接痕迹
    expect(runner.arguments!.join(' '), isNot(contains("'")));
    expect(runner.arguments!.join(' '), isNot(contains('LC_ALL')));
  });

  test('workingDirectory 是工程根（不再用 git -C 拼引号路径）', () async {
    final runner = _FakeRunner();
    await process(
      runner,
      root: r'C:\work\项目',
    ).run(['rev-parse', '--show-prefix']);
    expect(runner.workingDirectory, r'C:\work\项目');
    expect(runner.arguments, isNot(contains('-C')));
  });

  test(
    'env 注入：GIT_TERMINAL_PROMPT/GIT_CONFIG_NOSYSTEM/GIT_CONFIG_GLOBAL',
    () async {
      final credentials = GitCredentials(home: home.path);
      final runner = _FakeRunner();
      final git = GitProcess(
        '/project',
        executable: 'git',
        environment: const {'PATH': '/usr/bin', 'CUSTOM': '1'},
        credentials: credentials,
        runner: runner.call,
      );
      await git.run(['fetch']);
      expect(git.environment['CUSTOM'], '1');
      expect(git.environment['GIT_TERMINAL_PROMPT'], '0');
      expect(git.environment['GIT_CONFIG_NOSYSTEM'], '1');
      expect(
        git.environment['GIT_CONFIG_GLOBAL'],
        credentials.globalConfigPath,
      );
      expect(
        runner.environment!['GIT_CONFIG_GLOBAL'],
        credentials.globalConfigPath,
      );
    },
  );

  test('输出合并 stdout+stderr 原文，失败退出码原样返回', () async {
    final runner = _FakeRunner(
      answer: (code: 128, stdout: 'fatal: ', stderr: 'not a git repository'),
    );
    final result = await process(runner).run(['status']);
    expect(result.code, 128);
    expect(result.out, 'fatal: not a git repository');
  });

  test('超时返回 124 而不是抛异常/挂住', () async {
    final runner = _FakeRunner(hang: true);
    final git = GitProcess(
      '/project',
      executable: 'git',
      runner: runner.call,
      timeoutMs: 30,
    );
    final result = await git.run(['status']);
    expect(result.code, 124);
    expect(result.out, contains('超时'));
  });

  test('可执行文件优先用私有 MinGit 的 gitExe', () async {
    final toolchain = DesktopToolchain(home: home.path);
    final exe = File(toolchain.gitExe);
    exe.parent.createSync(recursive: true);
    exe.writeAsStringSync('fake');
    final git = GitProcess(
      '/project',
      toolchain: toolchain,
      credentials: GitCredentials(home: home.path),
      runner: _FakeRunner().call,
    );
    expect(git.executable, toolchain.gitExe);
  });

  test('clone 参数：--branch/--depth 1 走 argv，URL 不转义', () async {
    final runner = _FakeRunner(answer: (code: 0, stdout: '', stderr: ''));
    final git = process(runner);
    await git.clone(
      url: 'https://github.com/u/repo.git',
      parentDirectory: '/projects',
      directory: 'repo',
      branch: 'main',
      shallow: true,
    );
    expect(runner.workingDirectory, '/projects');
    expect(runner.arguments!.sublist(runner.arguments!.indexOf('clone')), [
      'clone',
      '--branch',
      'main',
      '--depth',
      '1',
      'https://github.com/u/repo.git',
      'repo',
    ]);
  });

  test('version 解析首行', () async {
    final runner = _FakeRunner(
      answer: (code: 0, stdout: 'git version 2.47.0.windows.1\n', stderr: ''),
    );
    expect(await process(runner).version(), 'git version 2.47.0.windows.1');
  });

  test('SSH 地址规范成 HTTPS（MinGit 不含 ssh.exe）', () {
    expect(
      GitProcess.normalizeUrl('git@github.com:owner/repo.git'),
      'https://github.com/owner/repo.git',
    );
    expect(
      GitProcess.normalizeUrl('ssh://git@github.com/owner/repo.git'),
      'https://github.com/owner/repo.git',
    );
    expect(
      GitProcess.normalizeUrl('ssh://git@github.com:22/owner/repo.git'),
      'https://github.com/owner/repo.git',
    );
    expect(
      GitProcess.normalizeUrl('git@gitlab.com:group/sub/repo.git'),
      'https://gitlab.com/group/sub/repo.git',
    );
    // 已经是 HTTPS / 本地路径的不能动
    const https = 'https://github.com/owner/repo.git';
    expect(GitProcess.normalizeUrl(https), https);
    expect(GitProcess.normalizeUrl('/tmp/local-repo'), '/tmp/local-repo');
    expect(GitProcess.isSshUrl(https), false);
    expect(GitProcess.isSshUrl('git@github.com:o/r.git'), true);
    expect(GitProcess.sshNotice('git@github.com:o/r.git'), isNotNull);
    expect(GitProcess.sshNotice(https), isNull);
  });

  test('display 只用于展示，带空格/中文的参数加引号', () {
    expect(
      GitProcess.display(['commit', '-m', '提交 信息']),
      "git commit -m '提交 信息'",
    );
    expect(GitProcess.display(['status']), 'git status');
  });
}
