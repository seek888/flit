import 'dart:async';
import 'dart:io';

import 'errors.dart';
import 'layout.dart';
import 'process.dart';

/// `sdkmanager --list` 的一行可安装/已安装包。
///
/// [path] 就是 sdkmanager 的包路径（`cmake;3.22.1`、`platforms;android-36`…）。
/// 桌面端把它当作「版本目录」的唯一真值源，不再依赖 GitHub 上的 Android 产物。
typedef SdkPackage = ({
  String path,
  String version,
  String description,
  bool installed,
});

/// Android SDK 组件安装器。
///
/// 绕开 `.bat`：`sdkmanager.bat` 在路径含空格/`&` 时会被 shell 拆参数，
/// 所以直接用 `java.exe -classpath <jar> <主类> --sdk_root=...`，
/// java.exe 的参数不经过 shell，`C:\Users\Zhang San\...`、`A&B` 都安全。
///
/// classpath jar 的名字随 cmdline-tools 版本变化：
/// - 新版（build 13114758 起）：`lib/sdkmanager-classpath.jar`
/// - 旧版：`lib/sdkmanager.jar`
/// 这里按「先新后旧」解析，避免升级 cmdline-tools 后整条 SDK 阶段失效。
class SdkManager {
  SdkManager({required this.layout, ToolchainProcessGateway? process})
    : process = process ?? const SystemToolchainProcess();

  final ToolchainLayout layout;
  final ToolchainProcessGateway process;

  /// 实际可用的 classpath jar；两个名字都不存在时返回 null。
  String? get classpathJar {
    for (final path in <String>[
      layout.sdkManagerClasspathJar,
      layout.sdkManagerLegacyJar,
    ]) {
      final file = File(path);
      try {
        if (file.existsSync() && file.lengthSync() > 0) return path;
      } catch (_) {}
    }
    return null;
  }

  /// `sdkmanager.bat` 的等价 argv 前缀（不含子命令）。
  ///
  /// `-Dcom.android.sdklib.toolsdir` 与官方 `.bat` 一致：sdkmanager 用它
  /// 定位自身的 `tools` 目录（许可文案、资源）。
  List<String> get commandPrefix => <String>[
    '-Dcom.android.sdklib.toolsdir=${layout.cmdlineToolsDir}',
    '-classpath',
    classpathJar ?? layout.sdkManagerClasspathJar,
    'com.android.sdklib.tool.sdkmanager.SdkManagerCli',
    '--sdk_root=${layout.sdkDir}',
  ];

  bool get available =>
      File(layout.javaExe).existsSync() && classpathJar != null;

  /// 组件 id + 版本 → sdkmanager 包名；不支持的返回 null。
  static String? packageFor(String id, String version) => switch (id) {
    'platforms' => 'platforms;android-$version',
    'build-tools' => 'build-tools;$version',
    'ndk' => 'ndk;$version',
    'cmake' => 'cmake;$version',
    'platform-tools' => 'platform-tools',
    'cmdline-tools' => 'cmdline-tools;latest',
    _ => null,
  };

  /// 当前生效的仓库源（日志与排障用）。
  String get repositorySource => layout.androidSdkMirrored
      ? '${layout.androidSdkRepo}（国内镜像）'
      : '${ToolchainLayout.officialAndroidSdkBase}（官方源）';

  void _ensureAvailable() {
    if (!File(layout.javaExe).existsSync()) {
      throw SdkManagerException(
        'JDK 未安装或损坏：${layout.javaExe}。请先在开发环境页完成 JDK 安装。',
      );
    }
    if (classpathJar == null) {
      throw SdkManagerException(
        'Android cmdline-tools 未安装或不完整：'
        '${layout.cmdlineToolsDir}（缺少 lib/sdkmanager-classpath.jar）。'
        '请先完成 Android SDK 阶段。',
      );
    }
  }

  /// 流式安装一组组件；退出码非 0 时抛 [SdkManagerException]（带尾部输出）。
  Stream<String> install(List<String> packages) async* {
    _ensureAvailable();
    if (packages.isEmpty) return;
    yield 'Android SDK 下载源：$repositorySource';
    yield 'sdkmanager --install ${packages.join(' ')}';
    final tail = <String>[];
    var exitCode = -1;
    final lines = process.stream(
      layout.javaExe,
      <String>[...commandPrefix, ...packages],
      environment: layout.childEnvironment(),
      timeout: const Duration(minutes: 30),
      onClosed: (code) => exitCode = code,
    );
    await for (final line in lines) {
      tail.add(line);
      if (tail.length > 20) tail.removeAt(0);
      yield line;
    }
    if (exitCode != 0) {
      throw SdkManagerException(
        'sdkmanager 安装失败（退出码 $exitCode）：${packages.join(' ')}'
        '${tail.isEmpty ? '' : '\n${tail.join('\n')}'}',
      );
    }
  }

  /// 接受 Android SDK 许可（stdin 写 y，然后关闭）。
  Future<void> acceptLicenses({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    _ensureAvailable();
    final input = List<String>.filled(200, 'y').join('\n');
    final exitCode = await process.runWithStdin(
      layout.javaExe,
      <String>[...commandPrefix, '--licenses'],
      stdinText: '$input\n',
      environment: layout.childEnvironment(),
      timeout: timeout,
    );
    if (exitCode != 0) {
      throw SdkManagerException('接受 Android SDK 许可失败（退出码 $exitCode）');
    }
  }

  /// 查询 SDK 仓库（国内镜像或官方）里的可安装包；耗时较长（要拉仓库元数据）。
  Future<List<SdkPackage>> listPackages({
    Duration timeout = const Duration(minutes: 6),
  }) async {
    _ensureAvailable();
    final result = await process.run(
      layout.javaExe,
      <String>[...commandPrefix, '--list'],
      environment: layout.childEnvironment(),
      timeout: timeout,
    );
    return parseListOutput('${result.stdout}\n${result.stderr}');
  }

  /// 解析 `sdkmanager --list` 输出（纯函数，单测用固定文本覆盖）。
  ///
  /// 结构：`Installed packages:` / `Available Packages:` 两个分段，行形如
  /// `  cmake;3.22.1  | 3.22.1 | CMake 3.22.1 | cmake\3.22.1`
  /// （最后一列只有已安装行才有）。
  static List<SdkPackage> parseListOutput(String text) {
    final byPath = <String, SdkPackage>{};
    var installed = false;
    for (final rawLine in text.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final lower = line.toLowerCase();
      if (lower.startsWith('installed packages')) {
        installed = true;
        continue;
      }
      if (lower.startsWith('available packages') ||
          lower.startsWith('available updates')) {
        installed = false;
        continue;
      }
      if (!line.contains('|')) continue;
      final cells = line.split('|').map((cell) => cell.trim()).toList();
      if (cells.length < 2) continue;
      final path = cells[0];
      if (path.isEmpty || path.contains(' ') || path == 'Path') continue;
      // 包路径形如 `type;version`；platform-tools / emulator / tools 没有分号。
      if (!path.contains(';') &&
          path != 'platform-tools' &&
          path != 'emulator' &&
          path != 'tools') {
        continue;
      }
      final package = (
        path: path,
        version: cells[1],
        description: cells.length > 2 ? cells[2] : '',
        installed: installed,
      );
      final existing = byPath[path];
      // 同一包可能同时出现在两个分段里：已安装优先保留。
      if (existing == null || (!existing.installed && installed)) {
        byPath[path] = package;
      }
    }
    final result = byPath.values.toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return result;
  }

  Future<void> installPackages(List<String> packages) async {
    await install(packages).drain<void>();
  }
}