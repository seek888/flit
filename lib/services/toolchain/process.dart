import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'errors.dart';

/// 子进程边界：工具链各层只通过它 spawn 进程，单测注入 fake 即可完全离线。
///
/// 关键点是 Windows 上的 `.bat/.cmd`：**直接以 argv 启动**（系统会交给
/// cmd 处理，CreateProcess 负责引用），不要自己拼
/// `cmd.exe /c "<bat>" <args...>`。Dart 会把传给 `cmd.exe` 的命令字符串
/// 整体再包一层引号、内层 `"` 转义成 `\"`，cmd 于是把 `\"` 当成命令名的
/// 一部分——`"D:\...\flutter.bat"` 会报「不是内部或外部命令」，带空格的
/// 路径/参数更是直接坏掉（新建项目预检就栽在这里）。
///
/// 真正对引号敏感的 sdkmanager 走 `java.exe -classpath sdkmanager.jar`
/// （见 `sdk_manager.dart`），完全不经过 shell。
abstract class ToolchainProcessGateway {
  /// 一次性执行（短命令：探测/版本读取）。
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 25),
    String? workingDirectory,
  });

  /// 需要写 stdin 的进程（`sdkmanager --licenses` 写 y）。
  Future<int> runWithStdin(
    String executable,
    List<String> arguments, {
    String stdinText = '',
    Map<String, String>? environment,
    Duration timeout = const Duration(minutes: 5),
    String? workingDirectory,
  });

  /// 流式输出（`flutter --version` 预热 / sdkmanager 安装），按行产出。
  /// [onClosed] 在进程退出后拿到退出码；超时会杀掉进程并抛 [ToolchainException]。
  Stream<String> stream(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    Duration timeout = const Duration(minutes: 30),
    String? workingDirectory,
    void Function(int exitCode)? onClosed,
  });
}

/// 解码子进程输出。
///
/// 工具链命令（flutter / sdkmanager / git）输出 UTF-8（`•`、中文、路径都
/// 是 UTF-8 字节）；cmd 内建命令与部分 OEM 工具输出系统代码页。先按 UTF-8
/// 严格解码，失败再退回 [SystemEncoding]，避免版本行出现 `鈥?` 这类乱码。
String decodeProcessOutput(List<int> bytes) {
  if (bytes.isEmpty) return '';
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return const SystemEncoding().decode(bytes);
  }
}

class SystemToolchainProcess implements ToolchainProcessGateway {
  const SystemToolchainProcess();

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 25),
    String? workingDirectory,
  }) async {
    final Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        environment: environment,
        workingDirectory: workingDirectory,
      );
    } on ProcessException catch (error) {
      throw ToolchainException(
        '无法启动命令：$executable（${error.message}）',
        cause: error,
      );
    }
    final stdoutBytes = _collect(process.stdout);
    final stderrBytes = _collect(process.stderr);
    try {
      final exitCode = await process.exitCode.timeout(timeout);
      return ProcessResult(
        process.pid,
        exitCode,
        decodeProcessOutput(await stdoutBytes),
        decodeProcessOutput(await stderrBytes),
      );
    } on TimeoutException {
      _kill(process);
      throw ToolchainException('命令执行超时（${timeout.inSeconds} 秒）：$executable');
    }
  }

  static Future<List<int>> _collect(Stream<List<int>> stream) =>
      stream.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));

  @override
  Future<int> runWithStdin(
    String executable,
    List<String> arguments, {
    String stdinText = '',
    Map<String, String>? environment,
    Duration timeout = const Duration(minutes: 5),
    String? workingDirectory,
  }) async {
    final Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        environment: environment,
        workingDirectory: workingDirectory,
      );
    } on ProcessException catch (error) {
      throw ToolchainException(
        '无法启动命令：$executable（${error.message}）',
        cause: error,
      );
    }
    final drained = Future.wait<void>(<Future<void>>[
      process.stdout.drain<void>(),
      process.stderr.drain<void>(),
    ]);
    try {
      if (stdinText.isNotEmpty) {
        process.stdin.write(stdinText);
        await process.stdin.flush();
      }
      await process.stdin.close();
    } catch (_) {
      // 进程可能不接受 stdin（例如已经退出），不影响退出码判断。
    }
    try {
      final exitCode = await process.exitCode.timeout(timeout);
      await drained.timeout(
        const Duration(seconds: 10),
        onTimeout: () => const <void>[],
      );
      return exitCode;
    } on TimeoutException {
      _kill(process);
      throw ToolchainException('命令执行超时（${timeout.inMinutes} 分钟）：$executable');
    }
  }

  @override
  Stream<String> stream(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    Duration timeout = const Duration(minutes: 30),
    String? workingDirectory,
    void Function(int exitCode)? onClosed,
  }) async* {
    final Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        environment: environment,
        workingDirectory: workingDirectory,
      );
    } on ProcessException catch (error) {
      throw ToolchainException(
        '无法启动命令：$executable（${error.message}）',
        cause: error,
      );
    }

    final lines = StreamController<String>();
    var openStreams = 2;
    void wire(Stream<List<int>> source) {
      source
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (!lines.isClosed) lines.add(line);
            },
            onError: (Object _) {},
            cancelOnError: false,
            onDone: () {
              openStreams--;
              if (openStreams == 0 && !lines.isClosed) lines.close();
            },
          );
    }

    wire(process.stdout);
    wire(process.stderr);

    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      _kill(process);
    });
    var completed = false;
    try {
      await for (final line in lines.stream) {
        yield line;
      }
      completed = true;
    } finally {
      timer.cancel();
      if (!completed) {
        _kill(process);
        if (!lines.isClosed) await lines.close();
      }
    }
    final exitCode = await process.exitCode;
    onClosed?.call(exitCode);
    if (timedOut) {
      throw ToolchainException('命令执行超时（${timeout.inMinutes} 分钟）：$executable');
    }
  }

  void _kill(Process process) {
    try {
      process.kill();
    } catch (_) {}
    try {
      Process.killPid(process.pid);
    } catch (_) {}
  }
}
