import 'package:flutter/material.dart';

import '../../../core/desktop/hover.dart';
import '../../../core/theme.dart';
import '../../../l10n/desktop_strings.dart';
import '../../../l10n/strings.dart';

/// 左侧永久侧栏的两个页签。
enum DesktopSidebarTab { files, versionControl }

/// 桌面左侧栏：文件 / 版本控制两个页签 + 底部「设置」「关闭工程」，
/// 右缘可拖拽调宽（宽度由页面状态持有，220–420）。
///
/// 只负责摆放：文件树与 Git 面板仍是原来的组件（docked / 窄栏形态各自内部处理），
/// 侧栏保证给足宽度、内容用 [Expanded] 承载，不产生 overflow。
class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({
    super.key,
    required this.width,
    required this.tab,
    required this.onTabChanged,
    required this.onResize,
    required this.files,
    required this.versionControl,
    required this.onSettings,
    required this.onCloseProject,
  });

  final double width;
  final DesktopSidebarTab tab;
  final ValueChanged<DesktopSidebarTab> onTabChanged;

  /// 拖拽产生的宽度增量（px）；由页面夹在 220–420 后写回布局态。
  final ValueChanged<double> onResize;
  final Widget files;
  final Widget versionControl;
  final VoidCallback onSettings;
  final VoidCallback onCloseProject;

  @override
  Widget build(BuildContext context) {
    final t = desktopStrings(context);
    return SizedBox(
      width: width,
      child: Row(
        children: [
          Expanded(
            child: Container(
              color: AppColors.bg,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _tabs(context),
                  const Divider(height: 1, color: AppColors.border),
                  Expanded(
                    child: IndexedStack(
                      index: tab.index,
                      children: [files, versionControl],
                    ),
                  ),
                  const Divider(height: 1, color: AppColors.border),
                  _bottomAction(
                    context,
                    icon: Icons.settings_outlined,
                    label: t.settings,
                    onTap: onSettings,
                  ),
                  _bottomAction(
                    context,
                    icon: Icons.logout,
                    label: context.strings.closeProject,
                    onTap: onCloseProject,
                  ),
                  const SizedBox(height: 4),
                ],
              ),
            ),
          ),
          _resizeHandle(),
        ],
      ),
    );
  }

  Widget _tabs(BuildContext context) => SizedBox(
    height: 30,
    child: Row(
      children: [
        Expanded(
          child: _tabItem(context, desktopStrings(context).fileTree, DesktopSidebarTab.files),
        ),
        Expanded(
          child: _tabItem(
            context,
            context.strings.versionControl,
            DesktopSidebarTab.versionControl,
          ),
        ),
      ],
    ),
  );

  Widget _tabItem(
    BuildContext context,
    String label,
    DesktopSidebarTab value,
  ) {
    final selected = tab == value;
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovering) => InkWell(
        onTap: () => onTabChanged(value),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? AppColors.surface
                : hovering
                ? AppColors.hover
                : Colors.transparent,
            border: Border(
              bottom: BorderSide(
                color: selected ? AppColors.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomAction(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) => HoverRow(
    onTap: onTap,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Row(
      children: [
        Icon(icon, size: 15, color: AppColors.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    ),
  );

  /// 右缘拖拽条：悬停高亮、左右箭头光标，5px 宽但不挡内容点击。
  Widget _resizeHandle() => HoverBuilder(
    cursor: SystemMouseCursors.resizeLeftRight,
    builder: (context, hovering) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) => onResize(details.delta.dx),
      child: Container(
        width: 5,
        color: hovering ? AppColors.hoverStrong : AppColors.border,
      ),
    ),
  );
}