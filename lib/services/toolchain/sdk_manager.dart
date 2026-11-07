import 'dart:async';
import 'dart:io';

import 'errors.dart';
import 'layout.dart';
import 'process.dart';

/// Android SDK 组件安装器。
///
/// 绕开 `.bat`：`sdkmanager.bat` 在路径含空格/`&` 时会被 shell 拆参数，
/// 所以直接用 `java.exe -classpath <jar> <主类> --sdk_root=...`，
/// java.exe 的参数不经过 shell，`C:\Users\Zhang San\...`、`A&B` 都安全。
class SdkManager {
  SdkManager({required this.layout, ToolchainProcessGateway? process})
    : process = process ?? const SystemToolchainProcess();

  final ToolchainLayout layout;
  final ToolchainProcessGateway process;

  /// `sdkmanager.bat` 的等价 argv 前缀（不含子命令）。
  List<String> get commandPrefix => <String>[
    '-classpath',
    layout.sdkManagerJar,
    'com.android.sdklib.tool.sdkmanager.SdkManagerCli',
    '--sdk_root=${layout.sdkDir}',
  ];

  bool get available =>
      File(layout.javaExe).existsSync() &&
      File(layout.sdkManagerJar).existsSync();

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

  void _ensureAvailable() {
    if (!File(layout.javaExe).existsSync()) {
      throw SdkManagerException(
        'JDK 未安装或损坏：${layout.javaExe}。请先在开发环境页完成 JDK 安装。',
      );
    }
    if (!File(layout.sdkManagerJar).existsSync()) {
      throw SdkManagerException(
        'Android cmdline-tools 未安装：${layout.sdkManagerJar}。请先完成 Android SDK 阶段。',
      );
    }
  }

  /// 流式安装一组组件；退出码非 0 时抛 [SdkManagerException]（带尾部输出）。
  Stream<String> install(List<String> packages) async* {
    _ensureAvailable();
    if (packages.isEmpty) return;
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

  Future<void> installPackages(List<String> packages) async {
    await install(packages).drain<void>();
  }
}
