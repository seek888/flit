import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/desktop/hover.dart';
import '../../core/page_layout.dart';
import '../../core/theme.dart';
import '../../l10n/desktop_strings.dart';
import '../../l10n/strings.dart';
import '../../services/native_file_service.dart';
import '../workspace/project_session.dart' show ProjectKind;
import 'project_list.dart';

/// 桌面工程列表：44px 工具条 + 搜索框 + 工程表格。
///
/// 行高 38、名称/路径/类型/修改时间四列；悬停高亮、单选、双击打开、右键菜单，
/// ↑↓ 选择、Enter 打开、Delete 移除。窗口窄于 760 时收起路径列，保证 400 宽
/// 也不溢出。手机端仍由 [ProjectsPage] 的卡片列表负责。
class DesktopProjectsView extends StatefulWidget {
  const DesktopProjectsView({
    super.key,
    required this.projects,
    required this.projectsRoot,
    required this.environmentReady,
    required this.environmentChecking,
    required this.busy,
    required this.onOpenProject,
    required this.onCreateProject,
    required this.onCloneProject,
    required this.onImportFolder,
    required this.onOpenFolder,
    required this.onOpenEnvironment,
    required this.onOpenSettings,
    required this.onRefresh,
    required this.onRename,
    required this.onDelete,
  });

  final ProjectList? projects;
  final String? projectsRoot;
  final bool environmentReady;
  final bool environmentChecking;
  final bool busy;
  final void Function(String path) onOpenProject;
  final VoidCallback? onCreateProject;
  final VoidCallback? onCloneProject;
  final VoidCallback? onImportFolder;
  final VoidCallback? onOpenFolder;
  final VoidCallback onOpenEnvironment;
  final VoidCallback onOpenSettings;
  final VoidCallback onRefresh;
  final void Function(ProjectEntry entry) onRename;
  final void Function(ProjectEntry entry) onDelete;

  @override
  State<DesktopProjectsView> createState() => _DesktopProjectsViewState();
}

