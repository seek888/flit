import 'package:flit/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/desktop/hover.dart';
import '../../../core/theme.dart';
import '../../../l10n/desktop_strings.dart';
import '../../workspace/editor_tabs.dart';
import '../../workspace/project_documents.dart';
import '../file_kind.dart';
import 'desktop_context_menu.dart';
import 'file_dialogs.dart';

/// 打开项 tab 条。手机是 36 高、✕ 只在当前项、长按给关闭/关闭其他；
/// 桌面是 32 高、悬停即出 ✕、中键直接关、右键菜单给关闭/关闭其他/关闭全部，
/// 脏标记用圆点，同名文件带上一级目录区分。
class EditorFileTabs extends StatefulWidget {
  const EditorFileTabs({
    super.key,
    required this.onSelect,
    required this.onClose,
    required this.onCloseOthers,
    this.onCloseAll,
    this.trailing,
    this.desktop = false,
  });

  final void Function(OpenItem item) onSelect;
  final void Function(OpenItem item) onClose;
  final void Function(OpenItem item) onCloseOthers;
  final VoidCallback? onCloseAll;
  final Widget? trailing;

  /// 桌面标签行形态（32 高、悬停关闭、右键菜单、中键关闭）
  final bool desktop;

  static const height = 36.0;
  static const desktopHeight = 32.0;

  @override
  State<EditorFileTabs> createState() => _EditorFileTabsState();
}

class _EditorFileTabsState extends State<EditorFileTabs> {
  late final EditorTabs tabs = context.read<EditorTabs>();
  late final ProjectDocuments documents = context.read<ProjectDocuments>();
  final _selectedKey = GlobalKey();
  OpenItem? _revealed;

  /// 当前项变了就滚进可视区(切 tab/新开文件都在末尾或屏外)
  void _revealSelected() {
    final current = tabs.current;
    if (current == null || identical(_revealed, current)) return;
    _revealed = current;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _selectedKey.currentContext;
      if (context != null && mounted) {
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: const Duration(milliseconds: 150),
        );
      }
    });
  }

  Map<OpenItem, String> _labels(List<OpenItem> items) {
    final counts = <String, int>{};
    for (final item in items) {
      counts[item.name] = (counts[item.name] ?? 0) + 1;
    }
    return {
      for (final item in items)
        item: (counts[item.name] ?? 0) > 1 ? _withParent(item.path) : item.name,
    };
  }

  static String _withParent(String path) {
    final parts = path.split('/');
    return parts.length < 2 ? path : '${parts[parts.length - 2]}/${parts.last}';
  }

  /// 桌面右键菜单: 关闭 / 关闭其他 / 关闭全部（长按给手机保留原底部弹层）。
  Future<void> _showTabMenu(
    BuildContext context,
    OpenItem item,
    Offset position,
  ) {
    final t = desktopStrings(context);
    return showDesktopContextMenu(context, position, [
      (
        icon: Icons.close,
        label: t.closeTab,
        onTap: () => widget.onClose(item),
      ),
      (
        icon: Icons.clear_all,
        label: t.closeOtherTabs,
        onTap: () => widget.onCloseOthers(item),
      ),
      (
        icon: Icons.close_fullscreen,
        label: t.closeAllTabs,
        onTap: widget.onCloseAll,
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([tabs, documents]),
    builder: (context, _) {
      final items = tabs.items;
      final labels = _labels(items);
      _revealSelected();
      final height = widget.desktop
          ? EditorFileTabs.desktopHeight
          : EditorFileTabs.height;
      return ExcludeFocus(
        child: Material(
          color: AppColors.surface,
          child: SizedBox(
            width: double.infinity,
            height: height,
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    child: Row(
                      children: [
                        for (final item in items)
                          _chip(context, item, labels[item]!),
                      ],
                    ),
                  ),
                ),
                if (widget.trailing != null) widget.trailing!,
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _chip(BuildContext context, OpenItem item, String label) {
    final selected = identical(tabs.current, item);
    final dirty = item is CodeTab && item.document.dirty;
    final color = selected ? AppColors.accent : AppColors.textSecondary;
    final icon = switch (item) {
      FileTab(kind: FileKind.image) => Icons.image_outlined,
      FileTab() => Icons.insert_drive_file_outlined,
      CodeTab() => null,
    };
    final chipHeight = widget.desktop ? 26.0 : 30.0;
    final closeSize = widget.desktop ? 20.0 : 22.0;
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      enabled: widget.desktop,
      builder: (context, hovering) {
        final showClose = selected || (widget.desktop && hovering);
        return GestureDetector(
          // 中键关闭: 桌面鼠标习惯, 手机没有该按钮。
          onTertiaryTapUp: widget.desktop ? (_) => widget.onClose(item) : null,
          child: Padding(
            key: selected ? _selectedKey : null,
            padding: const EdgeInsets.only(right: 4),
            child: Material(
              color: selected
                  ? AppColors.accent.withValues(alpha: .12)
                  : hovering && widget.desktop
                  ? AppColors.hover
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    canRequestFocus: false,
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => widget.onSelect(item),
                    // 右键菜单只给桌面; 长按留给手机原交互
                    onSecondaryTapDown: widget.desktop
                        ? (details) => _showTabMenu(
                            context,
                            item,
                            details.globalPosition,
                          )
                        : null,
                    onLongPress: widget.desktop
                        ? null
                        : () => showActionMenu(context, [
                            (
                              'close',
                              Icons.close,
                              context.strings.close,
                              () => widget.onClose(item),
                            ),
                            (
                              'others',
                              Icons.clear_all,
                              context.strings.closeOthers,
                              () => widget.onCloseOthers(item),
                            ),
                          ]),
                    child: Container(
                      height: chipHeight,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (icon != null) ...[
                            Icon(icon, size: 12, color: color),
                            const SizedBox(width: 4),
                          ],
                          Text(
                            label,
                            style: TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: color,
                            ),
                          ),
                          if (!showClose && dirty) ...[
                            const SizedBox(width: 5),
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: AppColors.accent,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (showClose)
                    Tooltip(
                      message: context.strings.closeP(label),
                      waitDuration: const Duration(milliseconds: 400),
                      child: InkWell(
                        canRequestFocus: false,
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => widget.onClose(item),
                        child: SizedBox(
                          width: closeSize,
                          height: chipHeight,
                          child: Icon(Icons.close, size: 13, color: color),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}