import 'package:flit/l10n/strings.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/desktop/app_commands.dart';
import '../../core/theme.dart';
import '../../core/page_layout.dart';
import '../../l10n/desktop_strings.dart';

import '../../services/desktop_toolchain.dart';
import '../../services/native_file_service.dart';
import '../../services/paths.dart';
import '../../services/shell.dart';
import '../workspace/project_session.dart';
import '../terminal/console_session.dart';
import '../terminal/terminal_host.dart';
import 'clone_project_page.dart';
import 'create_project_page.dart';
import 'desktop_projects_view.dart';
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

  /// 桌面菜单/快捷键注册（Android 没有菜单，不注册）。
  AppCommands? _commands;
  final _registeredCommands = <AppCommand>[];

  @override
  void initState() {
    super.initState();
    _registerDesktopCommands();
    unawaited(_init());
  }

  /// 工程列表页是桌面的主页面：文件菜单、View 菜单和快捷键都指向这里的动作。
  /// 只注册自己负责的命令，退出页面时按名注销，避免清空编辑器的注册表。
  void _registerDesktopCommands() {
    if (!isDesktopPlatform) return;
    final AppCommands commands;
    try {
      commands = context.read<AppCommands>();
    } catch (_) {
      return; // 组件单测直接挂页面、没有 AppScope 时静默跳过
    }
    _commands = commands;
    void bind(AppCommand command, VoidCallback handler) {
      commands.register(command, handler);
      _registeredCommands.add(command);
    }

    bind(AppCommand.newProject, _createProject);
    bind(AppCommand.openProject, _openProjectFromFolder);
    bind(AppCommand.importProject, _importFolder);
    bind(AppCommand.openSettings, widget.onOpenSettings);
    bind(AppCommand.openEnvironment, widget.onOpenEnvironment);
    bind(
      AppCommand.refresh,
      () => unawaited(_projects?.refresh() ?? Future<void>.value()),
    );
  }

  Future<void> _init() async {
    final status = await Shell.instance
        .bootstrapStatus()
        .timeout(const Duration(seconds: 5))
        .catchError((_) => <dynamic, dynamic>{});
    final home = (status['home'] as String? ?? '').trim();
    final root = home.isNotEmpty
        ? (isDesktopPlatform ? joinPath(home, 'projects') : '$home/projects')
        : (isDesktopPlatform
              ? DesktopToolchain().projectsDir
              : '/data/user/0/com.seek888.flit/files/home/projects');
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
    // 列表项路径与工程打开路径可能来自不同拼接点（Windows 分隔符/大小写），
    // 直接比字符串会漏判，导致"正在打开的工程"被改名/删除。
    if (samePath(path, active.path) ||
        relativeInside(active.path, path) != null ||
        relativeInside(path, active.path) != null) {
      throw StateError(
        context.strings.closeThisProjectBeforeRenamingOrDeleting,
      );
    }
  }

  @override
  void dispose() {
    final commands = _commands;
    if (commands != null) {
      for (final command in _registeredCommands) {
        commands.unregister(command);
      }
    }
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
        // 桌面专属文案先硬编码（不随 Android 的"卸载即删"语义，见 l10n 清单）。
        isDesktopPlatform
            ? '工程目录：${_projectsRoot ?? ''}\n\n'
                  '桌面端工程放在本机应用目录，卸载应用不会删除工程；'
                  '可直接用资源管理器打开、压缩备份，或推送到 GitHub 仓库。'
            : (context.strings.projectDirectoryP(_projectsRoot ?? '') +
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

  /// 导入已有工程：原生文件夹选择器选中的目录直接作为工作区打开（不复制文件）。
  Future<void> _importFolder() async {
    if (_busy || !_requireEnvironment()) return;
    final path = await NativeFileService.pickDirectory(
      initialDirectory: _projectsRoot,
      title: desktopStrings(context).importProject,
    );
    if (path == null || !mounted) return;
    widget.onOpenProject(path);
    unawaited(_projects?.refresh());
  }

  /// 打开工程：与导入一致，桌面用系统选择器定位任意位置的工程。
  Future<void> _openProjectFromFolder() async {
    if (_busy || !_requireEnvironment()) return;
    final path = await NativeFileService.pickProjectDirectory();
    if (path == null || !mounted) return;
    widget.onOpenProject(path);
    unawaited(_projects?.refresh());
  }

  /// 在资源管理器中打开工程根目录。
  Future<void> _openProjectsFolder() async {
    final root = _projectsRoot;
    if (root == null) return;
    final opened = await NativeFileService.openFolder(root);
    if (!opened && mounted) _snack(root);
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
      _pendingProjectPath = joinPath(params.projectRoot, params.name);
      _pendingMarker = 'create';
    });
    final String command;
    String? workingDirectory;
    if (isDesktopPlatform) {
      // 桌面端没有 bash：目录用 Dart 建，flutter/dart create 参数化直跑。
      try {
        Directory(params.projectRoot).createSync(recursive: true);
      } catch (error) {
        setState(() => _busy = false);
        _snack('$error');
        return;
      }
      command = buildDesktopCreateCommand(params);
      // 桌面命令串里没有 `cd`（目录已建好），PTY 必须显式在工程根里启动；
      // 否则 cmd 会落在工具链 home，`flutter create my_app` 会在
      // `<home>/my_app` 生成工程，而列表打开的是 `<home>/projects/my_app`
      // ——正是「创建成功但工程目录是空的」。
      workingDirectory = params.projectRoot;
    } else {
      // Android 的命令串自带 `mkdir -p` + `cd`，不需要 PTY 工作目录。
      command = params.type == 'dart'
          ? buildDartCreateCommand(params)
          : buildFlutterCreateCommand(params);
    }
    await _runTask(
      command,
      openOnSuccess: true,
      workingDirectory: workingDirectory,
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

    final cloneTarget = joinPath(params.targetDir, params.dirName);
    // 桌面端允许把仓库克隆到工程根以外；那种情况下列表刷新看不到，直接打开。
    final outsideRoot = !samePath(params.targetDir, root);
    setState(() {
      _busy = true;
      _termExpanded = true;
      _pendingName = params.dirName;
      _pendingProjectPath = cloneTarget;
      _pendingMarker = 'clone';
    });
    await _runTask(
      buildGitCloneCommand(params),
      openOnSuccess: isDesktopPlatform && outsideRoot,
    );
  }

  Future<void> _runTask(
    String command, {
    required bool openOnSuccess,
    String? workingDirectory,
  }) async {
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
    final code = await task.run(
      command,
      workingDirectory: workingDirectory,
    );
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

  /// 桌面工作台主页面：工具条 + 工程表；手机端仍走下面的卡片列表。
  Widget _desktopScaffold() {
    final ready = _projects != null && !_busy;
    return Scaffold(
      body: TerminalHost(
        session: _task,
        expanded: _termExpanded,
        running: _busy,
        onToggle: () => setState(() => _termExpanded = !_termExpanded),
        child: DesktopProjectsView(
          projects: _projects,
          projectsRoot: _projectsRoot,
          environmentReady: widget.environmentReady,
          environmentChecking: widget.environmentChecking,
          busy: _busy,
          onOpenProject: widget.onOpenProject,
          onCreateProject: ready ? () => unawaited(_createProject()) : null,
          onCloneProject: ready ? () => unawaited(_cloneProject()) : null,
          onImportFolder: ready ? () => unawaited(_importFolder()) : null,
          onOpenFolder: ready ? () => unawaited(_openProjectsFolder()) : null,
          onOpenEnvironment: widget.onOpenEnvironment,
          onOpenSettings: widget.onOpenSettings,
          onRefresh: () =>
              unawaited(_projects?.refresh() ?? Future<void>.value()),
          onRename: (entry) => unawaited(_renameProject(entry)),
          onDelete: (entry) => unawaited(_deleteProject(entry)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isDesktopPlatform) return _desktopScaffold();
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
                isDesktopPlatform
                    ? '工程保存在本机应用目录，可直接用资源管理器打开'
                    : context.strings.projectsAreStoredInTheAppAnd,
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
