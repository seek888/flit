import 'package:flit/l10n/strings.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../services/paths.dart';
import 'controller/code_controller.dart';
import 'file_kind.dart';
import 'widgets/editor_dock_toolbar.dart';
import 'widgets/markdown_preview.dart';
import 'widgets/svg_preview.dart';
import 'widgets/editor_file_tabs.dart';
import 'widgets/editor_analysis_status.dart';
import 'widgets/editor_surface.dart';
import 'widgets/editor_run_controls.dart';
import 'widgets/file_card.dart';
import '../terminal/terminal_session_tabs.dart';
import 'widgets/file_tree_drawer.dart';
import 'workbench_layout.dart';
import '../git/git_panel.dart';
import '../run/web_runner.dart';
import '../workspace/editor_tabs.dart';
import '../workspace/project_scope.dart';
import '../workspace/project_session.dart';
import '../workspace/workspace_views.dart';
import '../terminal/run_sessions.dart';
import '../terminal/terminal_host.dart';
import '../settings/settings_page.dart';
import '../run/web_run_page.dart';

/// 编辑器页: 顶栏第二行是打开项 tab(代码文件=编辑器, 其余文件=文件卡) +
/// 文件树抽屉 + 内嵌真终端。编译/构建命令统一作为终端命令执行(输出实时回显在终端)。
///
/// 页面只做三件事: 把工程挂进 ProjectScope、承载布局、串起"打开/关闭/保存"
/// 这些跨对象的流程; 工程数据在 ProjectSession, 界面布局态在 WorkbenchLayout。
class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.projectPath,
    required this.projectName,
    required this.session,
  });

  final String projectPath;
  final String projectName;

  /// 由 ProjectWorkspace 打开并持有; 页面只呈现, 不创建也不独自关闭它
  final ProjectSession session;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> with WidgetsBindingObserver {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _viewsKey = GlobalKey();
  LocalHistoryEntry? _previewEntry;

  late final ProjectSession _project;
  late final WorkbenchLayout _layout;
  RunSessions get _executions => _project.executions;
  EditorTabs get _tabs => _project.tabs;
  OpenItem? get _current => _tabs.current;
  final _emptyController = CodeController();
  CodeController get _codeCtrl => switch (_current) {
    CodeTab(:final document) => document.controller,
    _ => _emptyController,
  };

  /// 当前 tab 的相对路径(代码或文件卡)
  String? get _openFile => _current?.path;

  /// 当前代码缓冲是可渲染文档(md/svg)时, 工具栏出现预览切换
  String? get _docPreviewFormat => switch (_current) {
    CodeTab(:final path) => renderableDocumentFormat(path),
    _ => null,
  };
  bool get _previewableOpen => _docPreviewFormat != null;
  final _editorFocus = FocusNode();
  bool _loadingFile = false;

  /// 可渲染文档的预览开关; 换 tab/换文件即复位
  bool _docPreview = false;
  int _fileSeq = 0;
  int _gitRevision = 0;
  StreamSubscription<String>? _artifacts;

  @override
  void initState() {
    super.initState();
    _project = widget.session;
    _layout = WorkbenchLayout(_executions);
    _layout.addListener(_syncPreviewEntry);
    // git 变化的副作用: 工作树变了重扫文件树, 出错提示; 重建由 watch 负责
    _project.git.addListener(_onGitChanged);
    // 构建成功 → 产物开成文件卡 tab(名字/大小/安装/分享都在眼前)
    _artifacts = _project.actions.builtArtifacts.listen(_openFileByPath);
    WidgetsBinding.instance.addObserver(this);
    _refreshFiles();
    if (_tabs.isEmpty) unawaited(_openFileByPath('lib/main.dart'));
    _editorFocus.addListener(_onFocusChanged);
    unawaited(_project.activate());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _flushSave();
  }

  Future<bool> _flushSave() => _project.documents.saveAll();

  Future<bool> _save({bool silent = false}) async {
    final ok = await _flushSave();
    if (mounted && (!ok || !silent)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? context.strings.saved
                : _project.documents.conflictPath != null
                ? context.strings.fileChangedExternallySavingStoppedTapThe
                : context.strings.saveFailedPleaseRetry,
          ),
        ),
      );
    }
    return ok;
  }

  Future<void> _retrySave() async {
    final path = _project.documents.conflictPath;
    if (path == null) {
      await _save();
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.strings.fileChangedExternally),
        content: Text(
          context.strings.pSavingStoppedToAvoidOverwritingDisk(path),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.strings.reloadFromDisk),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    try {
      await _project.documents.reload(path);
    } catch (error) {
      if (mounted) _showMessage('$error');
    }
  }

  void _onGitChanged() {
    if (!mounted || _gitRevision == _project.git.revision) return;
    _gitRevision = _project.git.revision;
    unawaited(_refreshFiles());
    if (_project.git.error != null) _showMessage(_project.git.error!);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String? _currentPath() =>
      _current == null ? null : joinPath(widget.projectPath, _current!.path);

  // ---------- 文件 ----------

  Future<void> _refreshFiles() async {
    try {
      await _project.files.refresh();
    } catch (error) {
      if (mounted) _showMessage('$error');
      return;
    }
    if (!mounted) return;
  }

  /// 打开一个文件到 tab: 代码进编辑器缓冲, 图片/二进制开文件卡;
  /// [asText] 强制按文本打开(重选已有代码 tab)
  Future<void> _openFileByPath(String rel, {bool asText = false}) async {
    // 只在抽屉打开时才 pop(关抽屉); initState 自动打开默认文件时没有抽屉,
    // 无条件 pop 会把编辑器页自己弹掉(进页即退)
    if (_scaffoldKey.currentState?.isDrawerOpen == true) {
      Navigator.pop(context);
    }
    final kind = asText ? FileKind.code : await _project.files.kindOf(rel);
    if (!mounted || _project.closed) return;
    if (kind != FileKind.code) {
      _layout.selectView(preview: false);
      _tabs.showFile(rel, kind);
      return;
    }
    if (_openFile != rel && !await _save(silent: true)) return;
    if (!mounted || _project.closed) return;
    _layout.selectView(preview: false);
    final seq = ++_fileSeq;
    setState(() => _loadingFile = true);
    try {
      if (!await _project.documents.open(rel) || !mounted || seq != _fileSeq) {
        return;
      }
      final document = _project.documents.current;
      if (document == null) return;
      // "以文本打开"替换掉同路径的文件卡, 位置不变
      FileTab? card;
      for (final item in _tabs.items) {
        if (item is FileTab && item.path == rel) card = item;
      }
      int? at;
      if (card != null) {
        at = _tabs.indexOf(card);
        _tabs.close(card);
      }
      _tabs.showDocument(document, at: at);
    } catch (_) {
      if (mounted && seq == _fileSeq) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.strings.unableToReadP(rel))),
        );
      }
    } finally {
      if (mounted && seq == _fileSeq) setState(() => _loadingFile = false);
    }
  }

  // ---------- tab ----------

  Future<void> _selectTab(OpenItem item) async {
    if (identical(_current, item)) return;
    if (item is CodeTab) {
      setState(() => _docPreview = false);
      // 重选代码 tab 走同一条打开路径: 干净缓冲顺便和磁盘重新同步
      await _openFileByPath(item.path, asText: true);
    } else {
      _layout.selectView(preview: false);
      _tabs.select(item);
    }
  }

  /// 关代码 tab = 释放缓冲(先落盘, 失败则留着并提示); 缓冲没了 tab 自动消失
  Future<void> _closeTab(OpenItem item) async {
    if (_project.documents.synchronizing) {
      _showMessage(context.strings.aFileOperationIsInProgressWait);
      return;
    }
    if (item is CodeTab) {
      try {
        await _project.documents.closeDocument(item.document);
      } catch (e) {
        _showMessage(e is StateError ? e.message : '$e');
        return;
      }
    } else {
      _tabs.close(item);
    }
    await _activateCurrent();
  }

  Future<void> _closeOthers(OpenItem keep) async {
    if (_project.documents.synchronizing) {
      _showMessage(context.strings.aFileOperationIsInProgressWait);
      return;
    }
    for (final item in _tabs.items) {
      if (identical(item, keep) || !mounted) continue;
      if (item is CodeTab) {
        try {
          await _project.documents.closeDocument(item.document);
        } catch (e) {
          _showMessage(e is StateError ? e.message : '$e');
          break;
        }
      } else {
        _tabs.close(item);
      }
    }
    if (!mounted) return;
    _tabs.select(keep);
    await _activateCurrent();
  }

  /// 关闭后把新的当前项真正显示出来(代码项要让缓冲成为 documents.current)
  Future<void> _activateCurrent() async {
    if (!mounted) return;
    final current = _current;
    if (current is CodeTab) await _openFileByPath(current.path, asText: true);
  }

  // ---------- 布局 ----------

  /// 预览的"返回键回代码"靠路由的 LocalHistoryEntry; 它随布局态同步增删,
  /// 撤销(返回键)时再反过来通知布局态——两边各管一头, 不互相递归。
  void _syncPreviewEntry() {
    if (_layout.showPreview && _previewEntry == null) {
      _previewEntry = LocalHistoryEntry(
        onRemove: () {
          _previewEntry = null;
          if (mounted) _layout.previewDismissed();
        },
      );
      ModalRoute.of(context)?.addLocalHistoryEntry(_previewEntry!);
    } else if (!_layout.showPreview && _previewEntry != null) {
      final entry = _previewEntry!;
      _previewEntry = null;
      entry.remove();
    }
  }

  void _toggleTerminal() =>
      _layout.toggleTerminal(editing: _editorFocus.hasFocus);

  Future<void> _closeProject() async {
    if (_project.git.busy) {
      _showMessage(context.strings.aGitOperationIsRunningWaitOr);
      return;
    }
    if (_project.documents.synchronizing) {
      _showMessage(context.strings.aFileOperationIsInProgressWait552);
      return;
    }
    final workspace = context.read<ProjectWorkspace>();
    if (!await _save(silent: true)) return;
    final ok = identical(workspace.active, _project)
        ? await workspace.closeActive()
        : await _project.close();
    if (ok && mounted) {
      _previewEntry?.remove();
      Navigator.of(context).pop();
    }
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _editorFocus.removeListener(_onFocusChanged);
    _project.git.removeListener(_onGitChanged);
    _layout.removeListener(_syncPreviewEntry);
    unawaited(_artifacts?.cancel());
    if (!_project.closed) _project.web.setClientReady(false);
    _layout.dispose();
    _emptyController.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ProjectScope(
      session: _project,
      layout: _layout,
      // 工程对象的 watch 必须在 ProjectScope 之下: 这里单独起一层 context
      child: Builder(builder: (context) => _workbench(context)),
    );
  }

  Widget _workbench(BuildContext context) {
    if (context.watch<ProjectSession>().closed) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final layout = context.watch<WorkbenchLayout>();
    final tabs = context.watch<EditorTabs>();
    final executions = context.watch<RunSessions>();
    final web = context.watch<WebRunController>();
    final runTarget = context.select((ProjectSession p) => p.runTarget);
    final busy = executions.all.any(
      (s) => s.alive && s.configuration.kind == SessionKind.temp,
    );
    final editing = _editorFocus.hasFocus;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _flushSave(); // 防抖中的内容在返回时落盘(后台完成)
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () async {
              if (!_project.documents.synchronizing &&
                  !await _save(silent: true)) {
                return;
              }
              unawaited(_project.git.refresh());
              if (!mounted) return;
              _scaffoldKey.currentState?.openDrawer();
            },
          ),
          title: _title(tabs),
          // AS 式顶栏任务操作: 平台 · 运行 · (热重载/停止) · 构建
          actions: const [EditorRunControls()],
          // 第二行: 打开项 tab(AS 的编辑器 tab 行); 没有打开项就不占高度
          bottom: tabs.isEmpty
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(EditorFileTabs.height),
                  child: EditorFileTabs(
                    trailing: _current is CodeTab
                        ? EditorAnalysisStatus(
                            controller: _codeCtrl,
                            focusNode: _editorFocus,
                          )
                        : null,
                    onSelect: _selectTab,
                    onClose: _closeTab,
                    onCloseOthers: _closeOthers,
                  ),
                ),
        ),
        drawer: _drawer(),
        onDrawerChanged: (open) {
          if (open) unawaited(_refreshFiles());
        },
        body: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, screen) {
                  final editorColumn = Stack(
                    children: [
                      Positioned.fill(
                        child: switch (_current) {
                          null => _emptyHint(),
                          CodeTab(:final document) => switch ((
                            _previewableOpen,
                            _docPreview,
                            _docPreviewFormat,
                          )) {
                            (true, true, 'svg') => SvgPreview(
                              key: const ValueKey('svg-preview'),
                              controller: document.controller,
                            ),
                            (true, true, _) => MarkdownPreview(
                              key: ValueKey('md:${_currentPath()}'),
                              controller: document.controller,
                              projectRoot: widget.projectPath,
                            ),
                            _ => EditorSurface(
                              key: ValueKey(_currentPath()),
                              controller: document.controller,
                              path: _currentPath()!,
                              focusNode: _editorFocus,
                            ),
                          },
                          FileTab(:final path, :final kind) => FileCard(
                            key: ValueKey('file:$path'),
                            projectRoot: widget.projectPath,
                            path: path,
                            kind: kind,
                          ),
                        },
                      ),
                      if (_loadingFile)
                        const Positioned.fill(
                          child: ColoredBox(
                            color: AppColors.bg,
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        ),
                    ],
                  );
                  final content = WorkspaceViews(
                    key: _viewsKey,
                    code: editorColumn,
                    preview: const WebRunPreview(),
                    showPreview: layout.showPreview,
                    hasPreview: web.state != WebRunState.idle,
                  );
                  return TerminalHost(
                    // MD 预览与编辑同样不自动弹终端
                    expanded:
                        layout.terminalExpanded && !editing && !_docPreview,
                    onToggle: _toggleTerminal,
                    footer: EditorDockToolbar(
                      controller: _codeCtrl,
                      previewAvailable:
                          runTarget == 'web' || web.state != WebRunState.idle,
                      showPreview: layout.showPreview,
                      terminalExpanded: layout.terminalExpanded && !editing,
                      docPreviewAvailable: _previewableOpen,
                      docPreviewOn: _docPreview,
                      docPreviewLabel: _docPreviewFormat == 'svg'
                          ? 'SVG'
                          : 'MD',
                      onDocPreview: () =>
                          setState(() => _docPreview = !_docPreview),
                      canEdit:
                          !layout.showPreview &&
                          !_docPreview &&
                          _current is CodeTab,
                      onCode: () {
                        setState(() => _docPreview = false);
                        _layout.selectView(preview: false);
                      },
                      onPreview: () => _layout.selectView(preview: true),
                      onTerminal: _toggleTerminal,
                    ),
                    running: busy,
                    preferredHeight: 260,
                    session: executions.console,
                    sessionsBar: const TerminalSessionTabs(),
                    child: content,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 标题: 工程名 + 保存状态(有代码 tab 或保存失败时才显示第二行)
  Widget _title(EditorTabs tabs) => ListenableBuilder(
    listenable: _project.documents,
    builder: (_, _) {
      final documents = _project.documents;
      final status = documents.saveFailed
          ? documents.conflictPath != null
                ? context.strings.fileChangedTapToResolve
                : context.strings.saveFailedTapToRetry
          : documents.saving
          ? context.strings.saving
          : documents.dirty
          ? context.strings.unsaved
          : context.strings.saved;
      final hasCode = tabs.items.any((item) => item is CodeTab);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.projectName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
          ),
          if (hasCode || documents.saveFailed)
            InkWell(
              onTap: documents.saveFailed ? _retrySave : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: documents.saveFailed
                        ? AppColors.danger
                        : AppColors.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _drawer() => Drawer(
    backgroundColor: AppColors.bg,
    child: SafeArea(
      child: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            Material(
              color: AppColors.surface,
              child: TabBar(
                labelColor: AppColors.accent,
                unselectedLabelColor: AppColors.textSecondary,
                indicatorColor: AppColors.accent,
                dividerColor: AppColors.border,
                tabs: [
                  Tab(text: context.strings.project),
                  Tab(text: context.strings.versionControl),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  FileTreeDrawer(asContent: true, onOpenFile: _openFileByPath),
                  const GitPanel(),
                ],
              ),
            ),
            // 工程级操作放抽屉底部(AS 的 File 菜单位), 顶栏只留任务操作。
            // 用 Navigator.pop 关抽屉: 同步摘掉其 LocalHistoryEntry,
            // 之后 _closeProject 末尾的 pop 才会真正退出页面
            const Divider(height: 1, color: AppColors.border),
            ListTile(
              dense: true,
              leading: const Icon(Icons.settings_outlined, size: 20),
              title: Text(
                context.strings.settings,
                style: TextStyle(fontSize: 13),
              ),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.logout, size: 20),
              title: Text(
                context.strings.closeProject,
                style: TextStyle(fontSize: 13),
              ),
              onTap: () {
                Navigator.pop(context);
                _closeProject();
              },
            ),
          ],
        ),
      ),
    ),
  );

  Widget _emptyHint() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.code, size: 56, color: AppColors.textDisabled),
          const SizedBox(height: 10),
          Text(
            context.strings.selectAFileFromTheProjectTool,
            style: TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            icon: const Icon(Icons.folder_open),
            label: Text(context.strings.openProjectToolWindow),
          ),
        ],
      ),
    );
  }
}
