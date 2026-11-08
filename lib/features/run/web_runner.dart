import 'package:flit/l10n/strings.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../services/desktop_toolchain.dart';
import '../../services/paths.dart';
import '../../services/shell.dart';
import '../terminal/run_sessions.dart';
import '../terminal/flutter_log_formatter.dart';

enum WebRunState { idle, starting, serving, stopped, failed }

/// 工程是否已具备 Web 平台入口（`web/index.html` 是 `flutter build web` 的硬前提）。
bool hasWebPlatform(String projectPath) =>
    File(joinPath(projectPath, 'web/index.html')).existsSync();

/// 补建 Web 平台目录：`flutter create --platforms=web .`。
///
/// 桌面端用参数数组 + [Process.run]（不再拼 `if [ ! -d web ]` / `stty` 这类
/// POSIX 语法，Windows 的 cmd.exe 解析不了）；Android 端保持原来的命令串。
/// 返回是否真的执行了创建；工程已有 `web/` 时什么都不做。
///
/// 桌面 Flutter 尚未装好时直接返回 false：让真正的 build/run 命令报出更准确的
/// “Flutter 未安装”诊断，而不是被引导步骤的失败盖掉。
Future<bool> ensureWebPlatform(String projectPath) async {
  if (hasWebPlatform(projectPath)) return false;
  if (isDesktopPlatform) {
    final toolchain = DesktopToolchain();
    if (!File(toolchain.flutterExe).existsSync()) return false;
    // 直接以 argv 启动 `.bat`（不要 runInShell：Windows 上它会把路径与参数
    // 重新拼进 cmd 命令行，工具链 home 含空格时会被拼坏）。
    final result = await Process.run(
      toolchain.flutterExe,
      const ['create', '--platforms=web', '.'],
      workingDirectory: projectPath,
      environment: toolchain.childEnvironment,
      stdoutEncoding: const SystemEncoding(),
      stderrEncoding: const SystemEncoding(),
    );
    if (result.exitCode != 0) {
      throw StateError(
        '无法为工程补建 Web 平台目录（flutter create --platforms=web .）：'
        '${('${result.stdout}${result.stderr}').trim()}',
      );
    }
    return true;
  }
  final result = await Shell.instance.exec(
    'cd ${shQuote(projectPath)} && flutter create --platforms=web . 2>&1',
    timeoutMs: 180000,
  );
  if (result['exitCode'] != 0) {
    throw StateError(
      '无法为工程补建 Web 平台目录（flutter create --platforms=web .）：'
      '${result['output'] ?? ''}',
    );
  }
  return true;
}

/// Web 预览的 flutter machine 命令。
///
/// 桌面端：不带 POSIX 引导与 `stty`，主机固定回环（cmd.exe 可解析、无 stty）；
/// Android 端：保留原有的「缺 web/ 就补建 + stty -echo + 0.0.0.0」命令串。
String webRunCommand(int port, {required bool desktop}) {
  if (desktop) {
    return 'flutter run --machine -d web-server --web-hostname 127.0.0.1 '
        '--web-port $port --no-devtools 2>&1';
  }
  return 'if [ ! -d web ]; then flutter create --platforms web . || exit \$?; fi; '
      'stty -echo; '
      // 0.0.0.0 让同一局域网的设备能用手机 IP 访问预览;
      // 应用内 WebView 仍走回环地址(见 app.webLaunchUrl 归一化)。
      'flutter run --machine -d web-server --web-hostname 0.0.0.0 '
      '--web-port $port --no-devtools 2>&1';
}

/// The project owns the server and Flutter protocol; changing views owns neither.
class WebRunController extends ChangeNotifier {
  WebRunController(
    this.executions, {
    Future<int> Function()? allocatePort,
    Future<void> Function(String projectPath)? prepareWeb,
  }) : _allocatePort = allocatePort ?? _freePort,
       _prepareWeb = prepareWeb ?? _defaultPrepareWeb {
    executions.addListener(_executionChanged);
  }

  final RunSessions executions;
  final Future<int> Function() _allocatePort;

