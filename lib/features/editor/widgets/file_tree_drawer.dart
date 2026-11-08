import 'package:flit/l10n/strings.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme.dart';
import '../../../l10n/desktop_strings.dart';
import '../../../services/native_file_service.dart';
import 'file_dialogs.dart';
import '../../../services/file_ops.dart';
import '../../../services/paths.dart';
import '../../../services/shared_storage_access.dart';
import '../../../services/shell.dart';
import '../../workspace/editor_tabs.dart';
import '../../workspace/project_files.dart';
import '../../workspace/project_session.dart';

/// 抽屉位置模式
enum _Loc { project, storage }

/// 文件树节点(由 find 扁平列表构建)
class _Node {
  _Node(this.name, this.path, this.isDir);
  final String name;
  final String path; // 相对项目根
  final bool isDir;
  final List<_Node> children = [];
}

/// Project tree with bounded mutations; shared storage is a read-only import
/// browser. Toolchains and app internals are not exposed as editable projects.
class FileTreeDrawer extends StatefulWidget {
  const FileTreeDrawer({
    super.key,
    required this.onOpenFile,
    this.asContent = false,
  });

  final ValueChanged<String> onOpenFile;
  final bool asContent; // true = 只出内容(嵌 drawer 的 tab), 不包 Drawer 壳

  @override
  State<FileTreeDrawer> createState() => _FileTreeDrawerState();
}

class _FileTreeDrawerState extends State<FileTreeDrawer> {
  final Set<String> _expanded = {};
  _Loc _loc = _Loc.project;

  // 共享存储/磁盘导入浏览器
  String _browseDir = '';
  List<FileSystemEntity> _entries = [];
  bool _browseLoading = false;
  int _browseRequest = 0;

  FileOps get _ops => FileOps.instance;

  /// 工程、文件清单与打开项都来自 ProjectScope
  late final ProjectSession _project = context.read<ProjectSession>();
  late final ProjectFiles _projectFiles = context.read<ProjectFiles>();
  List<String> get _files => _projectFiles.files;

  /// 当前打开项的相对路径(文件树据此高亮); 变了就展开它的祖先目录
  String? _openFile;

  @override
  void initState() {
    super.initState();
    _openFile = context.read<EditorTabs>().current?.path;
    _expandAncestorsOf(_openFile);
  }

  // ---------- 项目树(逻辑不变) ----------

  void _expandAncestorsOf(String? rel) {
    if (rel == null) return;
    final parts = rel.split('/')..removeLast();
    var acc = '';
    for (final p in parts) {
      acc = acc.isEmpty ? p : '$acc/$p';
      _expanded.add(acc);
    }
  }

  _Node _buildTree() {
    final root = _Node('', '', true);
    for (final rel in _files) {
      final directory = rel.endsWith('/');
      final parts = rel.split('/').where((part) => part.isNotEmpty).toList();
      _Node cur = root;
      var acc = '';
      for (var i = 0; i < parts.length; i++) {
        acc = acc.isEmpty ? parts[i] : '$acc/${parts[i]}';
        final isDir = i < parts.length - 1 || directory;
        _Node? next;
        for (final c in cur.children) {
          if (c.name == parts[i] && c.isDir == isDir) {
            next = c;
            break;
          }
        }
        if (next == null) {
          next = _Node(parts[i], acc, isDir);
          cur.children.add(next);
        }
        cur = next;
      }
    }
    void sort(_Node n) {
      n.children.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      for (final c in n.children) {
        sort(c);
      }
    }

    sort(root);
    return root;
  }

  List<(_Node, int)> _visible(_Node root) {
    final out = <(_Node, int)>[];
    void walk(_Node n, int depth) {
      for (final c in n.children) {
        out.add((c, depth));
        if (c.isDir && _expanded.contains(c.path)) walk(c, depth + 1);
      }
    }

    walk(root, 0);
    return out;
  }

  void _toggle(_Node n) {
    setState(() {
      if (_expanded.contains(n.path)) {
        _expanded.remove(n.path);
      } else {
        _expanded.add(n.path);
      }
    });
  }

  // ---------- 位置切换 + 浏览器 ----------

