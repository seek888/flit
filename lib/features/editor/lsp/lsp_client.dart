import 'package:flit/l10n/strings.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flit_lsp/flit_lsp.dart';
import '../../../services/paths.dart';
import 'protocol.dart';

enum LanguageServiceState { stopped, starting, ready, unavailable }

/// One project-scoped Dart language server. A successful process spawn is not
/// readiness: initialize must complete before any document notification is sent.
class LspClient {
  LspClient();
  static int _nextGeneration = 0;
  bool _disposed = false;
  final state = ValueNotifier(LanguageServiceState.stopped);
  final _diagCtrl = StreamController<DiagnosticsReport>.broadcast();
  Stream<DiagnosticsReport> get diagnostics => _diagCtrl.stream;
  StreamSubscription<dynamic>? _subscription;
  Future<bool>? _starting;
  String? _root;
  int _generation = 0;
  final _documents = <String, ({int version, String text})>{};
  Future<void> _documentQueue = Future.value();
  bool _resolveSupported = false;
  bool get ready => state.value == LanguageServiceState.ready;

  Future<bool> ensureStarted(String projectPath) async {
    if (_disposed) return false;
    if (_root == projectPath && ready) return true;
    if (_starting != null) {
      await _starting;
      if (_disposed) return false;
      if (_root == projectPath && ready) return true;
    }
    return await (_starting = _start(
      projectPath,
    ).whenComplete(() => _starting = null));
  }

  Future<bool> _start(String projectPath) async {
    final generation = _generation = ++_nextGeneration;
    _documents.clear();
    _documentQueue = Future.value();
    _resolveSupported = false;
    await FlitLsp.stop();
    if (generation != _generation) return false;
    _root = projectPath;
    state.value = LanguageServiceState.starting;
    _subscription ??= FlitLsp.notifications.listen(
      (data) {
        if (data is! String) return;
        try {
          final message = jsonDecode(data) as Map<String, dynamic>;
          if (message['flitSession'] != _generation) return;
          if (message['method'] == 'textDocument/publishDiagnostics' && ready) {
            _diagCtrl.add(DiagnosticsReport.parse(data));
          } else if (message['method'] == 'flit/serverExited') {
            _generation = ++_nextGeneration;
            _documentQueue = Future.value();
            _documents.clear();
            state.value = LanguageServiceState.unavailable;
          }
        } catch (_) {
          /* Ignore unsupported notifications. */
        }
      },
      onError: (_) {
        state.value = LanguageServiceState.unavailable;
      },
    );
    try {
      final spawned = await FlitLsp.start(
        rootPath: projectPath,
        session: generation,
      );
      if (generation != _generation) {
        await FlitLsp.stop();
        return false;
      }
      if (!spawned) throw StateError(strings.dartLanguageServiceCouldNotStart);
      final response = await _request('initialize', {
        'processId': null,
        'rootUri': LspProtocol.fileUri(projectPath),
        'workspaceFolders': [
          {
            'uri': LspProtocol.fileUri(projectPath),
            'name': baseName(projectPath),
          },
        ],
        'capabilities': {
          'general': {
            'positionEncodings': ['utf-16'],
          },
          'textDocument': {
            'completion': {
              'completionItem': {
                'snippetSupport': false,
                'insertReplaceSupport': true,
                'documentationFormat': ['plaintext'],
                'resolveSupport': {
                  'properties': [
                    'documentation',
                    'detail',
                    'additionalTextEdits',
                  ],
                },
              },
            },
            'publishDiagnostics': {'versionSupport': true},
            'signatureHelp': {
              'signatureInformation': {
                'parameterInformation': {'labelOffsetSupport': true},
              },
            },
          },
        },
        'clientInfo': {'name': 'Flit'},
        // 真机冷启动(分析器首启+全工程索引)可能超过 20s, 放宽到 60s
      }, timeout: const Duration(seconds: 60));
      if (response == null ||
          response['error'] != null ||
          response['result'] is! Map ||
          generation != _generation) {
        throw StateError(strings.initializationFailed);
      }
      final capabilities = (response['result'] as Map)['capabilities'] as Map?;
      _resolveSupported =
          (capabilities?['completionProvider'] as Map?)?['resolveProvider'] ==
          true;
      await _notify('initialized', {});
      if (generation != _generation) return false;
      state.value = LanguageServiceState.ready;
      return true;
    } catch (_) {
      if (generation == _generation) {
        await FlitLsp.stop();
        state.value = LanguageServiceState.unavailable;
      }
      return false;
    }
  }

