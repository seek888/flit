import 'package:flit/l10n/strings.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flit_files/flit_files.dart';

import '../../../core/theme.dart';
import '../../../services/adb_ops.dart';
import '../../../services/desktop_toolchain.dart';
import '../../../services/paths.dart';
import '../../../services/shell.dart';
import '../file_kind.dart';

/// 非文本文件的 tab 内容: 图片给预览, 其余给一张文件卡——图标、名字、路径、
/// 大小/时间, 以及动作清单(file_kind.cardActions 按格式分发, 分享永远在)。
/// 文件系统操作(改名/删除)不在这里, 在文件树的长按菜单。
class FileCard extends StatefulWidget {
  const FileCard({
    super.key,
    required this.projectRoot,
    required this.path,
    required this.kind,
  });

  final String projectRoot;

  /// 相对工程根
  final String path;
  final FileKind kind;

  @override
  State<FileCard> createState() => _FileCardState();
}

class _FileCardState extends State<FileCard> {
  FileStat? _stat;
  int _dirFiles = 0;
  int _dirBytes = 0;

  String get _absolute => joinPath(widget.projectRoot, widget.path);

  /// 动作清单唯一事实源在 file_kind.cardActions; 图标等展示随清单推导
  List<FileCardAction> get _actions => cardActions(widget.path);
  bool get _installable => _actions.contains(FileCardAction.installApk);

