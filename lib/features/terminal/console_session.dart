import 'package:flit/l10n/strings.dart';

import 'dart:async';
import 'dart:convert' as convert;

import 'package:flutter/material.dart' show ScrollController;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flit_work/flit_work.dart';
import 'package:xterm/xterm.dart';

import '../../services/console_command.dart';
import '../../services/shell.dart';
import 'terminal_log.dart';

enum ExecutionState { idle, starting, running, stopping, exited, failed }

/// The small process boundary also lets lifecycle tests run without native PTYs.
abstract interface class SessionProcess {
  Stream<List<int>> get output;
  Future<int> get exitCode;
  void write(Uint8List data);
  void resize(int rows, int columns);
  void kill();
}

/// How a console obtains its process. Production wires PtyLauncher in from the
/// composition root; nothing in this layer knows how to start a PTY by itself.
typedef ProcessLauncher =
    Future<SessionProcess> Function({
      required String? command,
      required String? workingDirectory,
      required int rows,
      required int columns,
    });

/// 三类会话(与 AS 的 Terminal / Run / 命令控制台对应):
/// shell 默认 bash: 永远在, 唯一可输入; run: 跑起来才有, 能停(⏹, 输出留着)能删(✕);
/// temp 临时: 跑起来才有, 只能删(✕, 在跑则终止)。run/temp 只读, 删掉后回落默认 shell。
enum SessionKind { shell, run, temp }

/// A console and its current process. Views never own or choose a process.
/// Output/selection survive process exit and are released when the owner closes.
class ConsoleSession extends ChangeNotifier {
  ConsoleSession({
    required this.title,
    this.kind = SessionKind.temp,
    required ProcessLauncher launcher,
  }) : _launcher = launcher {
    terminal.onOutput = input;
    terminal.onResize = (columns, rows, _, __) =>
        _process?.resize(rows < 1 ? 1 : rows, columns < 1 ? 1 : columns);
  }

  final String title;
  final SessionKind kind;

  /// 只有默认 bash 接受用户输入; run/temp 由按钮程序性驱动(如热重载 r/R)
  bool get interactive => kind == SessionKind.shell;
  final ProcessLauncher _launcher;
  final terminal = Terminal(maxLines: 10000);
  final controller = TerminalController();
  final scrollController = ScrollController();
  late final log = TerminalLog(terminal);
  final _text = StreamController<String>.broadcast(sync: true);
  Stream<String> get textStream => _text.stream;
  ExecutionState state = ExecutionState.idle;
  int? exitCode;
  bool ctrlArmed = false;
  bool get alive =>
      state == ExecutionState.starting ||
      state == ExecutionState.running ||
      state == ExecutionState.stopping;

  /// 头部 ⏹ 的依据: 只有 run 会话能"停而不丢"; temp 只能连输出一起关掉
  bool get stoppable => kind == SessionKind.run && alive;
  bool get disposed => _disposed;
  bool _disposed = false;
  bool _stopRequested = false;
  bool get stopRequested => _stopRequested;
  SessionProcess? _process;
  Future<void>? _starting;
  Future<void>? _stopping;
  Completer<int> _done = Completer<int>();
  Future<int> get done => _done.future;
  bool _task = false;
  bool _keepAlive = false; // 进程存活期间持有前台服务保活

  /// 非进程任务(如 Dart 侧的原生下载/解压)也登记为本会话的任务: 头部状态、
  /// 停止按钮与进程任务走同一套逻辑。stop() 只置 stopRequested, 任务方自行收手。
  void beginTask() {
    if (_disposed || _closing != null) {
      throw StateError(strings.sessionIsClosed);
    }
    if (alive) throw StateError(strings.theCurrentTaskHasNotFinished);
    _stopRequested = false;
    exitCode = null;
    _done = Completer<int>();
    _task = true;
    state = ExecutionState.running;
    notifyListeners();
  }

  void endTask({int code = 0}) {
    if (!_task) return;
    _task = false;
    exitCode = code;
    state = code == 0 || _stopRequested
        ? ExecutionState.exited
        : ExecutionState.failed;
    _done.complete(code);
    notifyListeners();
  }

  /// 桌面端命令归一化：把 Android 专属的 bash 包装剥掉，见
  /// `services/console_command.dart`（纯函数，可单测）。
  static String? _normalizeForDesktop(String? command) {
    if (command == null || !isDesktopPlatform) return command;
    return normalizeConsoleCommand(command, platform: hostPlatform);
  }

  Future<void> start({
    String? command,
    String? displayCommand,
    String? workingDirectory,
    String Function(String)? outputFormatter,
    String Function()? finishOutput,
  }) {
    if (_disposed || _closing != null) {
      return Future.error(StateError(strings.sessionIsClosed));
    }
    if (_starting != null) return _starting!;
    if (alive) return Future.value();
    // 桌面端：没有 bash，也不需要 android_build.sh 的 aapt2 覆盖与环境 source。
    command = _normalizeForDesktop(command);
    if (command != null && command.trim().isNotEmpty) {
      log.info('\$ ${displayCommand ?? command}');
    }
    _stopRequested = false;
    exitCode = null;
    _done = Completer<int>();
    state = ExecutionState.starting;
    notifyListeners();
    return _starting = _launch(
      command,
      workingDirectory,
      outputFormatter,
      finishOutput,
    ).whenComplete(() => _starting = null);
  }