  /// 桌面端点“Web 预览”前补建 `web/` 平台目录（测试注入 no-op，不 spawn flutter）。
  final Future<void> Function(String projectPath) _prepareWeb;

  static Future<void> _defaultPrepareWeb(String projectPath) async {
    await ensureWebPlatform(projectPath);
  }

  RunSession? session;
  WebRunState state = WebRunState.idle;
  Uri? url;
  String? error;
  bool reloading = false;
  bool _clientReady = false;
  String? _appId;
  String _buffer = '';
  FlutterLogFormatter _logs = FlutterLogFormatter();
  int _epoch = 0;
  int _requestId = 0;
  int? _port;
  bool _disposed = false;
  Future<void>? _starting;
  Timer? _startupTimer;
  final _requests = <int, Completer<Map<String, dynamic>>>{};

  bool get starting => state == WebRunState.starting;
  bool get serving => state == WebRunState.serving && session?.alive == true;
  bool get canReload => serving && _clientReady && _appId != null && !reloading;

  static Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Future<void> start() {
    if (_starting != null) return _starting!;
    if (starting) return Future.value();
    return _starting = _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    if (_disposed) return;
    final epoch = ++_epoch;
    _finishRequests(strings.webServerRestarted);
    _startupTimer?.cancel();
    session = null;
    url = null;
    error = null;
    _appId = null;
    _clientReady = false;
    _buffer = '';
    _logs = FlutterLogFormatter();
    state = WebRunState.starting;
    notifyListeners();
    _startupTimer = Timer(const Duration(minutes: 6), () {
      if (_disposed || epoch != _epoch || !starting) return;
      _fail(strings.webStartupTimedOutCheckRunLogs);
      unawaited(session?.stop());
    });
    try {
      final port = await _allocatePort();
      if (_disposed || epoch != _epoch) return;
      _port = port;
      if (isDesktopPlatform) {
        // 桌面端补建 web/ 用 Dart 判断 + flutter create（参数数组），
        // 不再把 POSIX 引导塞进命令串；启动中/计时器失效时放弃本次启动。
        await _prepareWeb(executions.projectPath);
        if (_disposed || epoch != _epoch || !starting) return;
      }
      final launched = await executions.start(
        RunConfiguration(
          id: 'run:web',
          title: 'Web',
          kind: SessionKind.run,
          hotReload: true,
          target: 'web',
          command: webRunCommand(port, desktop: isDesktopPlatform),
        ),
        outputFormatter: (chunk) =>
            epoch == _epoch && !_disposed ? _readOutput(chunk) : chunk,
        finishOutput: () {
          final remaining = _buffer;
          _buffer = '';
          return _logs.call(remaining) + _logs.finish();
        },
      );
      if (_disposed || epoch != _epoch) {
        await launched.stop();
        return;
      }
      session = launched;
      if (state == WebRunState.failed) {
        await launched.stop();
      } else {
        _executionChanged();
        notifyListeners();
      }
    } catch (e) {
      if (!_disposed && epoch == _epoch) _fail(strings.webStartupFailedP(e));
    }
  }

