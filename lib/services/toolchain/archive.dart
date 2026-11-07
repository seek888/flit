import 'dart:io';

import 'errors.dart';
import 'process.dart';

/// 解压：Windows 10 1803+ 自带 bsdtar 优先（能解 zip，路径处理比
/// Expand-Archive 好），失败再用 PowerShell 单命令兜底；两者都失败抛
/// 带操作提示的 [ArchiveException]，不再让 `ProcessException` 裸奔。
class ArchiveExtractor {
  ArchiveExtractor({required this.process, bool? windows})
    : windows = windows ?? Platform.isWindows;

  final ToolchainProcessGateway process;
  final bool windows;

  Future<void> extract(String archive, String destination) async {
    final target = Directory(destination);
    if (target.existsSync()) target.deleteSync(recursive: true);
    target.createSync(recursive: true);

    if (windows) {
      final tarCode = await _run('tar.exe', <String>[
        '-xf',
        archive,
        '-C',
        destination,
      ]);
      if (tarCode == 0) return;

      // 单条命令，满足「不依赖 PowerShell 写复杂逻辑」的约束。
      final powershellCode = await _run('powershell.exe', <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "Expand-Archive -LiteralPath '$archive' -DestinationPath "
            "'$destination' -Force",
      ]);
      if (powershellCode == 0) return;

      throw ArchiveException(
        '解压失败：tar.exe 与 PowerShell Expand-Archive 均失败'
        '（退出码 $tarCode / $powershellCode）。'
        '请确认系统为 Windows 10 1803 及以上；或手动解压 $archive 到 $destination。',
      );
    }

    final unzipCode = await _run('unzip', <String>[
      '-q',
      archive,
      '-d',
      destination,
    ]);
    if (unzipCode == 0) return;
    throw ArchiveException('解压失败（unzip 退出码 $unzipCode）：$archive');
  }

  Future<int> _run(String executable, List<String> arguments) async {
    try {
      final result = await process.run(
        executable,
        arguments,
        timeout: const Duration(minutes: 30),
      );
      return result.exitCode;
    } catch (_) {
      return -1;
    }
  }

  /// 解压目录下只有一个顶层目录时返回它（用来把 zip 的根目录「拍平」发布）。
  static String? singleChildDirectory(String directory) {
    final dir = Directory(directory);
    if (!dir.existsSync()) return null;
    final directories = dir.listSync().whereType<Directory>().toList();
    if (directories.length == 1) return directories.single.path;
    return null;
  }
}
