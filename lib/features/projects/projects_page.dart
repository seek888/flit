import 'package:flit/l10n/strings.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../core/page_layout.dart';

import '../../services/shell.dart';
import '../workspace/project_session.dart';
import '../terminal/console_session.dart';
import '../terminal/terminal_host.dart';
import 'clone_project_page.dart';
import 'create_project_page.dart';
import 'project_list.dart';

/// 主页 = 工程列表(Android Studio 欢迎页的手机版): 工程根 $HOME/projects 下
/// 一层目录, 含 pubspec.yaml 的是工程, 其余目录也可作为工作区打开; 最近改动的
/// 排前面。新建/克隆都落工程根, 跑在底部任务控制台里, 完成后刷新列表。
class ProjectsPage extends StatefulWidget {
  const ProjectsPage({
    super.key,
    required this.environmentReady,
    this.environmentChecking = false,
    required this.onOpenProject,
    required this.onOpenEnvironment,
    required this.onOpenSettings,
  });

  final bool environmentReady;
  final bool environmentChecking;
  final void Function(String path) onOpenProject;
  final VoidCallback onOpenEnvironment;
  final VoidCallback onOpenSettings;

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  bool _busy = false; // 新建/克隆任务进行中
  bool _termExpanded = false;
  String _pendingName = '';
  String _pendingMarker = 'create'; // create | clone
  String? _pendingProjectPath;
  ConsoleSession? _task;