  Future<void> _notify(String method, Map<String, dynamic> params) async {
    final generation = _generation;
    try {
      final sent = await FlitLsp.notify(method, jsonEncode(params));
      if (!sent) throw StateError(strings.languageServiceDisconnected);
    } catch (_) {
      if (generation == _generation) {
        state.value = LanguageServiceState.unavailable;
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> _request(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final json = await FlitLsp.request(
      method,
      jsonEncode(params),
    ).timeout(timeout);
    if (json == null) return null;
    return jsonDecode(json) as Map<String, dynamic>;
  }

  Future<void> openDocument(String path, String text) =>
      updateDocument(path, text);

  /// Serial notifications preserve protocol order, including rapid edits and
  /// an immediate completion request while a debounce timer is pending.
  Future<void> updateDocument(String path, String text) {
    final generation = _generation;
    final operation = _documentQueue.catchError((_) {}).then((_) async {
      if (!ready || generation != _generation || !path.endsWith('.dart')) {
        return;
      }
      final previous = _documents[path];
      if (previous?.text == text) return;
      final version = (previous?.version ?? 0) + 1;
      await _notify(
        previous == null ? 'textDocument/didOpen' : 'textDocument/didChange',
        previous == null
            ? {
                'textDocument': {
                  'uri': LspProtocol.fileUri(path),
                  'languageId': 'dart',
                  'version': version,
                  'text': text,
                },
              }
            : {
                'textDocument': {
                  'uri': LspProtocol.fileUri(path),
                  'version': version,
                },
                'contentChanges': [
                  {'text': text},
                ],
              },
      );
      if (generation == _generation) {
        _documents[path] = (version: version, text: text);
      }
    });
    _documentQueue = operation;
    return operation;
  }

  Future<void> closeDocument(String path) {
    final generation = _generation;
    final operation = _documentQueue.catchError((_) {}).then((_) async {
      if (generation != _generation || !ready) return;
      if (_documents.remove(path) != null) {
        await _notify('textDocument/didClose', {
          'textDocument': {'uri': LspProtocol.fileUri(path)},
        });
      }
    });
    _documentQueue = operation;
    return operation;
  }

  bool acceptsDiagnostics(DiagnosticsReport report, String text) {
    // 语言服务回的路径来自 Uri.toFilePath()（Windows 是 `C:\a\b`），
    // 编辑器里的路径是 joinPath 拼的绝对路径；不能直接按字符串 key 查，
    // 否则混合分隔符/大小写会让诊断永远被丢弃。
    for (final entry in _documents.entries) {
      if (!samePath(entry.key, report.path)) continue;
      final doc = entry.value;
      return doc.text == text &&
          (report.version == null || report.version == doc.version);
    }
    return false;
  }

  Future<List<LspCompletionItem>> completion(
    String path,
    String text,
    int offset,
  ) async {
    if (!ready ||
        !path.endsWith('.dart') ||
        offset < 0 ||
        offset > text.length) {
      return const [];
    }
    final generation = _generation;
    try {
      await updateDocument(path, text);
      if (!ready || generation != _generation) return const [];
      final pos = LspProtocol.offsetToPosition(text, offset);
      final response = await _request('textDocument/completion', {
        'textDocument': {'uri': LspProtocol.fileUri(path)},
        'position': {'line': pos.$1, 'character': pos.$2},
      });
      if (response == null || generation != _generation) return const [];
      return LspCompletionItem.parseList(jsonEncode(response), document: text);
    } catch (_) {
      return const [];
    }
  }

  Future<LspCompletionItem> resolve(
    LspCompletionItem item,
    String document,
  ) async {
    if (!_resolveSupported || !ready) return item;
    final generation = _generation;
    try {
      final result = await _request('completionItem/resolve', item.raw);
      if (generation == _generation &&
          result?['result'] is Map<String, dynamic>) {
        return LspCompletionItem.fromJson({
          ...item.raw,
          ...result!['result'] as Map<String, dynamic>,
        }, document: document);
      }
    } catch (_) {
      /* The original item remains usable. */
    }
    return item;
  }

  Future<SignatureHelp?> signature(String path, String text, int offset) async {
    if (!ready ||
        !path.endsWith('.dart') ||
        offset < 0 ||
        offset > text.length) {
      return null;
    }
    final generation = _generation;
    try {
      await updateDocument(path, text);
      if (generation != _generation || !ready) return null;
      final pos = LspProtocol.offsetToPosition(text, offset);
      final result = await _request('textDocument/signatureHelp', {
        'textDocument': {'uri': LspProtocol.fileUri(path)},
        'position': {'line': pos.$1, 'character': pos.$2},
      });
      return generation == _generation
          ? SignatureHelp.parse(result?['result'])
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> stop() async {
    _generation = ++_nextGeneration;
    state.value = LanguageServiceState.stopped;
    _documents.clear();
    _documentQueue = Future.value();
    _resolveSupported = false;
    _root = null;
    await FlitLsp.stop();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    await _starting;
    await _subscription?.cancel();
    await _diagCtrl.close();
    state.dispose();
  }

  /// 快速修复: 对诊断区间请求 codeAction, 只保留作用于本文档的文本编辑
  Future<List<LspCodeAction>> codeActions(
    String path,
    String text,
    int startLine,
    int startChar,
    int endLine,
    int endChar,
  ) async {
    if (!ready || !path.endsWith('.dart')) return const [];
    final generation = _generation;
    try {
      await updateDocument(path, text);
      if (!ready || generation != _generation) return const [];
      final result = await _request('textDocument/codeAction', {
        'textDocument': {'uri': LspProtocol.fileUri(path)},
        'range': {
          'start': {'line': startLine, 'character': startChar},
          'end': {'line': endLine, 'character': endChar},
        },
        'context': {'diagnostics': []},
      });
      if (generation != _generation) return const [];
      return LspCodeAction.parse(result?['result'], path);
    } catch (_) {
      return const [];
    }
  }
}