class _DesktopProjectsViewState extends State<DesktopProjectsView> {
  final _search = TextEditingController();
  final _listFocus = FocusNode(debugLabel: 'desktop-projects');
  final _rowKeys = <int, GlobalKey>{};
  int? _selected;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      final value = _search.text.trim();
      if (value == _query) return;
      setState(() {
        _query = value;
        _selected = null;
      });
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _listFocus.dispose();
    super.dispose();
  }

  DesktopStrings get t => desktopStrings(context);

  bool get _zh => Localizations.localeOf(context).languageCode.startsWith('zh');

  String _tr(String zh, String en) => _zh ? zh : en;

  void _select(int? index) {
    setState(() => _selected = index);
    if (index == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _rowKeys[index]?.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          alignment: .5,
          duration: const Duration(milliseconds: 120),
        );
      }
    });
  }

  List<ProjectEntry> _filtered(List<ProjectEntry> entries) {
    if (_query.isEmpty) return entries;
    final query = _query.toLowerCase();
    return entries
        .where(
          (entry) =>
              entry.name.toLowerCase().contains(query) ||
              entry.path.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final entries = _filtered(widget.projects?.entries ?? const []);
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _select(entries.isEmpty ? null : ((_selected ?? -1) + 1).clamp(
          0,
          entries.length - 1,
        ));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _select(entries.isEmpty ? null : ((_selected ?? entries.length) - 1)
            .clamp(0, entries.length - 1));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        final index = _selected;
        if (index != null && index < entries.length) {
          widget.onOpenProject(entries[index].path);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case LogicalKeyboardKey.delete:
        final index = _selected;
        if (index != null && index < entries.length) {
          widget.onDelete(entries[index]);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(),
        _searchBar(),
        Expanded(child: _content()),
      ],
    );
  }

  // ---------- 工具条 ----------

  Widget _toolbar() {
    final ready =
        widget.environmentReady && !widget.busy && widget.projects != null;
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  _toolButton(
                    icon: Icons.add,
                    label: t.newProject,
                    onPressed: ready ? widget.onCreateProject : null,
                  ),
                  _toolButton(
                    icon: Icons.download_outlined,
                    label: context.strings.cloneRepository,
                    onPressed: ready ? widget.onCloneProject : null,
                  ),
                  _toolButton(
                    icon: Icons.create_new_folder_outlined,
                    label: '${t.importProject}…',
                    onPressed: ready ? widget.onImportFolder : null,
                  ),
                  _toolButton(
                    icon: Icons.folder_open_outlined,
                    label: '${t.openFolder}…',
                    onPressed: widget.projectsRoot == null
                        ? null
                        : widget.onOpenFolder,
                  ),
                  _toolButton(
                    icon: Icons.refresh,
                    label: t.refresh,
                    onPressed: widget.busy ? null : widget.onRefresh,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(
            height: 20,
            child: VerticalDivider(width: 1, color: AppColors.divider),
          ),
          _toolButton(
            icon: Icons.build_circle_outlined,
            label: _tr('开发环境', 'Environment'),
            onPressed: widget.onOpenEnvironment,
          ),
          _toolButton(
            icon: Icons.settings_outlined,
            label: t.settings,
            onPressed: widget.onOpenSettings,
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _toolButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: Tooltip(
      message: label,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        style: TextButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          minimumSize: const Size(0, 30),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    ),
  );

  // ---------- 搜索 ----------

  Widget _searchBar() => LayoutBuilder(
    builder: (context, constraints) => Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: Row(
        children: [
          SizedBox(
            width: constraints.maxWidth < 520
                ? constraints.maxWidth
                : 340,
            height: 30,
            child: TextField(
              controller: _search,
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 16),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 30,
                  minHeight: 30,
                ),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: t.close,
                        icon: const Icon(Icons.close, size: 14),
                        onPressed: _search.clear,
                        style: IconButton.styleFrom(
                          minimumSize: const Size(28, 28),
                          padding: EdgeInsets.zero,
                        ),
                      ),
                suffixIconConstraints: const BoxConstraints(
                  minWidth: 28,
                  minHeight: 28,
                ),
                hintText: _tr('搜索工程', 'Search projects'),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
              ),
            ),
          ),
          if (constraints.maxWidth >= 520) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.projectsRoot ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            if (widget.onOpenFolder != null)
              TextButton.icon(
                onPressed: widget.onOpenFolder,
                icon: const Icon(Icons.open_in_new, size: 14),
                label: Text(
                  t.openFolder,
                  style: const TextStyle(fontSize: 11),
                ),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ],
      ),
    ),
  );

  // ---------- 内容 ----------

  Widget _content() {
    final projects = widget.projects;
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
            icon: const Icon(Icons.build_circle_outlined, size: 16),
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
                onPressed: widget.onRefresh,
                child: Text(context.strings.retry),
              ),
            ],
          );
        }
        final entries = _filtered(projects.entries);
        if (projects.entries.isEmpty) {
          return _emptyState();
        }
        if (entries.isEmpty) {
          return _message(
            icon: Icons.search_off,
            title: _tr('没有匹配的工程', 'No matching projects'),
            detail: _tr('换个关键词，或清空搜索框。', 'Try another keyword.'),
            actions: [
              TextButton(
                onPressed: _search.clear,
                child: Text(_tr('清空搜索', 'Clear search')),
              ),
            ],
          );
        }
        if (_selected != null && _selected! >= entries.length) {
          _selected = null;
        }
        return PageContent(
          maxWidth: 1180,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _tableHeader(),
              Expanded(
                child: Focus(
                  focusNode: _listFocus,
                  autofocus: true,
                  onKeyEvent: _onKey,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return _ProjectRow(
                        key: _keyFor(index),
                        entry: entry,
                        selected: _selected == index,
                        onSelected: () {
                          _listFocus.requestFocus();
                          _select(index);
                        },
                        onOpen: () => widget.onOpenProject(entry.path),
                        onRename: () => widget.onRename(entry),
                        onDelete: () => widget.onDelete(entry),
                        onCopyPath: () => _copy(entry.path),
                        onReveal: () => _reveal(entry.path),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Key _keyFor(int index) =>
      _rowKeys.putIfAbsent(index, () => GlobalKey(debugLabel: 'project-$index'));

  Widget _tableHeader() => PageContent(
    maxWidth: 1180,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        return Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.divider)),
          ),
          child: _cells(
            wide: wide,
            name: _tr('名称', 'Name'),
            path: _tr('路径', 'Path'),
            kind: _tr('类型', 'Type'),
            modified: _tr('修改时间', 'Modified'),
          ),
        );
      },
    ),
  );

  /// 表头与行共用的列布局：窄窗口隐藏路径列。
  Widget _cells({
    required bool wide,
    required String name,
    required String path,
    required String kind,
    required String modified,
    Widget? nameCell,
    Widget? pathCell,
    Widget? kindCell,
    Widget? modifiedCell,
    Widget? leading,
    TextStyle? style,
  }) => Row(
    children: [
      if (leading != null) leading,
      Expanded(
        flex: wide ? 4 : 3,
        child: nameCell ?? Text(name, style: style),
      ),
      if (wide)
        Expanded(
          flex: 6,
          child: pathCell ?? Text(path, style: style),
        ),
      SizedBox(
        width: wide ? 110 : 90,
        child: kindCell ?? Text(kind, style: style),
      ),
      SizedBox(
        width: wide ? 130 : 96,
        child: modifiedCell ?? Text(modified, style: style),
      ),
    ],
  );

  Widget _emptyState() => PageContent(
    maxWidth: 1180,
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.folder_open_outlined,
              size: 40,
              color: AppColors.textSecondary,
            ),
            const SizedBox(height: 12),
            Text(
              context.strings.noProjectsYet,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              _tr(
                '新建工程、克隆仓库，或导入已有文件夹。',
                'Create a project, clone a repository, or import an existing folder.',
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: widget.busy ? null : widget.onCreateProject,
                  icon: const Icon(Icons.add, size: 16),
                  label: Text(t.newProject),
                ),
                OutlinedButton.icon(
                  onPressed: widget.busy ? null : widget.onCloneProject,
                  icon: const Icon(Icons.download_outlined, size: 16),
                  label: Text(context.strings.cloneRepository),
                ),
                TextButton.icon(
                  onPressed: widget.busy ? null : widget.onImportFolder,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                  label: Text('${t.importProject}…'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget _message({
    required IconData icon,
    required String title,
    required String detail,
    List<Widget> actions = const [],
  }) => PageContent(
    maxWidth: 1180,
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.textSecondary),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
                height: 1.5,
              ),
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: actions,
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Future<void> _copy(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_tr('已复制路径', 'Path copied'))),
    );
  }

  Future<void> _reveal(String path) async {
    await NativeFileService.revealInExplorer(path);
  }
}

