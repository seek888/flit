import 'package:flit/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/host_platform.dart';
import '../../core/theme.dart';
import '../../services/git_repo.dart';
import '../editor/workbench_layout.dart';
import 'github_account.dart';
import 'github_account_tile.dart';
import 'project_git.dart';

/// Repository tools sit beside the file tree, never inside its folder menus.
class GitPanel extends StatefulWidget {
  const GitPanel({super.key});
  @override
  State<GitPanel> createState() => _GitPanelState();
}

class _GitPanelState extends State<GitPanel> {
  /// 工程的版本控制状态来自 ProjectScope, 页面生命周期内不换对象
  late final ProjectGit git = context.read<ProjectGit>();
  bool get disabled => git.blocked;

  /// 面板在抽屉里: 看输出 = 关抽屉 + 展开终端
  void _showOutput() {
    Scaffold.maybeOf(context)?.closeDrawer();
    context.read<WorkbenchLayout>().showOutput();
  }

  @override
  void initState() {
    super.initState();
    // 刷新会立刻 notify; 面板可能与提供它的 ProjectScope 同帧挂载,
    // 挂载中通知祖先会触发框架断言, 所以推到首帧之后
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) git.refresh();
    });
  }

  Future<void> _act(
    Future<void> Function() action, {
    bool terminal = false,
  }) async {
    try {
      if (terminal) _showOutput();
      await action();
    } catch (error) {
      if (mounted) _message('$error');
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// 桌面端：粘贴个人访问令牌登录 GitHub（写入 app 私有 gitconfig）。
  Future<void> _loginWithToken() async {
    final account = context.read<GithubAccount>();
    final token = await showGithubTokenDialog(context);
    if (token == null || !mounted) return;
    final ok = await account.loginWithToken(token);
    if (!mounted) return;
    _message(
      ok
          ? '已登录 GitHub${account.loginName == null ? '' : '：${account.loginName}'}'
          : account.error ?? '登录失败',
    );
  }

  Future<String?> _input(
    String title,
    String label, {
    String initial = '',
    int lines = 1,
  }) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _GitTextPrompt(
        title: title,
        label: label,
        initial: initial,
        lines: lines,
      ),
    );
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(context.strings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(context.strings.ok),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _commit() async {
    final message = await _input(
      context.strings.commitStagedChanges,
      context.strings.commitMessage,
      lines: 3,
    );
    if (message != null && mounted) await _act(() => git.commit(message));
  }

  Future<void> _diff(GitChange change, bool staged) async {
    try {
      final text = await git.repo.diff(change, staged: staged);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height * .8,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SheetHandle(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    '${staged ? context.strings.staged : context.strings.unstaged} · ${change.path}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(text, style: AppColors.mono),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (error) {
      if (mounted) _message('$error');
    }
  }

  Future<void> _fileMenu(GitChange change) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetHandle(),
              ListTile(
                title: Text(
                  change.path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (change.staged)
                ListTile(
                  leading: const Icon(Icons.difference_outlined),
                  title: Text(context.strings.showStagedDiff),
                  onTap: () => Navigator.pop(ctx, 'stagedDiff'),
                ),
              if (!change.untracked && change.unstaged)
                ListTile(
                  leading: const Icon(Icons.difference_outlined),
                  title: Text(context.strings.showUnstagedDiff),
                  onTap: () => Navigator.pop(ctx, 'diff'),
                ),
              if (change.unstaged || change.conflicted)
                ListTile(
                  leading: const Icon(Icons.add),
                  title: Text(
                    change.conflicted
                        ? context.strings.markConflictResolvedStage
                        : context.strings.stageFile,
                  ),
                  onTap: () => Navigator.pop(ctx, 'stage'),
                ),
              if (change.staged)
                ListTile(
                  leading: const Icon(Icons.remove),
                  title: Text(context.strings.unstage),
                  onTap: () => Navigator.pop(ctx, 'unstage'),
                ),
              if (!change.untracked && !change.conflicted && change.unstaged)
                ListTile(
                  leading: const Icon(Icons.undo, color: AppColors.danger),
                  title: Text(context.strings.rollbackUnstagedChanges),
                  onTap: () => Navigator.pop(ctx, 'discard'),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'stagedDiff':
        await _diff(change, true);
      case 'diff':
        await _diff(change, false);
      case 'stage':
        await _act(() => git.stage(change));
      case 'unstage':
        await _act(() => git.unstage(change));
      case 'discard':
        if (await _confirm(
              context.strings.rollbackChanges,
              context.strings.discardUnstagedChangesInPStagedChanges(
                change.path,
              ),
            ) &&
            mounted) {
          await _act(() => git.discard(change));
        }
    }
  }

  Future<void> _branches() async {
    try {
      final branches = await git.repo.branches();
      if (!mounted) return;
      final selected = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(context.strings.branches),
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: Text(context.strings.createAndSwitchBranch),
              onTap: () => Navigator.pop(ctx, ''),
            ),
            for (final branch in branches)
              ListTile(
                title: Text(branch),
                trailing: branch == git.snapshot.branch
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(ctx, branch),
              ),
          ],
        ),
      );
      if (selected == null || !mounted) return;
      if (selected.isEmpty) {
        final name = await _input(
          context.strings.newBranch,
          context.strings.branchName,
        );
        if (name != null && mounted) {
          await _act(() => git.switchBranch(name, create: true));
        }
      } else if (selected != git.snapshot.branch) {
        await _act(() => git.switchBranch(selected));
      }
    } catch (error) {
      if (mounted) _message('$error');
    }
  }

  Future<void> _settings(String action) async {
    if (action == 'log') {
      try {
        final text = await git.repo.checked(['log', '--oneline', '-15']);
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(context.strings.commitHistory),
            content: SingleChildScrollView(
              child: SelectableText(text, style: AppColors.mono),
            ),
          ),
        );
      } catch (error) {
        if (mounted) _message('$error');
      }
    } else if (action == 'remote') {
      final result = await git.repo.run(['remote', 'get-url', 'origin']);
      if (!mounted) return;
      final url = await _input(
        context.strings.remoteOrigin,
        context.strings.repositoryUrl,
        initial: result.code == 0 ? result.out.trim() : '',
      );
      if (url != null && mounted) await _act(() => git.setRemote(url));
    } else if (action == 'identity') {
      final existingName = await git.repo.run(['config', 'user.name']);
      final existingEmail = await git.repo.run(['config', 'user.email']);
      if (!mounted) return;
      final name = await _input(
        context.strings.commitAuthorThisRepository,
        context.strings.name,
        initial: existingName.out.trim(),
      );
      if (name == null || !mounted) return;
      final email = await _input(
        context.strings.commitAuthorThisRepository,
        context.strings.email,
        initial: existingEmail.out.trim(),
      );
      if (email != null && mounted) {
        await _act(() => git.setIdentity(name, email));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      git,
      git.executions,
      if (git.preparing != null) git.preparing!,
    ]),
    builder: (_, _) {
      final state = git.snapshot;
      final staged = state.changes.where((c) => c.staged).length;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
            child: Row(
              children: [
                const Icon(
                  Icons.account_tree_outlined,
                  size: 18,
                  color: AppColors.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state.exists
                        ? (state.detached
                              ? context.strings.detachedHead
                              : state.branch)
                        : context.strings.versionControl,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: context.strings.refreshVersionControlStatus,
                  onPressed: disabled ? null : git.refresh,
                  icon: const Icon(Icons.refresh, size: 20),
                ),
                PopupMenuButton<String>(
                  enabled: !disabled && state.exists,
                  tooltip: context.strings.repositorySettings,
                  onSelected: (value) => _act(() => _settings(value)),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'log',
                      child: Text(context.strings.commitHistory),
                    ),
                    PopupMenuItem(
                      value: 'remote',
                      child: Text(context.strings.remotes),
                    ),
                    PopupMenuItem(
                      value: 'identity',
                      child: Text(context.strings.commitAuthor),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (git.loading || git.busy)
            const LinearProgressIndicator(minHeight: 2),
          if (state.exists)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: disabled
                        ? null
                        : () => _act(git.pull, terminal: true),
                    icon: const Icon(Icons.download_outlined, size: 17),
                    label: Text(context.strings.pull),
                  ),
                  TextButton.icon(
                    onPressed: disabled
                        ? null
                        : () => _act(git.push, terminal: true),
                    icon: const Icon(Icons.upload_outlined, size: 17),
                    label: Text(context.strings.push),
                  ),
                  TextButton.icon(
                    onPressed: disabled ? null : _branches,
                    icon: const Icon(Icons.call_split, size: 17),
                    label: Text(context.strings.branches),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (git.error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      git.error!,
                      style: const TextStyle(
                        color: AppColors.danger,
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (git.busy)
                  Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text(
                      context.strings.operationInProgressViewProgressOrStop,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                if (!state.exists && !git.loading && git.error == null) ...[
                  Text(
                    context.strings.thisProjectHasNoGitRepositoryYet,
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: disabled ? null : () => _act(git.initialize),
                    icon: const Icon(Icons.add),
                    label: Text(context.strings.initializeRepository),
                  ),
                ],
                if (state.exists &&
                    state.changes.isEmpty &&
                    git.error == null &&
                    !git.loading)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      context.strings.noLocalChanges,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                if (state.hasConflicts)
                  Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text(
                      context.strings.conflictsFoundResolveThemInTheEditor,
                      style: TextStyle(color: AppColors.warn, fontSize: 12),
                    ),
                  ),
                for (final change in state.changes)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Text(
                      change.conflicted
                          ? context.strings.conflicts
                          : change.untracked
                          ? context.strings.untracked
                          : '${change.x}${change.y}',
                      style: TextStyle(
                        fontSize: 12,
                        color: change.conflicted
                            ? AppColors.danger
                            : AppColors.accent,
                      ),
                    ),
                    title: Text(
                      change.path,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    subtitle: change.staged
                        ? Text(
                            change.unstaged
                                ? context
                                      .strings
                                      .stagedWithAdditionalUnstagedChanges
                                : context.strings.staged,
                            style: const TextStyle(fontSize: 10),
                          )
                        : null,
                    trailing: const Icon(Icons.more_horiz, size: 18),
                    onTap: disabled ? null : () => _fileMenu(change),
                  ),
              ],
            ),
          ),
          if (state.exists && state.changes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextButton(
                    onPressed: disabled || state.hasConflicts
                        ? null
                        : () => _act(git.stageAll),
                    child: Text(context.strings.stageAllChanges),
                  ),
                  FilledButton.icon(
                    onPressed: disabled || staged == 0 || state.hasConflicts
                        ? null
                        : _commit,
                    icon: const Icon(Icons.commit, size: 18),
                    label: Text(context.strings.commitChangesP(staged)),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          // 账户是全局的: 与克隆页、设置页同一个 tile
          GithubAccountTile(dense: true, enabled: !disabled),
          // 桌面端没有 gh CLI：个人访问令牌是主登录方式。
          if (isDesktopPlatform)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: disabled ? null : _loginWithToken,
                  icon: const Icon(Icons.vpn_key_outlined, size: 16),
                  label: const Text(
                    '个人访问令牌（PAT）登录',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

class _GitTextPrompt extends StatefulWidget {
  const _GitTextPrompt({
    required this.title,
    required this.label,
    required this.initial,
    required this.lines,
  });
  final String title, label, initial;
  final int lines;
  @override
  State<_GitTextPrompt> createState() => _GitTextPromptState();
}

class _GitTextPromptState extends State<_GitTextPrompt> {
  late final controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: controller,
      autofocus: true,
      maxLines: widget.lines,
      decoration: InputDecoration(labelText: widget.label),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.strings.cancel),
      ),
      FilledButton(
        onPressed: () {
          final text = controller.text.trim();
          if (text.isNotEmpty) Navigator.pop(context, text);
        },
        child: Text(context.strings.ok),
      ),
    ],
  );
}