  /// 「共享存储」页签的浏览根。
  /// Android 是 SAF 共享存储；桌面端没有这个概念，直接浏览用户主目录
  /// （Windows: %USERPROFILE%，Linux/macOS: $HOME）。
  String get _storageRoot {
    if (isDesktopPlatform) {
      final env = Platform.environment;
      return env['USERPROFILE'] ?? env['HOME'] ?? Directory.current.path;
    }
    return '/storage/emulated/0';
  }

  Future<void> _switchLoc(_Loc loc) async {
    if (loc == _Loc.project) {
      ++_browseRequest;
      setState(() => _loc = loc);
      return;
    }
    if (isDesktopPlatform) {
      // permission_handler 在 Windows 上恒 GRANTED，权限门禁没有意义；
      // 也不该把 /storage/emulated/0 这种 Android 路径丢给 Directory.list。
      setState(() {
        _loc = loc;
        _browseDir = _storageRoot;
      });
      await _reloadEntries();
      return;
    }
    final granted = await SharedStorageAccess.request(
      context,
      purpose: context.strings.browseSharedStorageAndSelectFilesTo,
    );
    if (!mounted || !granted) return;
    setState(() {
      _loc = loc;
      _browseDir = _storageRoot;
    });
    await _reloadEntries();
  }