  /// 工程根 $HOME/projects: 从环境状态解析, 解析前列表不建
  String? _projectsRoot;
  ProjectList? _projects;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    final status = await Shell.instance
        .bootstrapStatus()
        .timeout(const Duration(seconds: 5))
        .catchError((_) => <dynamic, dynamic>{});
    final home = (status['home'] as String? ?? '').trim();
    final root = home.isNotEmpty
        ? '$home/projects'
        : '/data/user/0/com.seek888.flit/files/home/projects';
    if (!mounted) return;
    final projects = ProjectList(
      root: root,
      beforeMutation: _checkActiveProject,
    );
    setState(() {
      _projectsRoot = root;
      _projects = projects;
    });
    // 扫描要跑 shell: 环境没就绪(没有 bash)就等它就绪再扫
    if (widget.environmentReady) unawaited(projects.refresh());
  }

  @override
  void didUpdateWidget(covariant ProjectsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.environmentReady && !oldWidget.environmentReady) {
      unawaited(_projects?.refresh());
    }
  }

  void _checkActiveProject(String path) {
    final active = context.read<ProjectWorkspace>().active;
    if (active == null || active.closed) return;
    if (path == active.path ||
        path.startsWith('${active.path}/') ||
        active.path.startsWith('$path/')) {
      throw StateError(
        context.strings.closeThisProjectBeforeRenamingOrDeleting,
      );
    }
  }

  @override
  void dispose() {
    unawaited(_task?.close());
    _projects?.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 卸载即删是内部存储的硬事实, 没有卸载前回调, 只能在首页明示备份方式
  Future<void> _showStorageInfo() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.strings.whereAreProjectsStored),
      content: Text(
        (context.strings.projectDirectoryP(_projectsRoot ?? '') +
            context.strings.uninstallingTheAppOrClearingItsData +
            context.strings.pushToGithubFromVersionControl +
            context.strings.openFilesFlitProjectsAndCopyThe +
            context.strings.longPressAFileInTheEditor),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.strings.gotIt),
        ),
      ],
    ),
  );

  // ---------- 工程条目操作 ----------

  Future<void> _renameProject(ProjectEntry entry) async {
    final projects = _projects;
    if (projects == null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: entry.name),
    );
    if (name == null || name == entry.name || !mounted) return;
    try {
      await projects.rename(entry, name);
    } catch (e) {
      _snack(e is StateError ? e.message : '$e');
    }
  }

  Future<void> _deleteProject(ProjectEntry entry) async {
    final projects = _projects;
    if (projects == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.strings.deleteProjectP(entry.name)),
        content: Text(context.strings.theDirectoryAndAllItsFilesWill),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.strings.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.strings.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await projects.delete(entry);
    } catch (e) {
      _snack(e is StateError ? e.message : '$e');
    }
  }

  // ---------- 新建 / 克隆 ----------

  bool _requireEnvironment() {
    if (widget.environmentReady) return true;
    widget.onOpenEnvironment();
    return false;
  }

  Future<void> _createProject() async {
    final root = _projectsRoot;
    if (_busy || root == null || !_requireEnvironment()) return;

    // 新建项目整页表单(含预检/校验/重名拦截), 取消返回 null。
    final params = await Navigator.push<CreateProjectParams>(
      context,
      MaterialPageRoute(
        builder: (_) => CreateProjectPage(
          onOpenEnvironment: widget.onOpenEnvironment,
          projectRoot: root,
        ),
      ),
    );
    if (params == null || !mounted) return;

    setState(() {
      _busy = true;
      _termExpanded = true;
      _pendingName = params.name;
      _pendingProjectPath = '${params.projectRoot}/${params.name}';
      _pendingMarker = 'create';
    });
    await _runTask(
      params.type == 'dart'
          ? buildDartCreateCommand(params)
          : buildFlutterCreateCommand(params),
      openOnSuccess: true,
    );
  }

  /// 克隆 Git 仓库到工程根: 独立终端里跑, 完成后只刷新列表——
  /// 下载归下载, 打开归打开(用户在列表里自己点开)。
  Future<void> _cloneProject() async {
    final root = _projectsRoot;
    if (_busy || root == null || !_requireEnvironment()) return;

    final params = await Navigator.push<CloneProjectParams>(
      context,
      MaterialPageRoute(
        builder: (_) => CloneProjectPage(
          onOpenEnvironment: widget.onOpenEnvironment,
          targetDir: root,
        ),
      ),
    );
    if (params == null || !mounted) return;

    setState(() {
      _busy = true;
      _termExpanded = true;
      _pendingName = params.dirName;
      _pendingProjectPath = null;
      _pendingMarker = 'clone';
    });
    await _runTask(buildGitCloneCommand(params), openOnSuccess: false);
  }

  Future<void> _runTask(String command, {required bool openOnSuccess}) async {
    final previous = _task;
    final task = ConsoleSession(
      title: _pendingMarker == 'clone'
          ? context.strings.cloneProject
          : context.strings.createProject,
      launcher: context.read<ProcessLauncher>(),
    );
    // 临时会话从控制台头部 ✕ 关掉后, 面板回落到默认 shell
    task.addListener(() {
      if (task.disposed && mounted && identical(_task, task)) {
        setState(() => _task = null);
      }
    });
    setState(() => _task = task);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previous?.close();
    });
    var output = '';
    final watch = task.textStream.listen((chunk) {
      output = (output + chunk).substring(
        output.length + chunk.length > 8192
            ? output.length + chunk.length - 8192
            : 0,
      );
    });
    final code = await task.run(command);
    await watch.cancel();
    await _finishOp(
      code,
      stopped: task.stopRequested,
      output: output,
      openOnSuccess: openOnSuccess,
    );
  }

  /// 未登录克隆私库: GIT_TERMINAL_PROMPT=0 让 git 立刻失败, 这里认出来指路
  static final _needsLogin = RegExp(
    r'could not read Username|terminal prompts disabled|Authentication failed|Permission denied \(publickey\)',
  );

  Future<void> _finishOp(
    int code, {
    required bool stopped,
    required String output,
    required bool openOnSuccess,
  }) async {
    if (!mounted || !_busy) return;
    final verb = _pendingMarker == 'clone'
        ? context.strings.clone
        : context.strings.create;
    setState(() => _busy = false);
    // 列表永远反映磁盘真相: 被中断的 create/clone 可能已写出目录
    await _projects?.refresh();
    if (!mounted) return;
    if (code == 0) {
      _snack(context.strings.pPSucceeded(_pendingName, verb));
      if (openOnSuccess) widget.onOpenProject(_pendingProjectPath!);
    } else {
      final needsLogin =
          _pendingMarker == 'clone' && _needsLogin.hasMatch(output);
      _snack(
        stopped
            ? context.strings.pCancelled(verb)
            : needsLogin
            ? context.strings.cloneFailedSignInToGithubFirst
            : context.strings.pFailedExitCodePSeeTerminal(verb, code),
      );
    }
  }

  // ---------- 视图 ----------

  @override
  Widget build(BuildContext context) {
    final ready = _projects != null && !_busy;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Flit',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppColors.accent,
            fontFamily: 'monospace',
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            tooltip: context.strings.newProject,
            icon: const Icon(Icons.add, size: 22),
            onPressed: ready ? _createProject : null,
          ),
          IconButton(
            tooltip: context.strings.cloneRepository,
            icon: const Icon(Icons.download_outlined, size: 20),
            onPressed: ready ? _cloneProject : null,
          ),
          IconButton(
            tooltip: context.strings.settings,
            icon: const Icon(Icons.settings_outlined, size: 20),
            onPressed: widget.onOpenSettings,
          ),
        ],
      ),
      body: TerminalHost(
        session: _task,
        expanded: _termExpanded,
        running: _busy,
        onToggle: () => setState(() => _termExpanded = !_termExpanded),
        child: PageContent(
          child: Column(
            children: [
              _storageHint(),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _storageHint() => Material(
    color: AppColors.surface,
    child: InkWell(
      onTap: _showStorageInfo,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 16, color: AppColors.textSecondary),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                context.strings.projectsAreStoredInTheAppAnd,
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: AppColors.textSecondary),
          ],
        ),
      ),
    ),
  );

  Widget _body() {
    final projects = _projects;
    if (projects == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (widget.environmentChecking) {
      return _message(
        icon: Icons.manage_search,
        title: context.strings.checkingDevelopmentEnvironment,
        detail: context.strings.openDevelopmentEnvironmentForDetails,
        actions: [
          TextButton(
            onPressed: widget.onOpenEnvironment,
            child: Text(context.strings.viewDevelopmentEnvironment),
          ),
        ],
      );
    }
    if (!widget.environmentReady) {
      return _message(
        icon: Icons.build_circle_outlined,
        title: context.strings.developmentEnvironmentIsNotReady,
        detail: context.strings.yourProjectsWillAppearHereAfterSetup,
        actions: [
          FilledButton.icon(
            onPressed: widget.onOpenEnvironment,
            icon: const Icon(Icons.build_circle_outlined, size: 18),
            label: Text(context.strings.setUpDevelopmentEnvironment),
          ),
        ],
      );
    }
    return AnimatedBuilder(
      animation: projects,
      builder: (context, _) {
        if (projects.loading && projects.entries.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        final error = projects.error;
        if (error != null) {
          return _message(
            icon: Icons.error_outline,
            title: context.strings.failedToReadProjectDirectory,
            detail: error,
            actions: [
              OutlinedButton(
                onPressed: projects.refresh,
                child: Text(context.strings.retry),
              ),
            ],
          );
        }
        if (projects.entries.isEmpty) {
          return _message(
            icon: Icons.folder_open_outlined,
            title: context.strings.noProjectsYet,
            detail: context.strings.createAProjectOrCloneAGit,
            actions: [
              FilledButton.icon(
                onPressed: _busy ? null : _createProject,
                icon: const Icon(Icons.add, size: 18),
                label: Text(context.strings.newProject),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _cloneProject,
                icon: const Icon(Icons.download_outlined, size: 18),
                label: Text(context.strings.cloneRepository),
              ),
            ],
          );
        }
        return RefreshIndicator(
          onRefresh: projects.refresh,
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: projects.entries.length + 1,
            separatorBuilder: (_, index) =>
                SizedBox(height: index == 0 ? 0 : 8),
            itemBuilder: (context, index) => index == 0
                ? SectionLabel(
                    context.strings.projectsP(projects.entries.length),
                  )
                : _tile(projects.entries[index - 1]),
          ),
        );
      },
    );
  }

  Widget _tile(ProjectEntry entry) {
    final (icon, color) = switch (entry.kind) {
      ProjectKind.flutter => (Icons.flutter_dash, AppColors.accent),
      ProjectKind.dart => (Icons.code, AppColors.textPrimary),
      null => (Icons.folder_outlined, AppColors.textSecondary),
    };
    final modified = entry.modified;
    return SurfaceCard(
      padding: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(
          entry.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          [
            entry.kindLabel,
            if (modified != null) relativeTime(modified),
          ].join(' · '),
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
        trailing: PopupMenuButton<String>(
          tooltip: context.strings.more,
          icon: const Icon(Icons.more_vert, size: 20),
          onSelected: (action) => action == 'rename'
              ? _renameProject(entry)
              : _deleteProject(entry),
          itemBuilder: (_) => [
            PopupMenuItem(value: 'rename', child: Text(context.strings.rename)),
            PopupMenuItem(value: 'delete', child: Text(context.strings.delete)),
          ],
        ),
        onTap: () => widget.onOpenProject(entry.path),
      ),
    );
  }

  /// 居中的状态页(未就绪/空/出错); 横屏矮窗放不下时可滚动, 不溢出
  Widget _message({
    required IconData icon,
    required String title,
    required String detail,
    List<Widget> actions = const [],
  }) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 48, color: AppColors.textSecondary),
                const SizedBox(height: 16),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    height: 1.5,
                  ),
                ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    alignment: WrapAlignment.center,
                    children: actions,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// 重命名工程: 目录名校验, 确定返回新名字
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});
  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    final error = validateProjectName(name);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.strings.renameProject),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: InputDecoration(
        labelText: context.strings.projectDirectoryName,
        errorText: _error,
      ),
      onChanged: (_) {
        if (_error != null) setState(() => _error = null);
      },
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.strings.cancel),
      ),
      FilledButton(onPressed: _submit, child: Text(context.strings.ok)),
    ],
  );
}
