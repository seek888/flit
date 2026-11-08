import 'package:flutter/material.dart';

import '../../../core/theme.dart';

/// 桌面右键菜单项：图标、文案与动作（[onTap] 为 null 表示禁用项）。
typedef DesktopMenuEntry = ({IconData icon, String label, VoidCallback? onTap});

/// 在鼠标位置弹出桌面上下文菜单。
///
/// 桌面端用 [showMenu]：菜单出现在指针处、Esc 关闭、可用键盘上下走；Android
/// 没有右键，调用点仍走 [showActionMenu] 的底部弹层。
Future<void> showDesktopContextMenu(
  BuildContext context,
  Offset globalPosition,
  List<DesktopMenuEntry> entries,
) async {
  if (entries.isEmpty) return;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  final size = MediaQuery.sizeOf(context);
  final local = overlay != null && overlay.hasSize
      ? overlay.globalToLocal(globalPosition)
      : globalPosition;
  final selected = await showMenu<int>(
    context: context,
    position: RelativeRect.fromLTRB(
      local.dx,
      local.dy,
      size.width - local.dx,
      size.height - local.dy,
    ),
    color: AppColors.surface,
    elevation: 8,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(6),
      side: const BorderSide(color: AppColors.border),
    ),
    items: [
      for (var i = 0; i < entries.length; i++)
        PopupMenuItem<int>(
          value: i,
          enabled: entries[i].onTap != null,
          height: 30,
          child: Row(
            children: [
              Icon(entries[i].icon, size: 15, color: AppColors.textSecondary),
              const SizedBox(width: 8),
              Text(entries[i].label, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
    ],
  );
  if (selected == null) return;
  entries[selected].onTap?.call();
}