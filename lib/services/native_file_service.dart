import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import '../core/host_platform.dart';
import '../l10n/desktop_strings.dart';
import '../services/desktop_toolchain.dart';
import 'paths.dart';

/// Windows 原生文件选择器与资源管理器入口。
///
/// 全部静态、可 await；非桌面平台返回 null / no-op（Android 继续用应用内的
/// 文件树，不弹原生对话框）。选择器的标题/初始目录都做了防御：目录不存在
/// 时不传，交给系统决定，避免某些平台直接抛异常。
class NativeFileService {
  NativeFileService._();

  /// 选择目录；取消返回 null。
  static Future<String?> pickDirectory({
    String? initialDirectory,
    String? title,
  }) async {
    if (!isDesktopPlatform) return null;
    try {
      return await getDirectoryPath(
        initialDirectory: _existingDirectory(initialDirectory),
        confirmButtonText: title,
      );
    } catch (error) {
      debugPrint('选择目录失败: $error');
      return null;
    }
  }

  /// 选择工程目录：默认从工具链的 projects 目录开始。
  static Future<String?> pickProjectDirectory() => pickDirectory(
    initialDirectory: _projectsRoot(),
    title: desktopStringsFallback.chooseFolder,
  );

  /// 选择单个文件；取消返回 null。
  static Future<String?> pickFile({
    String? initialDirectory,
    List<XTypeGroup>? typeGroups,
  }) async {
    if (!isDesktopPlatform) return null;
    try {
      final file = await openFile(
        acceptedTypeGroups: typeGroups ?? const <XTypeGroup>[],
        initialDirectory: _existingDirectory(initialDirectory),
      );
      return file?.path;
    } catch (error) {
      debugPrint('选择文件失败: $error');
      return null;
    }
  }

  /// 选择保存位置；取消返回 null。
  static Future<String?> pickSavePath({
    required String suggestedName,
    List<XTypeGroup>? typeGroups,
    String? initialDirectory,
  }) async {
    if (!isDesktopPlatform) return null;
    try {
      final location = await getSaveLocation(
        suggestedName: suggestedName,
        acceptedTypeGroups: typeGroups ?? const <XTypeGroup>[],
        initialDirectory: _existingDirectory(initialDirectory),
        confirmButtonText: desktopStringsFallback.saveAs,
      );
      return location?.path;
    } catch (error) {
      debugPrint('选择保存位置失败: $error');
      return null;
    }
  }

  /// 在资源管理器中选中文件/文件夹（Windows 用 `/select,` 参数）。
  static Future<bool> revealInExplorer(String path) async {
    if (!isDesktopPlatform || path.isEmpty) return false;
    try {
      if (Platform.isWindows) {
        // 整体作为一个参数传给 explorer：`/select,"C:\a b\file.txt"`。
        await Process.run('explorer.exe', <String>['/select,"$path"']);
      } else if (Platform.isMacOS) {
        await Process.run('open', <String>['-R', path]);
      } else {
        await Process.run('xdg-open', <String>[dirName(path)]);
      }
      return true;
    } catch (error) {
      debugPrint('显示文件位置失败: $error');
      return false;
    }
  }

  /// 打开文件夹（资源管理器）。
  static Future<bool> openFolder(String path) async {
    if (!isDesktopPlatform || path.isEmpty) return false;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', <String>[path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', <String>[path]);
      } else {
        await Process.run('xdg-open', <String>[path]);
      }
      return true;
    } catch (error) {
      debugPrint('打开文件夹失败: $error');
      return false;
    }
  }

  /// 用系统默认关联程序打开文件。
  ///
  /// Windows 必须经 `cmd /c start "" "<path>"`：第一个引号参数是窗口标题，
  /// 否则带空格的路径会被 start 当成标题吞掉。参数以列表传入，由系统负责
  /// 引用，不拼命令字符串。
  static Future<bool> openFileWithDefaultApp(String path) async {
    if (!isDesktopPlatform || path.isEmpty) return false;
    try {
      if (Platform.isWindows) {
        await Process.run('cmd.exe', <String>['/c', 'start', '', path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', <String>[path]);
      } else {
        await Process.run('xdg-open', <String>[path]);
      }
      return true;
    } catch (error) {
      debugPrint('用默认程序打开失败: $error');
      return false;
    }
  }

  static String? _existingDirectory(String? path) {
    if (path == null || path.isEmpty) return null;
    try {
      return Directory(path).existsSync() ? path : null;
    } catch (_) {
      return null;
    }
  }

  static String? _projectsRoot() {
    try {
      return _existingDirectory(DesktopToolchain.instance.projectsDir);
    } catch (_) {
      return null;
    }
  }
}