  Future<void> _reloadEntries() async {
    final request = ++_browseRequest;
    final path = _browseDir;
    final dir = Directory(path);
    setState(() => _browseLoading = true);
    try {
      final list = await dir.list().toList();
      list.sort((a, b) {
        final aDir = a is Directory;
        final bDir = b is Directory;
        if (aDir != bDir) return aDir ? -1 : 1;
        return baseName(
          a.path,
        ).toLowerCase().compareTo(baseName(b.path).toLowerCase());
      });
      if (!mounted || request != _browseRequest) return;
      setState(() {
        _entries = list;
        _browseLoading = false;
      });
    } catch (e) {
      if (!mounted || request != _browseRequest) return;
      setState(() => _browseLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.strings.unableToReadDirectoryP(e))),
      );
    }
  }

  void _descend(Directory d) {
    setState(() => _browseDir = d.path);
    _reloadEntries();
  }

  void _ascend() {
    if (_browseDir == _storageRoot) return;
    final parent = dirName(_browseDir);
    if (parent.isEmpty || parent == _browseDir) return;
    setState(() => _browseDir = parent);
    _reloadEntries();
  }

  // ---------- 文件操作 ----------

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _runOp(Future<void> Function() operation) async {
    try {
      await operation();
      if (!mounted) return;
      await _projectFiles.refresh();
      _snack(strings.done);
      if (mounted) setState(() {});
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _pasteInto(String dir) => _runOp(() => _projectFiles.paste(dir));

  Future<void> _confirmDelete(String abs, String name) async {
    if (!await confirmDeleteDialog(context, name) || !mounted) return;
    await _runOp(() => _projectFiles.delete(abs));
  }

  Future<void> _renameDialog(String abs, String oldName) async {
    final name = await renameDialog(context, oldName);
    if (!mounted || name == null || name.isEmpty || name == oldName) return;
    await _runOp(() => _projectFiles.rename(abs, name));
  }

  Future<void> _createDialog(String parent, {required bool dir}) async {
    final name = await createDialog(context, dir: dir);
    if (!mounted || name == null || name.isEmpty) return;
    await _runOp(() => _projectFiles.create(parent, name, directory: dir));
  }

  /// 项目树节点 → 绝对路径
  String _abs(_Node n) => joinPath(_project.path, n.path);

  void _nodeMenu(_Node n, {Offset? position}) {
    final abs = _abs(n);
    showActionMenu(context, [
      if (isDesktopPlatform)
        (
          'reveal',
          Icons.folder_open_outlined,
          desktopStrings(context).revealInExplorer,
          () => NativeFileService.revealInExplorer(abs),
        ),
      if (n.isDir && _ops.hasClip)
        (
          'paste',
          Icons.content_paste,
          context.strings.pasteHere,
          () => _pasteInto(abs),
        ),
      if (n.isDir)
        (
          'newfile',
          Icons.post_add,
          context.strings.newFile,
          () => _createDialog(abs, dir: false),
        ),
      if (n.isDir)
        (
          'newdir',
          Icons.create_new_folder,
          context.strings.newDirectory,
          () => _createDialog(abs, dir: true),
        ),
      (
        'copy',
        Icons.copy_all_outlined,
        context.strings.copy,
        () {
          _ops.clipPath = abs;
          _ops.clipRoot = _project.path;
          _ops.clipCut = false;
          setState(() {});
          _snack(
            context.strings.copiedPLongPressTheDestinationDirectory(n.name),
          );
        },
      ),
      (
        'cut',
        Icons.content_cut,
        context.strings.cut,
        () {
          _ops.clipPath = abs;
          _ops.clipRoot = _project.path;
          _ops.clipCut = true;
          setState(() {});
          _snack(context.strings.cutPLongPressTheDestinationDirectory(n.name));
        },
      ),
      (
        'rename',
        Icons.drive_file_rename_outline,
        context.strings.rename,
        () => _renameDialog(abs, n.name),
      ),
      (
        'delete',
        Icons.delete_outline,
        context.strings.delete,
        () => _confirmDelete(abs, n.name),
      ),
    ]);
  }

  void _browseMenu(FileSystemEntity e) {
    final name = baseName(e.path);
    showActionMenu(context, [
      (
        'copy',
        Icons.copy_all_outlined,
        context.strings.copy,
        () {
          _ops.clipPath = e.path;
          _ops.clipRoot = null;
          _ops.clipCut = false;
          setState(() {});
          _snack(context.strings.copiedPReturnToTheProjectAnd(name));
        },
      ),
    ]);
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    context.watch<ProjectFiles>();
    final open = context.watch<EditorTabs>().current?.path;
    if (open != _openFile) {
      _openFile = open;
      _expandAncestorsOf(open);
    }
    final tree = _buildTree();
    final rows = _visible(tree);

    final content = SafeArea(
      child: Column(
        children: [
          _header(),
          if (_ops.hasClip) _clipBar(),
          Expanded(
            child: _loc == _Loc.project
                ? ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (_, i) {
                      final (n, depth) = rows[i];
                      return n.isDir ? _dirRow(n, depth) : _fileRow(n, depth);
                    },
                  )
                : _browserList(),
          ),
        ],
      ),
    );
    // 作为 drawer 的 tab 内容时只出内容, 不包 Drawer 壳
    return widget.asContent
        ? content
        : Drawer(backgroundColor: AppColors.bg, child: content);
  }

  Widget _header() {
    final label = switch (_loc) {
      _Loc.project => context.strings.project,
      _Loc.storage => context.strings.sharedStorageImportOnly,
    };
    final browseName = baseName(_browseDir);
    final title = _loc == _Loc.project
        ? _project.name
        : (browseName.isEmpty ? _browseDir : browseName);
    return ListTile(
      dense: true,
      leading: Icon(
        _loc == _Loc.project ? Icons.folder : Icons.folder_shared,
        color: AppColors.accent,
      ),
      title: Text(
        title,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      ),
      subtitle: Text(
        label,
        style: const TextStyle(fontSize: 10, color: Colors.grey),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_loc == _Loc.project)
            PopupMenuButton<bool>(
              tooltip: context.strings.newItem,
              icon: const Icon(Icons.add, size: 18),
              onSelected: (dir) => _createDialog(_project.path, dir: dir),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: false,
                  child: Text(context.strings.newFile),
                ),
                PopupMenuItem(
                  value: true,
                  child: Text(context.strings.newDirectory),
                ),
              ],
            ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: _loc == _Loc.project
                ? () async {
                    try {
                      await _projectFiles.refresh();
                    } catch (error) {
                      _snack('$error');
                    }
                  }
                : _reloadEntries,
          ),
          if (!isDesktopPlatform)
            PopupMenuButton<_Loc>(
              tooltip: context.strings.switchLocation,
              icon: const Icon(Icons.drive_file_move_outline, size: 18),
              onSelected: _switchLoc,
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: _Loc.project,
                  child: Text(context.strings.project),
                ),
                PopupMenuItem(
                  value: _Loc.storage,
                  child: Text(context.strings.copyFromSharedStorage),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// 剪贴板条: 快捷粘贴到项目根目录 + 取消
  Widget _clipBar() {
    final ops = _ops;
    final target = _loc == _Loc.project ? _project.path : null;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            ops.clipCut ? Icons.content_cut : Icons.copy_all_outlined,
            size: 14,
            color: AppColors.accent,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${ops.clipCut ? context.strings.cut : context.strings.copy}：${ops.clipName}',
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (target != null)
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () => _pasteInto(target),
              child: Text(
                context.strings.paste,
                style: TextStyle(fontSize: 12),
              ),
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 14),
            onPressed: () => setState(ops.clearClip),
          ),
        ],
      ),
    );
  }

  // ---------- 浏览器列表 ----------

  Widget _browserList() {
    return Column(
      children: [
        InkWell(
          onTap: _browseDir == _storageRoot ? null : _ascend,
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            width: double.infinity,
            child: Row(
              children: [
                const Icon(
                  Icons.arrow_upward,
                  size: 14,
                  color: AppColors.textFaint,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _browseDir,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: AppColors.textFaint,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: Color(0xFF21262D)),
        Expanded(
          child: _browseLoading
              ? const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : ListView.builder(
                  itemCount: _entries.length,
                  itemBuilder: (_, i) {
                    final e = _entries[i];
                    final isDir = e is Directory;
                    final name = baseName(e.path);
                    if (name.startsWith('.')) return const SizedBox.shrink();
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: Icon(
                        isDir ? Icons.folder : Icons.description_outlined,
                        size: 16,
                        color: isDir ? AppColors.accent : Colors.grey,
                      ),
                      title: Text(
                        name,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: AppColors.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: isDir ? () => _descend(e) : () {},
                      onLongPress: () => _browseMenu(e),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ---------- 项目树行 ----------

  Widget _dirRow(_Node n, int depth) {
    final open = _expanded.contains(n.path);
    return InkWell(
      onTap: () => _toggle(n),
      onLongPress: () => _nodeMenu(n),
      onSecondaryTapDown: (details) =>
          _nodeMenu(n, position: details.globalPosition),
      hoverColor: AppColors.hover,
      child: Container(
        height: isDesktopPlatform ? 26 : 34,
        padding: EdgeInsets.fromLTRB(10.0 + depth * 14.0, 0, 8, 0),
        child: Row(
          children: [
            AnimatedRotation(
              turns: open ? 0.25 : 0,
              duration: const Duration(milliseconds: 150),
              child: const Icon(
                Icons.chevron_right,
                size: 14,
                color: AppColors.textFaint,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              open ? Icons.folder_open : Icons.folder,
              size: 15,
              color: AppColors.accent,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                n.name,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: AppColors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fileRow(_Node n, int depth) {
    final selected = n.path == _openFile;
    return InkWell(
      onTap: () => widget.onOpenFile(n.path),
      onLongPress: () => _nodeMenu(n),
      onSecondaryTapDown: (details) =>
          _nodeMenu(n, position: details.globalPosition),
      hoverColor: AppColors.hover,
      child: Container(
        height: isDesktopPlatform ? 26 : 34,
        padding: EdgeInsets.fromLTRB(26.0 + depth * 14.0, 0, 8, 0),
        color: selected ? AppColors.accent.withValues(alpha: 0.15) : null,
        child: Row(
          children: [
            Icon(_iconFor(n.path), size: 15, color: _colorFor(n.path)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                n.name,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: selected ? AppColors.accent : AppColors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String path) {
    if (path.endsWith('.dart')) return Icons.flutter_dash;
    if (path.endsWith('.yaml') || path.endsWith('.lock')) {
      return Icons.settings;
    }
    if (path.endsWith('.png') ||
        path.endsWith('.jpg') ||
        path.endsWith('.webp')) {
      return Icons.image;
    }
    return Icons.description_outlined;
  }

  Color _colorFor(String path) {
    if (path.endsWith('.dart')) return AppColors.accent;
    if (path.endsWith('.yaml') || path.endsWith('.lock')) return AppColors.warn;
    return Colors.grey;
  }
}
