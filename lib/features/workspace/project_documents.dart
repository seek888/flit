import 'package:flit/l10n/strings.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../../services/local_fs.dart';
import '../../services/paths.dart';
import '../../services/shell.dart';
import '../editor/controller/code_controller.dart';
import '../editor/highlighting/highlighter.dart';

typedef DocumentRead = Future<String?> Function(String path);
typedef DocumentWrite = Future<bool> Function(String path, String text);

class EditorDocument {
  EditorDocument(this.path, String text)
    : controller = CodeController(
        text: text,
        language: CodeHighlighter.languageOf(path),
      ),
      savedText = text,
      _observedText = text;
  String path;
  final CodeController controller;
  String savedText;
  String _observedText;
  bool get dirty => controller.text != savedText;
  bool saving = false;
  bool saveFailed = false;
  bool externalChange = false;
}

/// Project-owned buffers, undo/selection and serialized saves survive page changes.
class ProjectDocuments extends ChangeNotifier {
  ProjectDocuments(
    this.projectPath, {
    DocumentRead? read,
    DocumentWrite? write,
  }) {
    _read = read ?? _readFile;
    _write = write ?? _writeFile;
  }
  final String projectPath;
  late final DocumentRead _read;
  late final DocumentWrite _write;
  final _documents = <String, EditorDocument>{};
  EditorDocument? current;
  Timer? _autoSave;
  DateTime _lastSavedAt = DateTime.now();
  Future<bool>? _saving;
  int _openSequence = 0;
  bool _closed = false;
  bool synchronizing = false;
  bool get saving => _documents.values.any((doc) => doc.saving);
  bool get saveFailed => _documents.values.any((doc) => doc.saveFailed);
  bool get dirty => _documents.values.any((doc) => doc.dirty);
  bool contains(EditorDocument document) => _documents.containsValue(document);
  String? get conflictPath {
    for (final doc in _documents.values) {
      if (doc.externalChange) return doc.path;
    }
    return null;
  }

  /// Explicitly discard a cached buffer after the user confirms reloading.
  Future<void> reload(String path) async {
    if (_closed || synchronizing) {
      throw StateError(strings.filesAreSyncingPleaseRetryShortly);
    }
    final doc = _documents[path];
    if (doc == null) return;
    synchronizing = true;
    ++_openSequence;
    _autoSave?.cancel();
    for (final document in _documents.values) {
      document.controller.editingLocked = true;
    }
    notifyListeners();
    var removed = false;
    try {
      await _saving;
      final text = await _read(_absolutePath(path));
      if (text == null) {
        _documents.remove(path);
        if (identical(current, doc)) current = null;
        removed = true;
      } else {
        doc.savedText = doc._observedText = text;
        doc.controller.replaceFromDisk(text);
        doc.saveFailed = doc.externalChange = false;
        current = doc;
      }
    } finally {
      synchronizing = false;
      for (final document in _documents.values) {
        document.controller.editingLocked = false;
      }
      notifyListeners();
      if (removed) {
        if (SchedulerBinding.instance.hasScheduledFrame) {
          await SchedulerBinding.instance.endOfFrame;
        }
        doc.controller.removeListener(_changed);
        doc.controller.dispose();
      }
    }
  }

  Future<String?> _readFile(String path) async {
    if (_relativePath(path) == null) throw StateError(strings.invalidFilePath);
    if (isDesktopPlatform) {
      final fs = LocalFs.instance;
      if (!fs.exists(path)) return null;
      if (!fs.isInside(projectPath, path)) {
        throw StateError(strings.fileIsUnreadableOrOutsideTheProject);
      }
      return fs.readText(path);
    }
    final result = await Shell.instance.exec(
      'root=\$(realpath -e -- ${shQuote(projectPath)}) || exit 64; '
      'if [ ! -e ${shQuote(path)} ] && [ ! -L ${shQuote(path)} ]; then exit 44; fi; '
      'file=\$(realpath -e -- ${shQuote(path)}) || exit 64; '
      r'case "$file" in "$root"/*) ;; *) exit 64;; esac; '
      r'base64 < "$file"',
    );
    if (result['exitCode'] == 44) return null;
    if (result['exitCode'] != 0) {
      throw StateError(strings.fileIsUnreadableOrOutsideTheProject);
    }
    return utf8.decode(
      base64.decode(
        (result['output'] as String? ?? '').replaceAll(RegExp(r'\s'), ''),
      ),
    );
  }

