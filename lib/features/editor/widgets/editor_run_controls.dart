import 'package:flit/l10n/strings.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme.dart';
import '../../../core/workbench_controls.dart';
import '../../../services/adb_ops.dart';
import '../../../services/paths.dart';
import '../../../services/shell.dart';
import '../../device/device_connect_page.dart';
import '../../environment/android_build_wrapper.dart';
import '../../git/project_git.dart';
import '../../run/web_runner.dart';
import '../../terminal/run_sessions.dart';
import '../../terminal/console_session.dart' show ExecutionState;
import '../../workspace/project_actions.dart';
import '../../workspace/project_session.dart';
import '../workbench_layout.dart';

/// 顶栏任务操作(AS 式): [平台] [运行/重跑] [热重载*] [停止*] [任务]  (*运行中才出现)
/// 平台列表按工程类型: Flutter = Web 预览 + 已连 ADB 设备; Dart = 仅终端(dart run)。
class EditorRunControls extends StatefulWidget {
  const EditorRunControls({super.key});

  @override
  State<EditorRunControls> createState() => _EditorRunControlsState();
}

class _EditorRunControlsState extends State<EditorRunControls> {
  /// 工程与布局态来自 ProjectScope, 页面生命周期内不会换对象
  late final ProjectSession _project = context.read<ProjectSession>();
  late final WorkbenchLayout _layout = context.read<WorkbenchLayout>();
  RunSessions get _executions => _project.executions;
  bool get _isDart => _project.kind == ProjectKind.dart;
  String get _target => _isDart ? 'dart' : _project.runTarget;
  List<AdbDevice> _adbDevices = const [];

  @override
  void initState() {
    super.initState();
    _loadAdbDevices();
  }