  Future<void> _launch(
    String? command,
    String? cwd,
    String Function(String)? outputFormatter,
    String Function()? finishOutput,
  ) async {
    try {
      final process = await _launcher(
        command: command,
        workingDirectory: cwd,
        rows: terminal.viewHeight > 0 ? terminal.viewHeight : 24,
        columns: terminal.viewWidth > 0 ? terminal.viewWidth : 80,
      );
      _process = process;
      final outputDone = Completer<void>();
      process.output
          // PTY 输出 Uint8List: 先用 map 统一流元素类型(不经 cast 包装器,
          // 规避 Utf8Decoder 的运行时类型转换失败), 再解码;
          // Utf8Decoder 变换器跨数据块保持解码状态, 中文不受数据块切分影响。
          .map<List<int>>((data) => data)
          .transform(const convert.Utf8Decoder(allowMalformed: true))
          .listen(
            (chunk) {
              terminal.write(outputFormatter?.call(chunk) ?? chunk);
              _text.add(chunk);
            },
            onError: (Object error) =>
                log.err(strings.failedToReadOutputP(error)),
            onDone: () {
              if (finishOutput != null) terminal.write(finishOutput());
              outputDone.complete();
            },
          );
      state = _stopRequested ? ExecutionState.stopping : ExecutionState.running;
      if (!_keepAlive) {
        _keepAlive = true;
        unawaited(WorkKeepAlive.acquire());
      }
      notifyListeners();
      unawaited(_watch(process, outputDone.future));
      if (_stopRequested) process.kill();
    } catch (error) {
      state = ExecutionState.failed;
      exitCode = -1;
      log.err(strings.failedToStartP(error));
      _done.complete(-1);
      notifyListeners();
    }
  }

  Future<void> _watch(SessionProcess process, Future<void> outputDone) async {
    final code = await process.exitCode;
    await outputDone;
    _process = null;
    if (_disposed) {
      if (!_done.isCompleted) _done.complete(code);
      return;
    }
    if (_keepAlive) {
      _keepAlive = false;
      unawaited(WorkKeepAlive.release());
    }
    exitCode = code;
    state = code == 0 || _stopRequested
        ? ExecutionState.exited
        : ExecutionState.failed;
    if (_stopRequested) {
      log.warn(strings.stopped);
    } else if (code == 0) {
      log.ok(strings.processExitedWithCode);
    } else {
      log.err(strings.processExitedWithCodeP(code));
    }
    _done.complete(code);
    notifyListeners();
  }

  void write(String data) =>
      _process?.write(Uint8List.fromList(convert.utf8.encode(data)));

  void input(String data) {
    if (ctrlArmed && data.length == 1) {
      final c = data.toLowerCase().codeUnitAt(0);
      if (c >= 0x61 && c <= 0x7a) data = String.fromCharCode(c & 0x1f);
      ctrlArmed = false;
      notifyListeners();
    }
    write(data);
  }

  void toggleCtrl() {
    ctrlArmed = !ctrlArmed;
    notifyListeners();
  }

  Future<void> stop() =>
      _stopping ??= _stop().whenComplete(() => _stopping = null);

  Future<void> _stop() async {
    if (!alive) return;
    _stopRequested = true;
    state = ExecutionState.stopping;
    notifyListeners();
    if (_task) {
      // 非进程任务打不断: 任务方看到 stopRequested 后尽早收尾, 这里等它结束
      await done;
      return;
    }
    await _starting;
    write('\x03');
    try {
      await done.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _process?.kill();
      await done;
    }
  }

  Future<int> run(
    String command, {
    String? displayCommand,
    String? workingDirectory,
    Duration timeout = const Duration(minutes: 30),
  }) async {
    if (alive) throw StateError(strings.theCurrentTaskHasNotFinished);
    await start(
      command: command,
      displayCommand: displayCommand,
      workingDirectory: workingDirectory,
    );
    try {
      return await done.timeout(timeout);
    } on TimeoutException {
      log.err(strings.executionTimedOutStopping);
      await stop();
      return -1;
    }
  }

  String? copySelection() {
    final selection = controller.selection;
    return selection == null ? null : terminal.buffer.getText(selection);
  }

  void selectAll() {
    controller.clearSelection();
    controller.setSelection(
      terminal.buffer.createAnchor(0, 0),
      terminal.buffer.createAnchorFromCursor(),
    );
  }

  Future<void> pasteClipboard() async {
    final text = (await Clipboard.getData('text/plain'))?.text;
    if (text != null && text.isNotEmpty && !_disposed) terminal.paste(text);
  }

  void clearScreen() {
    terminal.buffer.clearScrollback();
    terminal.write('\x1b[2J\x1b[H');
  }

  Future<void>? _closing;
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    // 关闭 = 立即终止整个进程组(SIGKILL), 不走优雅停止:
    // 优雅(Ctrl+C → 最多等 3s 再杀)是 ⏹ 的语义, 关闭要的是立刻释放——
    // bash 对 Ctrl+C 不退场, 优雅路径每次都白等满 3s, 关闭项目被拖慢就是它。
    if (alive) {
      _stopRequested = true;
      state = ExecutionState.stopping;
      _process?.kill();
    }
    _disposed = true;
    if (!_done.isCompleted) _done.complete(-1);
    notifyListeners();
    // Mounted panels detach their TerminalView before its controllers are freed.
    if (SchedulerBinding.instance.hasScheduledFrame) {
      await SchedulerBinding.instance.endOfFrame;
    }
    terminal.onOutput = null;
    terminal.onResize = null;
    await _text.close();
    scrollController.dispose();
    controller.dispose();
    super.dispose();
  }
}