  Future<bool> _writeFile(String path, String text) async {
    final relative = _relativePath(path);
    if (relative == null) return false;
    final doc = _documents[relative]!;
    doc.externalChange = await _readFile(path) != doc.savedText;
    if (doc.externalChange) return false;
    if (isDesktopPlatform) {
      final fs = LocalFs.instance;
      if (!fs.isInside(projectPath, path) || !fs.isFile(path)) return false;
      fs.writeText(path, text);
      return true;
    }
    final encoded = base64.encode(utf8.encode(text));
    final result = await Shell.instance.exec(
      'root=\$(realpath -e -- ${shQuote(projectPath)}) || exit 64; '
      // Resolve an existing file: do not recreate deleted files or replace links.
      'file=\$(realpath -e -- ${shQuote(path)}) || exit 64; '
      r'case "$file" in "$root"/*) ;; *) exit 64;; esac; '
      r'[ -f "$file" ] || exit 64; '
      r'parent=$(dirname -- "$file"); '
      r'tmp=$(mktemp "$parent/.flit-save.XXXXXX") || exit 1; '
      "trap 'rm -f -- \"\$tmp\"' EXIT; "
      "printf %s '$encoded' | base64 -d > \"\$tmp\" && "
      r'chmod --reference="$file" "$tmp" && '
      r'mv -f -- "$tmp" "$file"',
    );
    return result['exitCode'] == 0;
  }

  /// 工程内相对路径的绝对位置（统一用宿主分隔符）。
  String _absolutePath(String relative) => joinPath(projectPath, relative);

  String? _relativePath(String absolutePath) {
    final relative = relativeInside(projectPath, absolutePath);
    if (relative == null || !_validRelativePath(relative)) return null;
    return relative;
  }

  bool _validRelativePath(String path) =>
      path.isNotEmpty &&
      !path.startsWith('/') &&
      !path.contains('\\') &&
      path
          .split('/')
          .every((part) => part.isNotEmpty && part != '.' && part != '..');

  static bool _matchesPath(String path, String root) =>
      path == root || path.startsWith('$root/');

  /// Run a filesystem rename/move and keep open buffers attached to the new
  /// paths. The caller supplies the bounded disk operation.
  Future<void> renamePath(
    String oldPath,
    String newPath, {
    required Future<void> Function() apply,
  }) async {
    if (!_validRelativePath(oldPath) || !_validRelativePath(newPath)) {
      throw StateError(strings.invalidFilePath);
    }
    final documentsToMove = _documents.values
        .where((doc) => _matchesPath(doc.path, oldPath))
        .toList();
    final pathChanges = <EditorDocument, (String, String)>{
      for (final doc in documentsToMove)
        doc: (doc.path, _replacePrefix(doc.path, oldPath, newPath)),
    };
    final mappedPaths = pathChanges.values.map((change) => change.$2).toSet();
    if (mappedPaths.length != documentsToMove.length ||
        mappedPaths.any(
          (path) =>
              _documents.containsKey(path) &&
              !documentsToMove.any((doc) => doc.path == path),
        )) {
      throw StateError(strings.aFileIsAlreadyOpenAtThe);
    }

    return withFileChange(() async {
      await apply();
      final moved = <String, EditorDocument>{};
      for (final entry in pathChanges.entries) {
        final doc = entry.key;
        final nextPath = entry.value.$2;
        doc.path = nextPath;
        doc.controller.language = CodeHighlighter.languageOf(nextPath);
        doc.controller.setDiagnostics(const []);
        moved[nextPath] = doc;
      }
      for (final previousPath in pathChanges.values.map(
        (change) => change.$1,
      )) {
        _documents.remove(previousPath);
      }
      _documents.addAll(moved);
    });
  }

  /// Delete confirmed by the caller; saving first ensures a failed filesystem
  /// operation never discards the user's only copy of an edited buffer.
  Future<void> deletePath(
    String path, {
    required Future<void> Function() apply,
  }) async {
    if (!_validRelativePath(path)) throw StateError(strings.invalidFilePath);
    final documentsToRemove = _documents.values
        .where((doc) => _matchesPath(doc.path, path))
        .toList();
    final removed = <EditorDocument>[];
    return withFileChange(() async {
      await apply();
      for (final doc in documentsToRemove) {
        _documents.remove(doc.path);
        if (identical(current, doc)) current = null;
        removed.add(doc);
      }
    }, removed: removed);
  }

  /// 关闭一个缓冲(tab ✕): 先落盘再释放; 保存失败则抛错并保留缓冲。
  Future<void> closeDocument(EditorDocument document) {
    if (!contains(document)) return Future.value();
    final removed = <EditorDocument>[];
    return withFileChange(() async {
      _documents.remove(document.path);
      if (identical(current, document)) current = null;
      removed.add(document);
    }, removed: removed);
  }

  Future<T> withFileChange<T>(
    Future<T> Function() action, {
    List<EditorDocument>? removed,
  }) async {
    if (_closed || synchronizing) {
      throw StateError(strings.filesAreSyncingPleaseRetryShortly);
    }
    final removedDocuments = removed ?? <EditorDocument>[];
    synchronizing = true;
    ++_openSequence;
    for (final doc in _documents.values) {
      doc.controller.editingLocked = true;
    }
    notifyListeners();
    try {
      if (!await _flush()) {
        throw StateError(strings.saveFailedFileOperationCancelled);
      }
      return await action();
    } finally {
      synchronizing = false;
      for (final doc in _documents.values) {
        doc.controller.editingLocked = false;
      }
      notifyListeners();
      if (removedDocuments.isNotEmpty &&
          SchedulerBinding.instance.hasScheduledFrame) {
        await SchedulerBinding.instance.endOfFrame;
      }
      for (final doc in removedDocuments) {
        doc.controller.removeListener(_changed);
        doc.controller.dispose();
      }
    }
  }