  Future<void> _perform(Future<Object?> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<bool> _confirmRepair(AndroidRepairRequest request) async {
    if (!mounted || _project.closed) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              request.error == null
                  ? context.strings.installMissingAndroidBuildComponents
                  : context.strings.componentsCurrentlyUnavailable,
            ),
            content: SingleChildScrollView(
              child: Text(
                [
                  request.afterFailure
                      ? context.strings.theBuildFailedBecauseTheseComponentsAre
                      : context
                            .strings
                            .preflightFoundTheseMissingOrUnusableComponents,
                  '',
                  ...request.components.map((c) => '• ${c.title}'),
                  '',
                  request.error ??
                      context.strings.theBuildWillPAfterInstallationDownload(
                        request.afterFailure
                            ? context.strings.retryBuildVerb
                            : context.strings.continueBuildVerb,
                      ),
                ].join('\n'),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(
                  request.error == null
                      ? context.strings.cancel
                      : context.strings.gotIt,
                ),
              ),
              if (request.error == null)
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(
                    request.afterFailure
                        ? context.strings.installAndRetry
                        : context.strings.installAndContinue,
                  ),
                ),
            ],
          ),
        ) ==
        true;
  }

  List<Widget> _runControls() {
    final target = _target;
    final run = _executions.forConfiguration('run:$target');
    final web = _project.web;
    final alive = run?.alive == true;
    final active = _executions.activeRun;
    final activeOtherRun = active != null && active.id != run?.id;
    final starting =
        _project.actions.starting.value == 'run:$target' ||
        _executions.isStarting('run:$target') ||
        (target == 'web' && web.starting);
    // 已有设备连接可以与临时任务并存；有写入任务时不再启动/重启一次编译。
    final blocked =
        _project.actions.starting.value != null ||
        _project.git.busy ||
        _executions.conflictFor(
              RunConfiguration(
                id: 'run:$target',
                title: target,
                command: '',
                kind: SessionKind.run,
              ),
            ) !=
            null ||
        active?.state == ExecutionState.stopping;
    final canReload = target == 'web'
        ? web.canReload
        : run?.supportsReload == true;
    return [
      WorkbenchButton(
        tooltip: starting
            ? context.strings.starting
            : alive
            ? context.strings.rerun
            : context.strings.run,
        icon: starting
            ? Icons.hourglass_top_outlined
            : alive
            ? Icons.refresh
            : Icons.play_arrow,
        // 运行/重跑 = 绿; 启动中或被阻塞时禁用回灰。
        foreground: AppColors.success,
        onPressed: starting || blocked ? null : _runSelected,
      ),
      // Dart 会话不支持热重载(supportsReload=false), 按钮自然不出现
      if (alive && (target == 'web' || run!.supportsReload))
        WorkbenchButton(
          tooltip: context.strings.hotReload,
          icon: Icons.bolt,
          // 热重载 = 黄。
          foreground: AppColors.warn,
          onPressed: canReload && !blocked && !_executions.hasWritingTask
              ? () => _reloadRun(target, fullRestart: false)
              : null,
        ),
      if (alive || activeOtherRun)
        WorkbenchButton(
          tooltip: context.strings.stopRun,
          icon: Icons.stop_circle_outlined,
          // 停止 = 红; 已在停止时禁用回灰。
          foreground: AppColors.danger,
          onPressed: (alive ? run! : active!).stopRequested
              ? null
              : () => (alive ? run! : active!).stop(),
        ),
    ];
  }

  Future<void> _reloadRun(String target, {required bool fullRestart}) async {
    await _perform(
      () => _project.actions.reload(target, fullRestart: fullRestart),
    );
  }

  /// ▶: 运行选中的目标(Web = 本机预览; 设备 = flutter run 会话; Dart = dart run)。
  /// 无目标 → 打开目标选择; 目标已活 → 重启(rerun)。
  Future<void> _runSelected() async {
    if (_isDart) {
      _layout.showOutput();
      await _perform(_project.actions.runDart);
      return;
    }
    final target = _target;
    if (target.isEmpty) {
      await _pickTargetSheet();
      return;
    }
    _layout.showOutput();
    await _perform(() => _runTarget(target));
  }

  Future<void> _selectTarget(String target) async {
    if (target == _target) return;
    final active = _executions.activeRun;
    if (active != null) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.strings.switchRunTarget),
          content: Text(context.strings.stopTheCurrentRunAndStartThe),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.strings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.strings.switchAndRun),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      _applyTarget(target);
      _layout.showOutput();
      await _perform(() => _runTarget(target));
    } else {
      _applyTarget(target);
    }
  }

  /// 平台芯片为主控: 切换时终端视图跟随该目标的会话(未运行则回共享 bash),
  /// 预览只对 Web 目标有意义, 切到别的目标就退回代码
  void _applyTarget(String target) {
    _project.runTarget = target;
    final run = _executions.forConfiguration('run:$target');
    _executions.select(run?.alive == true ? run!.id : null);
    if (_layout.showPreview && target != 'web') {
      _layout.selectView(preview: false);
    }
  }

  Future<void> _runTarget(String target) async {
    if (target == 'web' && !await Directory('${_project.path}/web').exists()) {
      if (!mounted || _project.closed) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.strings.addWebSupport),
          content: Text(context.strings.addWebSupportDescription),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.strings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.strings.addAndRun),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted || _project.closed) return;
    }
    await _project.actions.run(target, confirmRepair: _confirmRepair);
  }

  /// 任务面板(AS Tools 菜单的对应): 依赖/构建/代码/维护分区, 每条都是
  /// 只读的临时会话(输出隔离 + chip 即进度灯), 按工程类型出内容。
  ///
  /// 桌面端不再用手机式底部抽屉：改成 480 宽的居中对话框（面板内容同一份），
  /// 构建按钮保留，构建成功后补“产物在哪”的提示。
  Future<void> _tasksSheet() async {
    final flutter = !_isDart;
    if (isDesktopPlatform) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: AppColors.surface,
          insetPadding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
            child: SafeArea(
              child: SingleChildScrollView(child: _tasksContent(ctx, flutter)),
            ),
          ),
        ),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [const SheetHandle(), _tasksContent(ctx, flutter)],
          ),
        ),
      ),
    );
  }

  Widget _tasksContent(BuildContext ctx, bool flutter) => ListenableBuilder(
    listenable: Listenable.merge([
      _executions,
      _project.actions.starting,
      _project.git,
    ]),
    builder: (_, _) {
      final runningTitles = _executions.all
          .where((s) => s.alive)
          .map((s) => s.title)
          .join('、');
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                Text(
                  context.strings.tasks,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  context.strings.currentProjectP(_project.name),
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textFaint,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_executions.active != null ||
              _project.actions.starting.value != null ||
              _project.git.busy)
            ListTile(
              dense: true,
              title: Text(
                context.strings.currentTaskP(
                  runningTitles.isNotEmpty
                      ? runningTitles
                      : (_project.git.busy
                            ? 'Git'
                            : context.strings.startingEllipsis),
                ),
              ),
              subtitle: Text(
                context.strings.tasksUseSeparateTerminalsConflictingActionsAre,
              ),
            ),
          _section(context.strings.dependencies, [
            _toolItem(
              ctx,
              ProjectTool.pubGet,
              context.strings.fetchDependenciesAndWritePackageConfig,
            ),
            _toolItem(
              ctx,
              ProjectTool.pubUpgrade,
              context.strings.upgradeDependenciesWithinConstraints,
            ),
            _toolItem(
              ctx,
              ProjectTool.pubOutdated,
              context.strings.listOutdatedDependencies,
            ),
          ]),
          _section(
            context.strings.build,
            flutter
                ? [
                    _buildItem(
                      ctx,
                      ProjectBuild.debugApk.configuration,
                      Icons.android_outlined,
                      context.strings.buildApkDebug,
                      context.strings.buildThenInstallOnTheSelectedAndroid,
                      () => _build(ctx, ProjectBuild.debugApk),
                    ),
                    _buildItem(
                      ctx,
                      ProjectBuild.releaseApk.configuration,
                      Icons.android_outlined,
                      context.strings.buildApkRelease,
                      context.strings.buildAReleaseApkThenChooseAdb,
                      () => _build(ctx, ProjectBuild.releaseApk),
                    ),
                    _buildItem(
                      ctx,
                      ProjectBuild.web.configuration,
                      Icons.web,
                      context.strings.buildWebRelease,
                      context.strings.outputDirectoryBuildWeb,
                      () => _build(ctx, ProjectBuild.web),
                    ),
                  ]
                : [
                    _buildItem(
                      ctx,
                      _project.actions.dartExeConfiguration,
                      Icons.memory_outlined,
                      context.strings.compileExecutable,
                      context.strings.dartCompileExeOutputBuildPackageName,
                      () => _project.actions.buildDartExe(),
                    ),
                  ],
          ),
          _section(context.strings.code, [
            _toolItem(
              ctx,
              ProjectTool.analyze,
              context.strings.runBatchAnalysisAndShowResultsIn,
            ),
            _toolItem(
              ctx,
              ProjectTool.test,
              context.strings.runTestsInTheTestDirectory,
            ),
          ]),
          if (flutter)
            _section(context.strings.maintenance, [
              _toolItem(
                ctx,
                ProjectTool.clean,
                context.strings.deleteBuildAndDartToolCaches,
              ),
              _toolItem(
                ctx,
                ProjectTool.doctor,
                context.strings.checkFlutterAndAndroidToolchainHealth,
              ),
            ]),
        ],
      );
    },
  );

  /// 构建入口：先把面板关掉并切到输出，再按平台补“产物在哪”的提示。
  ///
  /// 桌面端构建成功后会等会话真正结束，再弹“打开产物文件夹”；
  /// Android 端维持原样（产物卡由 editor 的 builtArtifacts 打开）。
  Future<RunSession> _build(BuildContext ctx, ProjectBuild kind) async {
    Navigator.pop(ctx);
    _layout.showOutput();
    final session = await _project.actions.build(
      kind,
      confirmRepair: _confirmRepair,
    );
    final artifact = session.configuration.artifactPath;
    if (isDesktopPlatform && artifact != null) {
      unawaited(
        session.done.then((code) {
          if (!mounted || code != 0 || session.stopRequested) return;
          _showArtifactHint(artifact);
        }),
      );
    }
    return session;
  }

  void _showArtifactHint(String artifact) {
    final absolute = joinPath(_project.path, artifact);
    final directory =
        FileSystemEntity.typeSync(absolute) == FileSystemEntityType.directory
        ? absolute
        : dirName(absolute);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('构建完成：$artifact'),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: '打开产物文件夹',
          onPressed: () => Shell.instance.revealDirectory(directory),
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> items) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.textFaint,
          ),
        ),
      ),
      ...items,
    ],
  );

  Widget _toolItem(BuildContext ctx, ProjectTool tool, String subtitle) =>
      ListTile(
        dense: true,
        leading: const Icon(
          Icons.terminal_outlined,
          size: 18,
          color: AppColors.textSecondary,
        ),
        title: Text(tool.title, style: const TextStyle(fontSize: 13)),
        subtitle: Text(
          subtitle,
          style: const TextStyle(fontSize: 11, color: AppColors.textFaint),
        ),
        onTap: _taskAction(ctx, tool.configuration(flutter: !_isDart), () {
          Navigator.pop(ctx);
          _layout.showOutput();
          _perform(
            () => _project.actions.tool(
              tool,
              flutter: _project.kind == ProjectKind.flutter,
            ),
          );
        }),
      );

  VoidCallback? _taskAction(
    BuildContext context,
    RunConfiguration configuration,
    VoidCallback action,
  ) {
    final existing = _executions.forConfiguration(configuration.id);
    if (existing?.alive == true) {
      return () {
        Navigator.pop(context);
        _executions.select(existing!.id);
        _layout.showOutput();
      };
    }
    if (_project.git.busy ||
        _executions.conflictFor(configuration) != null ||
        _executions.starting ||
        _project.actions.starting.value != null) {
      return null;
    }
    return action;
  }

  Widget _buildItem(
    BuildContext ctx,
    RunConfiguration configuration,
    IconData icon,
    String title,
    String subtitle,
    Future<RunSession> Function() action,
  ) => ListTile(
    dense: true,
    leading: Icon(icon, size: 18, color: AppColors.textSecondary),
    title: Text(title, style: const TextStyle(fontSize: 13)),
    subtitle: Text(
      subtitle,
      style: const TextStyle(fontSize: 11, color: AppColors.textFaint),
    ),
    onTap: _taskAction(ctx, configuration, () {
      Navigator.pop(ctx);
      _layout.showOutput();
      _perform(action);
    }),
  );

  Future<bool> _loadAdbDevices({bool reportError = false}) async {
    try {
      final devices = await AdbOps.devices();
      if (!mounted) return false;
      setState(() => _adbDevices = devices);
      _project.selectInitialTarget(devices);
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() => _adbDevices = const []);
      if (reportError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.strings.failedToReadDevicesP(error))),
        );
      }
      return false;
    }
  }

  Widget _deviceChip() {
    final sel = _target;
    String label;
    if (sel == 'web') {
      label = 'Web';
    } else if (sel.isEmpty) {
      label = context.strings.selectPlatform;
    } else {
      final hit = _adbDevices.where((d) => d.$1 == sel).toList();
      label = hit.isEmpty ? sel : AdbOps.describe(sel, hit.first.$2).$1;
    }
    return TextButton(
      onPressed:
          _project.actions.starting.value != null ||
              _executions.active?.state == ExecutionState.stopping
          ? null
          : _pickTargetSheet,
      style: TextButton.styleFrom(
        foregroundColor: AppColors.textSecondary,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            sel == 'web' ? Icons.language : Icons.devices_outlined,
            size: 16,
          ),
          const SizedBox(width: 4),
          // 顶栏空间有限: 平台名最多占 96, 超出省略
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 96),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
          ),
          const Icon(Icons.unfold_more, size: 14),
        ],
      ),
    );
  }

  /// Dart 工程唯一的运行位置: 终端。点击直接拉起输出面板, 没有平台可挑。
  Widget _terminalChip() => TextButton(
    onPressed: () => _layout.showOutput(),
    style: TextButton.styleFrom(
      foregroundColor: AppColors.textSecondary,
      minimumSize: const Size(0, 36),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.terminal, size: 16),
        SizedBox(width: 4),
        Text(context.strings.terminal, style: TextStyle(fontSize: 11)),
      ],
    ),
  );

  Future<void> _pickTargetSheet() async {
    if (_isDart) {
      _layout.showOutput();
      return;
    }
    await _loadAdbDevices(reportError: true);
    if (!mounted) return;
    final sel = _target;
    // Flutter 工程的运行平台: Web(本机预览) + 全部已连 Android 设备
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refreshSheet) {
          final targets = <(String, String)>[
            ('web', context.strings.webPreview),
            for (final (serial, model) in _adbDevices)
              (serial, AdbOps.describe(serial, model).$1),
          ];
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SheetHandle(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Row(
                    children: [
                      Text(
                        context.strings.runTarget,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: context.strings.refresh,
                        onPressed: () async {
                          await _loadAdbDevices(reportError: true);
                          if (ctx.mounted) refreshSheet(() {});
                        },
                        icon: const Icon(Icons.refresh, size: 20),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                for (final (target, name) in targets)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      target == 'web' ? Icons.web : Icons.smartphone,
                      size: 18,
                      color: target == 'web'
                          ? AppColors.warn
                          : AppColors.accent,
                    ),
                    title: Text(name, style: const TextStyle(fontSize: 13)),
                    subtitle: target == 'web'
                        ? Text(
                            context.strings.previewInsideTheIdeWithoutADevice,
                            style: TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                          )
                        : null,
                    trailing: sel == target
                        ? const Icon(
                            Icons.check,
                            size: 16,
                            color: AppColors.success,
                          )
                        : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      _selectTarget(target);
                    },
                  ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.link, size: 18),
                  title: Text(
                    context.strings.connectAndroidDevice,
                    style: TextStyle(fontSize: 13),
                  ),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const DeviceConnectPage(),
                      ),
                    );
                    if (mounted) await _loadAdbDevices(reportError: true);
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
    if (mounted) setState(() {}); // 芯片文字随选择刷新
  }

  @override
  Widget build(BuildContext context) {
    context.watch<RunSessions>();
    context.watch<WebRunController>();
    context.watch<ProjectSession>();
    context.watch<ProjectActions>();
    context.watch<ProjectGit>();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isDart) _terminalChip() else _deviceChip(),
        for (final control in _runControls())
          SizedBox(width: 38, child: control),
        WorkbenchButton(
          icon: Icons.handyman_outlined,
          tooltip: context.strings.tasks,
          onPressed: _tasksSheet,
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}
