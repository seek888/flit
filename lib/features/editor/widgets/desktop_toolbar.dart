import 'package:flutter/material.dart';

import '../../../core/desktop/app_commands.dart';
import '../../../core/theme.dart';
import '../../../core/workbench_controls.dart';
import '../../../l10n/desktop_strings.dart';

/// 桌面工作台顶栏（44px）：侧栏开关 + 工程名 13px + 分支/保存状态细字 +
/// 右侧任务操作组（沿用 [EditorRunControls]）。
class DesktopToolbar extends StatelessWidget {
  const DesktopToolbar({
    super.key,
    required this.projectName,
    required this.subtitle,
    required this.sidebarVisible,
    required this.onToggleSidebar,
    required this.runControls,
    this.saveFailed = false,
  });

  final String projectName;

  /// 形如 `main · 已保存` 的细字；空串不占位。
  final String subtitle;
  final bool sidebarVisible;
  final VoidCallback onToggleSidebar;
  final Widget runControls;
  final bool saveFailed;

  @override
  Widget build(BuildContext context) {
    final t = desktopStrings(context);
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          WorkbenchButton(
            icon: Icons.vertical_split_outlined,
            tooltip: '${t.fileTree} · ${shortcutLabel(AppCommand.toggleSidebar)}',
            active: sidebarVisible,
            onPressed: onToggleSidebar,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Tooltip(
                    message: projectName,
                    waitDuration: const Duration(milliseconds: 400),
                    child: Text(
                      projectName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: saveFailed
                            ? AppColors.danger
                            : AppColors.textFaint,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          runControls,
        ],
      ),
    );
  }
}