  static String _replacePrefix(
    String path,
    String oldPrefix,
    String newPrefix,
  ) => path == oldPrefix
      ? newPrefix
      : '$newPrefix${path.substring(oldPrefix.length)}';

  Future<bool> open(String path) async {
    if (synchronizing || _closed) return false;
    if (!_validRelativePath(path)) throw StateError(strings.invalidFilePath);
    final sequence = ++_openSequence;
    var document = _documents[path];
    if (document == null || !document.dirty) {
      final text = await _read(_absolutePath(path));
      if (text == null) throw StateError(strings.fileDoesNotExistP(path));
      if (_closed || sequence != _openSequence) return false;
      if (document == null) {
        document = EditorDocument(path, text);
        _documents[path] = document;
        document.controller.addListener(_changed);
      } else if (text != document.savedText) {
        document.savedText = document._observedText = text;
        document.controller.replaceFromDisk(text);
      }
    }
    if (_closed || sequence != _openSequence) return false;
    current = document;
    notifyListeners();
    return true;
  }

  void _changed() {
    if (_closed || synchronizing) return;
    var textChanged = false;
    for (final document in _documents.values) {
      final text = document.controller.text;
      if (text != document._observedText) {
        document._observedText = text;
        if (!document.dirty) {
          document.saveFailed = false;
          document.externalChange = false;
        }
        textChanged = true;
      }
    }
    // Selection/composition/diagnostic changes do not postpone pending saves.
    if (!textChanged) return;
    _autoSave?.cancel();
    if (!_documents.values.any((doc) => doc.dirty)) {
      notifyListeners();
      return;
    }
    if (DateTime.now().difference(_lastSavedAt) >= const Duration(seconds: 3)) {
      unawaited(saveAll());
    } else {
      _autoSave = Timer(const Duration(seconds: 1), saveAll);
    }
    notifyListeners();
  }

  Future<bool> saveAll() {
    if (synchronizing) return Future.value(false);
    return _flush();
  }

  Future<bool> _flush() {
    if (_closed) return Future.value(true);
    _autoSave?.cancel();
    _autoSave = null;
    return _saving ??= _saveDirty().whenComplete(() => _saving = null);
  }

  Future<bool> _saveDirty() async {
    // If edits arrive during a write, save the new snapshot before completing.
    while (true) {
      final dirty = _documents.values.where((doc) => doc.dirty).toList();
      if (dirty.isEmpty) return true;
      for (final doc in dirty) {
        final text = doc.controller.text;
        _lastSavedAt = DateTime.now();
        doc.saving = true;
        doc.saveFailed = false;
        notifyListeners();
        var saved = false;
        try {
          saved = await _write(_absolutePath(doc.path), text);
        } catch (_) {
          saved = false;
        } finally {
          doc.saving = false;
        }
        if (!saved) {
          doc.saveFailed = doc.dirty;
          notifyListeners();
          return false;
        }
        doc.savedText = text;
        doc.saveFailed = false;
        if (!_closed) notifyListeners();
      }
    }
  }

  /// Serialize external worktree writes against editor saves and edits.
  Future<T> changeOnDisk<T>(Future<T> Function() action) async {
    final removed = <EditorDocument>[];
    return withFileChange(() async {
      try {
        return await action();
      } finally {
        // Even an interrupted Git command may have changed some files.
        String? readError;
        for (final doc in _documents.values.toList()) {
          String? text;
          try {
            text = await _read(_absolutePath(doc.path));
          } catch (_) {
            readError = strings.unableToReloadPTheFileWas(doc.path);
            // A saved buffer that cannot be reread must not overwrite the disk.
            text = null;
          }
          if (text == null) {
            _documents.remove(doc.path);
            if (identical(current, doc)) current = null;
            removed.add(doc);
          } else if (text != doc.controller.text) {
            doc.savedText = doc._observedText = text;
            doc.controller.replaceFromDisk(text);
          }
        }
        if (readError != null) throw StateError(readError);
      }
    }, removed: removed);
  }

  Future<void> close() async {
    _autoSave?.cancel();
    ++_openSequence;
    await _saving;
    _autoSave?.cancel();
    _closed = true;
    current = null;
    notifyListeners();
    if (SchedulerBinding.instance.hasScheduledFrame) {
      await SchedulerBinding.instance.endOfFrame;
    }
    for (final doc in _documents.values) {
      doc.controller.removeListener(_changed);
      doc.controller.dispose();
    }
    _documents.clear();
    super.dispose();
  }
}
