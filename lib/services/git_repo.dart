import 'package:flit/l10n/strings.dart';

import 'git_process.dart';
import 'shell.dart';

export 'git_process.dart' show GitResult;

typedef GitExecute = Future<GitResult> Function(List<String> args);

class GitChange {
  const GitChange(this.x, this.y, this.path, {this.originalPath});
  final String x, y, path;
  final String? originalPath;
  bool get untracked => x == '?' && y == '?';
  bool get conflicted =>
      x == 'U' || y == 'U' || '$x$y' == 'AA' || '$x$y' == 'DD';
  bool get staged => !untracked && x != ' ' && !conflicted;
  bool get unstaged => untracked || y != ' ';
  List<String> get paths => [path, if (originalPath != null) originalPath!];
}

class GitSnapshot {
  const GitSnapshot({
    this.exists = false,
    this.branch = '',
    this.upstream,
    this.detached = false,
    this.unborn = false,
    this.changes = const [],
  });
  final bool exists, detached, unborn;
  final String branch;
  final String? upstream;
  final List<GitChange> changes;
  bool get hasConflicts => changes.any((c) => c.conflicted);
}

/// 一个工程的 Git 仓库操作。执行边界是 **参数数组**（[GitExecute]），
/// 桌面端由 [GitProcess] 直启 `git.exe`，Android 端仍走 PTY bash（把 argv
/// 渲染成 shQuote 命令串）。业务逻辑（status/diff/分支/冲突）与平台无关。
class GitRepo {
  GitRepo(this.root, {GitExecute? execute})
    : _execute = execute ?? defaultExecute(root);

  final String root;
  final GitExecute _execute;

  /// 面板据此提示「打开仓库根目录」；只有「目录嵌在父仓库里」会置 false。
  bool supported = true;

  /// 默认执行器：桌面端 argv + Process.run；Android 端保留原有 bash 执行。
  ///
  /// Android 不改执行方式是为了不破坏现有功能（flutter_pty bash + env.sh），
  /// 桌面端 cmd.exe 不认 `VAR=val`/单引号/`</dev/null`，必须换 argv。
  static GitExecute defaultExecute(String root) {
    if (isDesktopPlatform) return GitProcess(root).run;
    return (args) => androidShell(root, args);
  }

  /// **仅 Android**：把 argv 渲染成 POSIX 命令串（单引号逐个转义）。
  /// 桌面端不要用：任何 shell 拼串都会在 cmd.exe 上翻车。
  static String androidCommand(String root, List<String> args) =>
      'LC_ALL=C GIT_TERMINAL_PROMPT=0 '
      'GIT_SSH_COMMAND=${shQuote('ssh -o BatchMode=yes -o StrictHostKeyChecking=yes')} '
      'git --no-pager --literal-pathspecs -c core.quotepath=false -c color.ui=false '
      '-C ${shQuote(root)} ${args.map(shQuote).join(' ')}';

  /// **仅 Android**：经 flit_env 的 bash 执行（PTY 环境在启动时冻结，
  /// 需要 source env.sh，由 [Shell.exec] 侧处理）。
  static Future<GitResult> androidShell(String root, List<String> args) async {
    final result = await Shell.instance.exec(
      '$terminalEnvSource${androidCommand(root, args)}',
      timeoutMs: 60000,
    );
    return (
      code: result['exitCode'] as int? ?? -1,
      out: result['output'] as String? ?? '',
    );
  }

  /// 终端里展示的等价命令（只显示，不执行）。
  String display(List<String> args) => GitProcess.display(args);

  Future<GitResult> run(List<String> args) => _execute(args);

  Future<String> checked(List<String> args) async {
    final result = await run(args);
    if (result.code != 0) {
      throw StateError(
        result.out.trim().isEmpty
            ? strings.gitCommandFailedP(result.code)
            : result.out.trim(),
      );
    }
    return result.out;
  }

  Future<GitSnapshot> snapshot() async {
    final location = await run(['rev-parse', '--show-toplevel']);
    if (location.code != 0) {
      if (location.code == 128 &&
          location.out.contains('not a git repository')) {
        return const GitSnapshot();
      }
      throw StateError(
        location.out.trim().isEmpty
            ? strings.gitUnavailableCheckTheDevelopmentEnvironment
            : location.out.trim(),
      );
    }
    // Android exposes shared storage through several aliases (/sdcard and
    // /storage/emulated/0). Compare canonical paths rather than their spelling.
    final selectedRoot = await checked(['rev-parse', '--show-prefix']);
    if (selectedRoot.trim().isNotEmpty) {
      supported = false;
      throw StateError(strings.theProjectIsInsideAParentGit);
    }
    supported = true;
    return parseStatus(
      await checked([
        'status',
        '--porcelain=v1',
        '-z',
        '-b',
        '--untracked-files=all',
      ]),
    );
  }

  static GitSnapshot parseStatus(String output) {
    final records = output.split('\x00');
    final changes = <GitChange>[];
    var branch = '', detached = false, unborn = false;
    String? upstream;
    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      if (record.startsWith('## ')) {
        var head = record.substring(3).trimRight();
        for (final prefix in ['No commits yet on ', 'Initial commit on ']) {
          if (head.startsWith(prefix)) {
            unborn = true;
            head = head.substring(prefix.length);
            break;
          }
        }
        detached = head.startsWith('HEAD ');
        final split = head.indexOf('...');
        branch = split < 0 ? head : head.substring(0, split);
        if (split >= 0) upstream = head.substring(split + 3).split(' ').first;
        continue;
      }
      if (record.length < 4 || record[2] != ' ') continue;
      final x = record[0], y = record[1];
      String? original;
      if ((x == 'R' || x == 'C' || y == 'R' || y == 'C') &&
          i + 1 < records.length) {
        original = records[++i];
      }
      changes.add(GitChange(x, y, record.substring(3), originalPath: original));
    }
    return GitSnapshot(
      exists: true,
      branch: branch,
      upstream: upstream,
      detached: detached,
      unborn: unborn,
      changes: changes,
    );
  }

  Future<List<String>> branches() async => (await checked([
    'branch',
    '--format=%(refname:short)',
  ])).split('\n').where((line) => line.isNotEmpty).toList();

  Future<String> diff(GitChange change, {required bool staged}) async {
    if (change.untracked) return strings.thisFileIsUntrackedStageItTo;
    final output = await checked([
      'diff',
      '--no-ext-diff',
      '--no-textconv',
      if (staged) '--cached',
      '--',
      ...change.paths,
    ]);
    return output.isEmpty ? strings.noTextDiffPossiblyABinaryFile : output;
  }
}
