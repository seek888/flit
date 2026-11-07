import 'package:flit/l10n/strings.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/host_platform.dart';
import '../../services/git_process.dart';
import '../../services/git_repo.dart';
import '../terminal/run_sessions.dart';
import '../workspace/project_documents.dart';

/// One Git operation per project; its lifetime is independent of the sidebar.
/// GitHub 账户(登录/登出/状态)是全局的, 见 GithubAccount; 这里只管仓库操作。
class ProjectGit extends ChangeNotifier {
  ProjectGit({
    required this.documents,
    required this.executions,
    this.preparing,
    GitRepo? repository,
  }) : repo = repository ?? GitRepo(documents.projectPath);

  final ProjectDocuments documents;
  final RunSessions executions;
  final ValueListenable<String?>? preparing;
  bool get blocked =>
      !repo.supported ||
      busy ||
      loading ||
      executions.active != null ||
      executions.starting ||
      preparing?.value != null;
  final GitRepo repo;
  GitSnapshot snapshot = const GitSnapshot();
  String? error;
  bool loading = false, busy = false, _closed = false;
  int revision = 0;
  Future<void>? _refreshing;
  Future<void>? _operation;
  RunSession? _task;

  Future<void> refresh() {
    if (_closed || busy) return Future.value();
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final state = await repo.snapshot();
      if (!_closed) snapshot = state;
    } catch (e) {
      if (!_closed) error = '$e';
    } finally {
      if (!_closed) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _mutate(
    Future<void> Function() action, {
    bool changesFiles = false,
  }) {
    if (_closed) return Future.error(StateError(strings.projectIsClosed));
    if (!repo.supported) {
      return Future.error(StateError(strings.openTheGitRepositoryRootToUse));
    }
    if (blocked) {
      return Future.error(StateError(strings.aTaskIsRunningStopItBefore));
    }
    busy = true;
    error = null;
    notifyListeners();
    return _operation = (() async {
      try {
        // Validate the selected directory before any mutation, including when
        // the caller has not opened or refreshed the Git panel yet.
        await repo.snapshot();
        if (changesFiles) {
          await documents.changeOnDisk(action);
        } else {
          if (!await documents.saveAll()) {
            throw StateError(strings.saveFailedGitOperationCancelled);
          }
          if (_closed) return;
          await action();
        }
      } catch (e) {
        if (!_closed) error = '$e';
      } finally {
        if (!_closed) {
          final operationError = error;
          busy = false;
          revision++;
          notifyListeners();
          await _refresh();
          if (operationError != null) {
            error = operationError;
            notifyListeners();
          }
        }
      }
    })().whenComplete(() => _operation = null);
  }

  /// 执行一次 git 操作。
  ///
  /// **桌面端**：直接以 argv 调 git（[GitProcess]），输出写进终端日志；
  /// 不再拼 `VAR=val ... -C 'root'` 这种 shell 字符串（cmd.exe 不认）。
  /// **Android**：保持原样——把 argv 渲染成 shQuote 命令串进 PTY 会话，
  /// 这样 flutter_pty 的交互输出/中止行为完全不变。
  Future<void> _command(List<String> args, {String title = 'Git'}) {
    if (isDesktopPlatform) return _desktopCommand(args, title: title);
    return _terminal(GitRepo.androidCommand(repo.root, args), title: title);
  }

  Future<void> _desktopCommand(
    List<String> args, {
    required String title,
  }) async {
    if (_closed) return;
    final result = await repo.run(args);
    _logCommand(args, result.out);
    if (result.code != 0) {
      final detail = result.out.trim();
      throw StateError(
        detail.isEmpty
            ? strings.pIncompleteExitCodePSeeTerminal(title, result.code)
            : detail,
      );
    }
  }

  /// 桌面端没有 PTY 会话跑 git，把「等价命令 + 原文输出」写进终端日志：
  /// 成功失败都留痕，失败原文同时经 SnackBar 展示（见 GitPanel._act）。
  void _logCommand(List<String> args, String output) {
    if (_closed) return;
    try {
      final log = executions.console.log;
      log.info('\$ ${GitProcess.display(args)}');
      final text = output.trimRight();
      if (text.isEmpty) return;
      for (final line in text.split(RegExp(r'\r?\n'))) {
        log.line(line);
      }
    } catch (_) {
      // 终端已关闭/会话被替换时忽略：结果仍通过 error/SnackBar 呈现。
    }
  }

  Future<void> _terminal(String command, {required String title}) async {
    if (_closed) return;
    _task = await executions.start(
      RunConfiguration(id: 'git', title: title, command: command),
    );
    if (_closed) await _task!.stop();
    final code = await _task!.done;
    if (code != 0) {
      throw StateError(strings.pIncompleteExitCodePSeeTerminal(title, code));
    }
  }

  Future<void> initialize() =>
      _mutate(() => _command(['init'], title: strings.initializeRepository));
  Future<void> stage(GitChange change) => _mutate(
    () => _command([
      'add',
      '--',
      if (change.x == 'R' || change.x == 'C') change.path else ...change.paths,
    ]),
  );
  Future<void> stageAll() => _mutate(() => _command(['add', '-A']));
  Future<void> unstage(GitChange change) => _mutate(
    () => _command(
      snapshot.unborn
          ? ['rm', '--cached', '-f', '--', ...change.paths]
          : ['restore', '--staged', '--', ...change.paths],
    ),
  );
  Future<void> commit(String message) => _mutate(() async {
    if (message.trim().isEmpty) throw StateError(strings.enterACommitMessage);
    final state = await repo.snapshot();
    if (state.hasConflicts) {
      throw StateError(strings.resolveConflictsAndStageTheFilesFirst);
    }
    if (!state.changes.any((c) => c.staged)) {
      throw StateError(strings.stageTheFilesToCommitFirst);
    }
    await _command(['commit', '-m', message.trim()], title: strings.commit);
  });
  Future<void> discard(GitChange change) => _mutate(() async {
    if (change.untracked || change.conflicted) {
      throw StateError(strings.theCurrentFileStatusDoesNotSupport);
    }
    await _command([
      'restore',
      '--worktree',
      '--',
      change.path,
    ], title: strings.rollbackUnstagedChanges);
  }, changesFiles: true);
  Future<void> switchBranch(String branch, {bool create = false}) =>
      _mutate(() async {
        final state = await repo.snapshot();
        if (state.changes.isNotEmpty) {
          throw StateError(
            strings.commitOrRollbackChangesBeforeSwitchingBranches,
          );
        }
        await _command(
          create ? ['switch', '-c', branch] : ['switch', branch],
          title: strings.switchBranch,
        );
      }, changesFiles: true);
  Future<void> pull() => _mutate(() async {
    final state = await repo.snapshot();
    if (state.changes.isNotEmpty) {
      throw StateError(strings.commitOrRollbackChangesBeforePulling);
    }
    if (state.upstream == null) {
      throw StateError(strings.thisBranchHasNoUpstreamPushAnd);
    }
    await _command(['pull', '--ff-only'], title: strings.pull);
  }, changesFiles: true);
  Future<void> push() => _mutate(() async {
    final state = await repo.snapshot();
    if (state.detached || state.unborn) {
      throw StateError(strings.switchToABranchAndCreateA);
    }
    if (state.hasConflicts) throw StateError(strings.resolveConflictsFirst);
    if (state.upstream != null) {
      await _command(['push'], title: strings.push);
    } else {
      final remotes = (await repo.checked([
        'remote',
      ])).split('\n').where((s) => s.isNotEmpty).toList();
      if (remotes.length != 1) {
        throw StateError(strings.firstPushRequiresARemoteConfigureOrigin);
      }
      await _command([
        'push',
        '--set-upstream',
        remotes.single,
        state.branch,
      ], title: strings.firstPush);
    }
  });
  Future<void> setRemote(String url) => _mutate(() async {
    // 桌面端 MinGit 不含 ssh.exe：SSH 地址自动转 HTTPS，并提示一次。
    final normalized = isDesktopPlatform ? GitProcess.normalizeUrl(url) : url;
    final message = isDesktopPlatform ? GitProcess.sshNotice(url) : null;
    if (!RegExp(r'^(https?://|ssh://|git@)\S+$').hasMatch(normalized)) {
      throw StateError(strings.enterAValidRepositoryUrl);
    }
    if (message != null) {
      try {
        executions.console.log.warn(message);
      } catch (_) {}
    }
    final existing = await repo.run(['remote', 'get-url', 'origin']);
    await _command(
      existing.code == 0
          ? ['remote', 'set-url', 'origin', normalized]
          : ['remote', 'add', 'origin', normalized],
    );
  });
  Future<void> setIdentity(String name, String email) => _mutate(() async {
    if (name.trim().isEmpty || email.trim().isEmpty) {
      throw StateError(strings.enterTheCommitAuthorNameAndEmail);
    }
    await _command(['config', '--local', 'user.name', name.trim()]);
    await _command(['config', '--local', 'user.email', email.trim()]);
  });
  Future<void> close() async {
    _closed = true;
    await _task?.stop();
    await _operation;
    await _refreshing;
    super.dispose();
  }
}