  // Machine messages are line-delimited arrays. PTY chunks may split anywhere.
  // Keep the raw stream available to consumers, but show readable console logs.
  String _readOutput(String chunk) {
    _buffer += chunk;
    final output = StringBuffer();
    void printLine(Object? text, {String? color}) {
      final message = (text ?? '').toString();
      output.write(
        '${(color == null ? message : FlutterLogFormatter.color(message, color)).replaceAll(RegExp(r'\r?\n'), '\r\n')}\r\n',
      );
    }

    int end;
    while ((end = _buffer.indexOf('\n')) >= 0) {
      final line = _buffer.substring(0, end).trimRight();
      _buffer = _buffer.substring(end + 1);
      dynamic decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        output.write('$line\r\n');
        continue;
      }
      if (decoded is! List || decoded.any((item) => item is! Map)) {
        output.write('$line\r\n');
        continue;
      }
      for (final item in decoded.cast<Map>()) {
        final event = Map<String, dynamic>.from(item);
        final params = event['params'] is Map
            ? Map<String, dynamic>.from(event['params'] as Map)
            : <String, dynamic>{};
        switch (event['event']) {
          case 'app.start':
            _appId = params['appId'] as String?;
          case 'app.webLaunchUrl':
            // daemon 会按 --web-hostname 回报 0.0.0.0; WebView 只认回环地址,
            // 统一归一化后再作为预览地址。
            final candidate = Uri.tryParse(params['url'] as String? ?? '');
            if (candidate != null &&
                candidate.port == _port &&
                const {
                  '0.0.0.0',
                  '127.0.0.1',
                  'localhost',
                }.contains(candidate.host)) {
              url = candidate.replace(host: '127.0.0.1');
            }
          case 'app.started':
            if (url != null && state == WebRunState.starting) {
              _startupTimer?.cancel();
              state = WebRunState.serving;
              notifyListeners();
            }
          case 'app.stop':
            if (params['error'] != null) {
              _fail(strings.webRunFailedP(params['error']));
            }
          case 'app.log':
            printLine(
              params['log'],
              color: params['error'] == true ? '31' : null,
            );
          case 'app.progress':
            if (params['message'] != null) {
              printLine(params['message'], color: '36');
            }
          case 'daemon.logMessage':
            printLine(
              params['message'],
              color: switch (params['level']) {
                'error' => '31',
                'warning' => '33',
                'trace' => '90',
                _ => null,
              },
            );
            if (params['stackTrace'] != null) {
              printLine(params['stackTrace']);
            }
        }
        final completer = _requests.remove(event['id']);
        if (completer != null) completer.complete(event);
      }
    }
    return _logs.call(output.toString());
  }

  void setClientReady(bool ready) {
    if (_disposed || _clientReady == ready) return;
    _clientReady = ready;
    notifyListeners();
  }

  /// Use Flutter's reply, rather than a delay, to know compilation completed.
  Future<bool> reload({bool fullRestart = false}) async {
    if (!canReload) return false;
    reloading = true;
    error = null;
    notifyListeners();
    final epoch = _epoch;
    final id = ++_requestId;
    final reply = Completer<Map<String, dynamic>>();
    _requests[id] = reply;
    session!.write(
      '${jsonEncode([
        {
          'id': id,
          'method': 'app.restart',
          'params': {'appId': _appId, 'fullRestart': fullRestart, 'pause': false},
        },
      ])}\n',
    );
    try {
      final response = await reply.future.timeout(const Duration(minutes: 2));
      final result = response['result'];
      if (response['error'] != null || result is! Map || result['code'] != 0) {
        throw StateError(
          '${response['error'] ?? (result is Map ? result['message'] : strings.compilationFailed)}',
        );
      }
      return !_disposed && epoch == _epoch;
    } catch (e) {
      if (!_disposed && epoch == _epoch) {
        error = strings.updateFailedP(e);
        session?.log.err(error!);
      }
      return false;
    } finally {
      _requests.remove(id);
      if (!_disposed && epoch == _epoch) {
        reloading = false;
        notifyListeners();
      }
    }
  }

  void _executionChanged() {
    if (_disposed || session == null || session!.alive) return;
    _startupTimer?.cancel();
    if (state != WebRunState.failed) {
      state = session!.stopRequested || session!.exitCode == 0
          ? WebRunState.stopped
          : WebRunState.failed;
      error = state == WebRunState.failed
          ? strings.webProcessExitedCodePCheckRun(session!.exitCode)
          : null;
    }
    _clientReady = false;
    _finishRequests(strings.webServerStopped);
    notifyListeners();
  }

  void _finishRequests(String reason) {
    for (final request in _requests.values) {
      request.complete({'error': reason});
    }
    _requests.clear();
    reloading = false;
  }

  void _fail(String message) {
    _startupTimer?.cancel();
    state = WebRunState.failed;
    error = message;
    _clientReady = false;
    _finishRequests(message);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    _startupTimer?.cancel();
    executions.removeListener(_executionChanged);
    _finishRequests(strings.projectIsClosed);
    super.dispose();
  }
}