  bool get _desktop => isDesktopPlatform;
  bool get _isDirectory => _stat?.type == FileSystemEntityType.directory;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant FileCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _load();
  }

  Future<void> _load() async {
    final stat = await File(_absolute).stat();
    var files = 0;
    var bytes = 0;
    if (stat.type == FileSystemEntityType.directory) {
      // 目录型产物（Web 的 build/web/）：文件数与总大小比 size=0 更有意义。
      try {
        await for (final entity in Directory(
          _absolute,
        ).list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          files++;
          try {
            bytes += await entity.length();
          } catch (_) {}
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _stat = stat;
      _dirFiles = files;
      _dirBytes = bytes;
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<bool> Function() action, String failure) async {
    try {
      if (!await action()) _snack(failure);
    } catch (e) {
      _snack('$e');
    }
  }

  // ---------- 桌面端动作：不碰 flit_files 的 Android SAF/Intent ----------

  /// 打开所在文件夹（目录产物直接打开目录，文件打开父目录）。
  Future<void> _reveal() async {
    final target = _isDirectory ? _absolute : dirName(_absolute);
    final ok = await Shell.instance.revealDirectory(target);
    if (!ok && mounted) _snack('无法打开所在文件夹：$target');
  }

  Future<void> _openExternal() async {
    final index = joinPath(_absolute, 'index.html');
    final target = _isDirectory && File(index).existsSync() ? index : _absolute;
    await _run(
      () => Shell.instance.openUrl(Uri.file(target).toString()),
      '无法用系统应用打开该文件',
    );
  }

  /// 导出到 `%LOCALAPPDATA%\FlitDesk\exports\<项目>\`（与 DesktopToolchain.home 同根）；
  /// 不新增 downloads 概念，也不依赖 file_selector（不引入 pub 依赖）。
  Future<void> _export() async {
    try {
      final exports = joinPath(DesktopToolchain().home, 'exports');
      final projectDir = joinPath(exports, baseName(widget.projectRoot));
      final target = joinPath(projectDir, baseName(widget.path));
      await _copyEntity(FileSystemEntity.typeSync(_absolute), target);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已导出到 $target'),
          action: SnackBarAction(
            label: '打开文件夹',
            onPressed: () => Shell.instance.revealDirectory(dirName(target)),
          ),
        ),
      );
    } catch (e) {
      _snack('导出失败：$e');
    }
  }

  Future<void> _copyEntity(FileSystemEntityType type, String target) async {
    if (type != FileSystemEntityType.directory) {
      await File(target).parent.create(recursive: true);
      await File(_absolute).copy(target);
      return;
    }
    await Directory(target).create(recursive: true);
    await for (final entity in Directory(
      _absolute,
    ).list(recursive: true, followLinks: false)) {
      final relative = relativeInside(_absolute, entity.path);
      if (relative == null || relative.isEmpty) continue;
      final destination = joinPath(target, relative);
      if (entity is Directory) {
        await Directory(destination).create(recursive: true);
      } else if (entity is File) {
        await File(destination).parent.create(recursive: true);
        await entity.copy(destination);
      }
    }
  }

  /// APK 可选：有已连接设备时 `adb install -r`（无设备/无 adb 只提示，不算失败）。
  Future<void> _installToDevice() async {
    try {
      final devices = await AdbOps.devices();
      if (devices.isEmpty) {
        _snack('未连接 Android 设备，请先在设备页连接（USB 或 adb connect）');
        return;
      }
      final toolchain = DesktopToolchain();
      if (!File(toolchain.adbExe).existsSync()) {
        _snack('未找到 adb：请先在开发环境页安装 Android SDK');
        return;
      }
      final result = await Process.run(toolchain.adbExe, [
        'install',
        '-r',
        _absolute,
      ], environment: toolchain.childEnvironment);
      final output = '${result.stdout}${result.stderr}'.trim();
      if (result.exitCode != 0) {
        _snack(
          '安装失败：${output.isEmpty ? 'adb 退出码 ${result.exitCode}' : output}',
        );
      } else {
        _snack('已安装到 ${devices.first.$1}');
      }
    } catch (e) {
      _snack('安装失败：$e');
    }
  }

  /// 桌面动作清单：打开所在文件夹永远是主路径；APK 走 adb 安装，其余用系统应用打开。
  List<Widget> _desktopActions(bool exists) {
    final isApk = _actions.contains(FileCardAction.installApk);
    return [
      OutlinedButton.icon(
        onPressed: !exists ? null : _reveal,
        icon: const Icon(Icons.folder_open_outlined, size: 18),
        label: const Text('打开所在文件夹'),
      ),
      if (isApk)
        FilledButton.icon(
          onPressed: !exists ? null : _installToDevice,
          icon: const Icon(Icons.install_mobile_outlined, size: 18),
          label: const Text('安装到设备'),
        )
      else
        OutlinedButton.icon(
          onPressed: !exists ? null : _openExternal,
          icon: const Icon(Icons.open_in_new, size: 18),
          label: Text(_isDirectory ? '在浏览器中打开' : context.strings.openWith),
        ),
      OutlinedButton.icon(
        onPressed: !exists ? null : _export,
        icon: const Icon(Icons.save_alt_outlined, size: 18),
        label: const Text('导出到本机'),
      ),
    ];
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final stat = _stat;
    final exists = stat != null && stat.type != FileSystemEntityType.notFound;
    final modified = stat?.modified;
    final meta = !exists
        ? (stat == null ? '' : context.strings.fileDoesNotExist)
        : '${formatBytes(stat.size)} · '
              '${modified!.year}-${_two(modified.month)}-${_two(modified.day)} '
              '${_two(modified.hour)}:${_two(modified.minute)}';
    final isImage = widget.kind == FileKind.image;
    return ColoredBox(
      color: AppColors.bg,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (isImage && exists)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(_absolute),
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.broken_image_outlined,
                      size: 64,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              )
            else
              Icon(
                isImage
                    ? Icons.image_outlined
                    : _installable
                    ? Icons.android
                    : Icons.insert_drive_file_outlined,
                size: 64,
                color: AppColors.textSecondary,
              ),
            const SizedBox(height: 16),
            Text(
              baseName(widget.path),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              widget.path,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                meta,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
            if (_isDirectory) ...[
              const SizedBox(height: 4),
              Text(
                '$_dirFiles 个文件 · ${formatBytes(_dirBytes)}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: _desktop
                  ? _desktopActions(exists)
                  : [
                      for (final action in cardActions(widget.path))
                        switch (action) {
                          FileCardAction.installApk => FilledButton.icon(
                            onPressed: !exists
                                ? null
                                : () => _run(
                                    () => FlitFiles.installApk(_absolute),
                                    context
                                        .strings
                                        .cannotInstallAllowFlitToInstallUnknown,
                                  ),
                            icon: const Icon(
                              Icons.install_mobile_outlined,
                              size: 18,
                            ),
                            label: Text(context.strings.installLocally),
                          ),
                          FileCardAction.openExternal => OutlinedButton.icon(
                            onPressed: !exists
                                ? null
                                : () => _run(
                                    () => FlitFiles.open(_absolute),
                                    context
                                        .strings
                                        .noApplicationCanOpenThisFile,
                                  ),
                            icon: const Icon(Icons.open_in_new, size: 18),
                            label: Text(context.strings.openWith),
                          ),
                          FileCardAction.share => OutlinedButton.icon(
                            onPressed: !exists
                                ? null
                                : () => _run(
                                    () => FlitFiles.share(_absolute),
                                    context.strings.unableToShareThisFile,
                                  ),
                            icon: const Icon(Icons.share_outlined, size: 18),
                            label: Text(context.strings.share),
                          ),
                        },
                    ],
            ),
          ],
        ),
      ),
    );
  }
}
