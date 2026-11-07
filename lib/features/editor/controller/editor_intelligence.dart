import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../services/paths.dart';
import '../completion/completion_engine.dart';
import '../lsp/lsp_client.dart';
import '../lsp/protocol.dart';
import 'code_controller.dart';

/// Language features for one visible document. No routes, layout or focus nodes.
class EditorIntelligence extends ChangeNotifier {
  EditorIntelligence({
    required this.path,
    required this.code,
    required this.language,
  }) {
    _value = code.value;
    code.addListener(_onValue);
    language.state.addListener(_onLanguageState);
    _diagnosticsSubscription = language.diagnostics.listen((report) {
      if (!samePath(report.path, path) ||
          !language.acceptsDiagnostics(report, code.text)) {
        return;
      }
      diagnostics = report.items;
      code.setDiagnostics(diagnostics);
      notifyListeners();
    });
    _sync();
  }

  final String path;
  final CodeController code;
  final LspClient language;
  late TextEditingValue _value;
  late final StreamSubscription<DiagnosticsReport> _diagnosticsSubscription;
  Timer? _syncTimer, _completionTimer;
  int _request = 0;
  bool _disposed = false, _focused = false;
  List<CompletionItem> suggestions = const [];
  List<EditorDiagnostic> diagnostics = const [];
  SignatureHelp? signature;
  int selected = 0;

  bool get canSuggest =>
      _focused &&
      code.selection.isValid &&
      code.selection.isCollapsed &&
      code.value.composing.isCollapsed;

  void setFocused(bool focused) {
    _focused = focused;
    if (!focused) dismiss();
  }

  void _onLanguageState() {
    if (language.ready) {
      _sync();
    } else {
      diagnostics = const [];
      code.setDiagnostics(diagnostics);
      dismiss();
    }
    notifyListeners();
  }

  Future<void> _sync() async {
    try {
      await language.updateDocument(path, code.text);
    } catch (_) {
      // Local editing remains available when the language server is unavailable.
    }
  }

  void _onValue() {
    final next = code.value;
    if (next == _value) return;
    final textChanged = next.text != _value.text;
    _value = next;
    if (textChanged) {
      diagnostics = const [];
      code.setDiagnostics(diagnostics);
      _syncTimer?.cancel();
      _syncTimer = Timer(const Duration(milliseconds: 400), _sync);
    }
    _refreshSuggestions();
  }

  void dismiss() {
    ++_request;
    _completionTimer?.cancel();
    suggestions = const [];
    signature = null;
    selected = 0;
    notifyListeners();
  }

  void moveSelection(int delta) {
    if (suggestions.isEmpty) return;
    selected = (selected + delta).clamp(0, suggestions.length - 1);
    notifyListeners();
  }

  void _refreshSuggestions() {
    final request = ++_request;
    _completionTimer?.cancel();
    selected = 0;
    signature = null;
    suggestions = canSuggest
        ? CompletionEngine.complete(
            code.text,
            code.selection.baseOffset,
            language: code.language,
          )
        : const [];
    notifyListeners();
    if (!canSuggest || !language.ready || code.language != 'dart') return;
    final value = code.value;
    final offset = value.selection.baseOffset;
    final prefix = CompletionEngine.prefixOf(value.text, offset);
    final before = value.text.substring(0, offset).trimRight();
    final wantCompletion = prefix.isNotEmpty || before.endsWith('.');
    final wantSignature =
        before.contains('(') && !before.endsWith(';') && !before.endsWith('}');
    if (!wantCompletion && !wantSignature) return;
    bool current() =>
        !_disposed && request == _request && code.value == value && canSuggest;
    _completionTimer = Timer(const Duration(milliseconds: 220), () async {
      if (!current()) return;
      if (wantCompletion) {
        final remote = [...await language.completion(path, value.text, offset)];
        if (!current()) return;
        remote.sort(
          (a, b) => (a.sortText ?? a.label).compareTo(b.sortText ?? b.label),
        );
        final seen = <String>{};
        final items = <CompletionItem>[];
        for (final item in remote) {
          final filter = (item.filterText ?? item.label).toLowerCase();
          if (prefix.isNotEmpty && !filter.startsWith(prefix.toLowerCase())) {
            continue;
          }
          if (seen.add(item.label)) items.add(CompletionItem.fromLsp(item));
        }
        for (final item in CompletionEngine.complete(
          value.text,
          offset,
          language: code.language,
        )) {
          if (seen.add(item.label)) items.add(item);
        }
        suggestions = items.take(40).toList();
        selected = suggestions.isEmpty
            ? 0
            : selected.clamp(0, suggestions.length - 1);
        notifyListeners();
      }
      if (wantSignature) {
        final result = await language.signature(path, value.text, offset);
        if (!current()) return;
        signature = result;
        notifyListeners();
      }
    });
  }

  /// False means the document/selection changed while resolving a suggestion.
  Future<bool> apply(CompletionItem item) async {
    if (!canSuggest) return false;
    final value = code.value;
    final request = ++_request;
    _completionTimer?.cancel();
    if (item.semantic != null) {
      final resolved = await language.resolve(item.semantic!, value.text);
      if (_disposed ||
          request != _request ||
          value != code.value ||
          !canSuggest) {
        return false;
      }
      item = CompletionItem.fromLsp(resolved);
    }
    final (text, offset) = CompletionEngine.apply(
      value.text,
      value.selection.baseOffset,
      item,
    );
    code.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
    );
    dismiss();
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    ++_request;
    _syncTimer?.cancel();
    _completionTimer?.cancel();
    code.removeListener(_onValue);
    language.state.removeListener(_onLanguageState);
    unawaited(_diagnosticsSubscription.cancel());
    unawaited(language.closeDocument(path).catchError((_) {}));
    super.dispose();
  }
}