/// 工程表格的一行：悬停/选中/双击/右键。
class _ProjectRow extends StatefulWidget {
  const _ProjectRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.onSelected,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
    required this.onCopyPath,
    required this.onReveal,
  });

  final ProjectEntry entry;
  final bool selected;
  final VoidCallback onSelected;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onCopyPath;
  final VoidCallback onReveal;

  @override
  State<_ProjectRow> createState() => _ProjectRowState();
}

class _ProjectRowState extends State<_ProjectRow> {
  bool get _zh => Localizations.localeOf(context).languageCode.startsWith('zh');

  String _tr(String zh, String en) => _zh ? zh : en;

  Future<void> _showMenu() async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final rect = box == null || overlay == null
        ? Rect.zero
        : box.localToGlobal(Offset.zero) & box.size;
    final position = RelativeRect.fromRect(
      rect,
      Offset.zero & (overlay?.size ?? const Size(1, 1)),
    );
    final action = await showMenu<String>(
      context: context,
      position: position,
      items: [
        PopupMenuItem(
          value: 'open',
          child: Text(desktopStrings(context).openProject),
        ),
        PopupMenuItem(
          value: 'reveal',
          child: Text(desktopStrings(context).revealInExplorer),
        ),
        PopupMenuItem(
          value: 'copy',
          child: Text(desktopStrings(context).copyPath),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'rename',
          child: Text(desktopStrings(context).rename),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Text(desktopStrings(context).delete),
        ),
      ],
    );
    switch (action) {
      case 'open':
        widget.onOpen();
      case 'reveal':
        widget.onReveal();
      case 'copy':
        widget.onCopyPath();
      case 'rename':
        widget.onRename();
      case 'delete':
        widget.onDelete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final (icon, color) = switch (entry.kind) {
      ProjectKind.flutter => (Icons.flutter_dash, AppColors.accent),
      ProjectKind.dart => (Icons.code, AppColors.textPrimary),
      null => (Icons.folder_outlined, AppColors.textSecondary),
    };
    final kindLabel = switch (entry.kind) {
      ProjectKind.flutter => 'Flutter',
      ProjectKind.dart => 'Dart',
      null => _tr('文件夹', 'Folder'),
    };
    final modified = entry.modified;
    final modifiedLabel = modified == null ? '—' : relativeTime(modified);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        return HoverRow(
          selected: widget.selected,
          padding: EdgeInsets.zero,
          onTap: widget.onSelected,
          onDoubleTap: widget.onOpen,
          onSecondaryTap: _showMenu,
          child: SizedBox(
            height: 38,
            child: Row(
              children: [
                const SizedBox(width: 10),
                SizedBox(
                  width: 20,
                  child: Icon(icon, size: 16, color: color),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: wide ? 4 : 3,
                  child: Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (wide)
                  Expanded(
                    flex: 6,
                    child: Text(
                      entry.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                SizedBox(
                  width: wide ? 110 : 90,
                  child: Text(
                    kindLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                SizedBox(
                  width: wide ? 130 : 96,
                  child: Text(
                    modifiedLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
        );
      },
    );
  }
}