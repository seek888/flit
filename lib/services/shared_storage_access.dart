import 'package:flit/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/host_platform.dart';

/// Shared permission flow for the project location picker and the editor's
/// import browser. Declining it never blocks app-private project work.
class SharedStorageAccess {
  SharedStorageAccess._();

  static Future<bool> isGranted() async {
    // 桌面端没有 Android 的共享存储沙箱：应用本来就能读写用户文件，
    // 不碰 permission_handler（Windows 恒 GRANTED，显示授权流程没有意义）。
    if (isDesktopPlatform) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    return Permission.storage.isGranted;
  }

  static Future<bool> requestPermission() async {
    if (isDesktopPlatform) return true;
    if (await isGranted()) return true;
    await Permission.manageExternalStorage.request();
    if (await isGranted()) return true;
    await Permission.storage.request();
    return isGranted();
  }

  static Future<bool> request(
    BuildContext context, {
    required String purpose,
  }) async {
    if (isDesktopPlatform) return true;
    if (await isGranted()) return true;
    if (!context.mounted) return false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.allowSharedStorageAccess),
        content: Text(
          '$purpose\n\n${strings.withPermissionFlitCanAccessSharedStorage}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.notNow),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.grantAccess),
          ),
        ],
      ),
    );
    if (accepted != true || !context.mounted) return false;

    final granted = await requestPermission();
    if (!context.mounted) return false;
    if (!granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            strings.sharedStoragePermissionDeniedAppPrivateProjects,
          ),
        ),
      );
    }
    return granted;
  }
}
