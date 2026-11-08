import 'package:flit/l10n/strings.dart';
import 'package:flutter/material.dart';

import '../../../core/desktop/desktop_presentation.dart';
import '../../../core/theme.dart';
import '../../../services/shell.dart';

typedef MenuAction = (String, IconData, String, VoidCallback);

/// 文件管理通用操作菜单。
///
/// 桌面端是真正的弹出菜单（右键位置优先，否则落在指针附近），手机端保持底部
/// 操作面板——两者共用同一份 [MenuAction] 列表。
Future<void> showActionMenu(
  BuildContext context,
  List<MenuAction> items, {
  Offset? position,
}) async {
  if (items.isEmpty) return;
  if (!isDesktopPlatform) {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetHandle(),
            for (final (_, icon, label, onTap) in items)
              ListTile(
                dense: true,
                leading: Icon(icon, size: 18, color: AppColors.textSecondary),
                title: Text(label, style: const TextStyle(fontSize: 13)),
                onTap: () {
                  Navigator.pop(ctx);
                  onTap();
                },
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    return;
  }
  final screen = MediaQuery.sizeOf(context);
  final origin = position ?? Offset(screen.width / 2 - 120, screen.height / 3);
  final selected = await showMenu<int>(
    context: context,
    color: AppColors.surface,
    position: RelativeRect.fromLTRB(
      origin.dx,
      origin.dy,
      screen.width - origin.dx,
      screen.height - origin.dy,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(6)),
      side: BorderSide(color: AppColors.border),
    ),
    items: [
      for (var index = 0; index < items.length; index++)
        PopupMenuItem<int>(
          value: index,
          height: 32,
          child: Row(
            children: [
              Icon(
                items[index].$2,
                size: 16,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 10),
              Text(items[index].$3, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
    ],
  );
  if (selected != null) items[selected].$4();
}

/// 删除确认（不可恢复）。
Future<bool> confirmDeleteDialog(BuildContext context, String name) async {
  if (isDesktopPlatform) {
    return showConfirmDialog(
      context: context,
      title: context.strings.deleteP576(name),
      message: context.strings.permanentlyDeleteTheSelectedFileOrDirectory,
      confirmLabel: context.strings.delete,
      destructive: true,
    );
  }
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(
        context.strings.deleteP576(name),
        style: const TextStyle(fontSize: 16),
      ),
      content: Text(
        context.strings.permanentlyDeleteTheSelectedFileOrDirectory,
        style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(context.strings.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          child: Text(context.strings.delete),
        ),
      ],
    ),
  );
  return yes ?? false;
}

/// 重命名输入框；返回 null = 取消。
Future<String?> renameDialog(BuildContext context, String oldName) async {
  if (isDesktopPlatform) {
    return showPromptDialog(
      context: context,
      title: context.strings.rename,
      initialValue: oldName,
      hintText: context.strings.name,
      validator: (value) =>
          (value ?? '').trim().isEmpty ? context.strings.name : null,
    );
  }
  final ctrl = TextEditingController(text: oldName);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(context.strings.rename, style: const TextStyle(fontSize: 16)),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: InputDecoration(hintText: context.strings.name),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(context.strings.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: Text(context.strings.rename),
        ),
      ],
    ),
  );
  ctrl.dispose();
  return result;
}

/// 新建文件/文件夹输入框；返回 null = 取消。
Future<String?> createDialog(BuildContext context, {required bool dir}) async {
  final hint = dir ? 'widgets' : 'utils.dart';
  if (isDesktopPlatform) {
    return showPromptDialog(
      context: context,
      title: dir ? context.strings.newDirectory : context.strings.newFile,
      hintText: hint,
      validator: (value) =>
          (value ?? '').trim().isEmpty ? hint : null,
    );
  }
  final ctrl = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(
        dir ? context.strings.newDirectory : context.strings.newFile,
        style: const TextStyle(fontSize: 16),
      ),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(context.strings.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: Text(context.strings.create),
        ),
      ],
    ),
  );
  ctrl.dispose();
  return result;
}