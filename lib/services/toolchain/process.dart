import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'errors.dart';

/// 子进程边界：工具链各层只通过它 spawn 进程，单测注入 fake 即可完全离线。
///
/// 关键点是 Windows 上的 `.bat/.cmd`：Dart 官方文档明确「批处理文件可能被
/// 系统 shell 启动，参数按 shell 规则解析」。这里统一改成
/// `cmd.exe /c <bat> <args...>`，比 `runInShell: true` 更可控；而真正对
/// 引号敏感的 sdkmanager 走 `java.exe -classpath sdkmanager.jar`（见
/// `sdk_manager.dart`），完全不经过 shell。
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

class SystemToolchainProcess implements ToolchainProcessGateway {
  const SystemToolchainProcess({bool? windows}) : _windows = windows;

  final bool? _windows;

  bool get _isWindows => _windows ?? Platform.isWindows;

  ({String executable, List<String> arguments}) _invocation(
    String executable,
    List<String> arguments,
  ) {
    final lower = executable.toLowerCase();
    final isBatch =
        _isWindows && (lower.endsWith('.bat') || lower.endsWith('.cmd'));
    if (isBatch) {
      return (
        executable: 'cmd.exe',
        arguments: <String>['/c', executable, ...arguments],
      );
    }
    return (executable: executable, arguments: arguments);
  }

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 25),
    String? workingDirectory,
  }) async {
    final invocation = _invocation(executable, arguments);
    try {
      return await Process.run(
        invocation.executable,
        invocation.arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        stdoutEncoding: const SystemEncoding(),
        stderrEncoding: const SystemEncoding(),
      ).timeout(timeout);
    } on TimeoutException {
      throw ToolchainException('命令执行超时（${timeout.inSeconds} 秒）：$executable');
    } on ProcessException catch (error) {
      throw ToolchainException(
        '无法启动命令：$executable（${error.message}）',
        cause: error,
      );
    }
  }

  @override
  Future<int> runWithStdin(
    String executable,
    List<String> arguments, {
    String stdinText = '',
    Map<String, String>? environment,
    Duration timeout = const Duration(minutes: 5),
    String? workingDirectory,
  }) async {
    final invocation = _invocation(executable, arguments);
    final Process process;
    try {
      process = await Process.start(
        invocation.executable,
        invocation.arguments,
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
    final invocation = _invocation(executable, arguments);
    final Process process;
    try {
      process = await Process.start(
        invocation.executable,
        invocation.arguments,
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
