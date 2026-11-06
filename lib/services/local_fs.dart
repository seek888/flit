import 'dart:convert';
import 'dart:io';

/// 跨平台文件操作：替代原先依赖 POSIX shell（find -printf / realpath / base64）的实现。
///
/// Android 侧仍可复用（语义一致），桌面端是唯一实现路径。
class LocalFs {
  LocalFs._();

  static final LocalFs instance = LocalFs._();

  static bool get _caseInsensitive => Platform.isWindows || Platform.isMacOS;

  /// 规范化路径：存在则解析符号链接；不存在则解析父目录后拼末段。
  String canonical(String path) {
    final normalized = _normalize(path);
    try {
      final type = FileSystemEntity.typeSync(normalized, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        return _normalize(File(normalized).resolveSymbolicLinksSync());
      }
    } catch (_) {}
    try {
      final parent = File(normalized).parent.path;
      final parentReal = File(parent).resolveSymbolicLinksSync();
      final leaf = _leaf(normalized);
      return _join(parentReal, leaf);
    } catch (_) {}
    return normalized;
  }

  /// path 是否严格位于 root 之内（不含 root 自身）。
  bool isInside(String root, String path) {
    final r = _cmp(canonical(root));
    final p = _cmp(canonical(path));
    if (p == r) return false;
    return p.startsWith('$r${Platform.pathSeparator}');
  }

  /// 等价于 `[ -e p ] || [ -L p ]`。
  bool exists(String path) {
    try {
      return FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.notFound;
    } catch (_) {
      return false;
    }
  }

  bool isDir(String path) => FileSystemEntity.isDirectorySync(path);

  bool isFile(String path) => FileSystemEntity.isFileSync(path);

  String readText(String path) {
    try {
      final bytes = File(path).readAsBytesSync();
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  /// 原子写：先写临时文件再改名，避免半截文件。
  void writeText(String path, String content) {
    final target = File(path);
    target.parent.createSync(recursive: true);
    final tmp = File('${path}.tmp-${DateTime.now().microsecondsSinceEpoch}');
    tmp.writeAsStringSync(content);
    try {
      if (target.existsSync()) target.deleteSync();
      tmp.renameSync(path);
    } catch (_) {
      if (target.existsSync()) target.deleteSync();
      tmp.renameSync(path);
    }
  }

  /// 写二进制（编辑器里 base64 落盘那条路径用）。
  void writeBytes(String path, List<int> bytes) {
    final target = File(path);
    target.parent.createSync(recursive: true);
    target.writeAsBytesSync(bytes);
  }

  void remove(String path) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      Directory(path).deleteSync(recursive: true);
    } else if (type != FileSystemEntityType.notFound) {
      File(path).deleteSync();
    }
  }

  void rename(String from, String to) => File(from).renameSync(to);

  void copy(String from, String to) {
    final type = FileSystemEntity.typeSync(from, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      _copyDir(Directory(from), Directory(to));
    } else {
      final target = File(to);
      target.parent.createSync(recursive: true);
      target.writeAsBytesSync(File(from).readAsBytesSync());
    }
  }

  void _copyDir(Directory src, Directory dst) {
    dst.createSync(recursive: true);
    for (final e in src.listSync(followLinks: false)) {
      final name = _leaf(e.path);
      if (e is Directory) {
        _copyDir(e, Directory(_join(dst.path, name)));
      } else if (e is File) {
        File(_join(dst.path, name))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(e.readAsBytesSync());
      }
    }
  }

  /// 递归目录体积（替代 `du -sb`）。
  int dirSize(String path) {
    var total = 0;
    final root = Directory(path);
    if (!root.existsSync()) return 0;
    try {
      for (final e in root.listSync(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += e.lengthSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// 工程列表扫描（替代 project_list 的 find -printf 脚本）。
  /// 返回 name -> (isFlutter, newestMtimeMillis)
  List<ProjectProbe> scanProjects(String root) {
    final dir = Directory(root);
    final out = <ProjectProbe>[];
    if (!dir.existsSync()) return out;
    final skip = <String>{'build', '.dart_tool', '.git', '.gradle'};
    for (final e in dir.listSync(followLinks: false)) {
      if (e is! Directory) continue;
      final name = _leaf(e.path);
      if (name.startsWith('.')) continue;
      final pubspec = File(_join(e.path, 'pubspec.yaml'));
      var isFlutter = false;
      var hasPubspec = false;
      if (pubspec.existsSync()) {
        hasPubspec = true;
        final text = readText(pubspec.path);
        final re = RegExp(r'^\s*(flutter:|sdk:\s*flutter)', multiLine: true);
        isFlutter = re.hasMatch(text);
      }
      var newest = 0;
      try {
        for (final f in e.listSync(recursive: true, followLinks: false)) {
          final rel = f.path.substring(e.path.length);
          if (skip.any(
            (s) => rel.contains(
              '${Platform.pathSeparator}$s${Platform.pathSeparator}',
            ),
          )) {
            continue;
          }
          if (f is File) {
            try {
              final ms = f.lastModifiedSync().millisecondsSinceEpoch;
              if (ms > newest) newest = ms;
            } catch (_) {}
          }
        }
      } catch (_) {}
      out.add(
        ProjectProbe(
          name: name,
          path: _join(root, name),
          hasPubspec: hasPubspec,
          isFlutter: isFlutter,
          newestMillis: newest == 0 ? null : newest,
        ),
      );
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// 工程文件树（替代 find -printf 脚本）。
  /// 返回相对路径列表：目录以 '/' 结尾，跳过 build/.dart_tool/.git。
  List<String> listTree(String root) {
    final dir = Directory(root);
    if (!dir.existsSync()) return const <String>[];
    final skip = <String>{'build', '.dart_tool', '.git'};
    final out = <String>[];
    void walk(Directory d, String prefix) {
      List<FileSystemEntity> entries;
      try {
        entries = d.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      for (final e in entries) {
        final name = _leaf(e.path);
        if (name.startsWith('.')) continue;
        if (e is Directory) {
          if (skip.contains(name)) continue;
          out.add('$prefix$name/');
          walk(e, '$prefix$name/');
        } else if (e is File) {
          out.add('$prefix$name');
        }
      }
    }

    walk(dir, '');
    out.sort();
    return out;
  }

  // ---------- 内部 ----------

  String _normalize(String p) {
    var s = p.replaceAll('\\', '/');
    while (s.contains('//')) {
      s = s.replaceAll('//', '/');
    }
    if (s.length > 1 && s.endsWith('/')) s = s.substring(0, s.length - 1);
    return s.replaceAll('/', Platform.pathSeparator);
  }

  String _join(String a, String b) => a.endsWith(Platform.pathSeparator)
      ? '$a$b'
      : '$a${Platform.pathSeparator}$b';

  String _leaf(String p) {
    final norm = p.replaceAll('\\', '/');
    final i = norm.lastIndexOf('/');
    return i >= 0 ? norm.substring(i + 1) : norm;
  }

  String _cmp(String p) => _caseInsensitive ? p.toLowerCase() : p;
}

/// 工程扫描结果。
class ProjectProbe {
  const ProjectProbe({
    required this.name,
    required this.path,
    required this.hasPubspec,
    required this.isFlutter,
    required this.newestMillis,
  });

  final String name;
  final String path;
  final bool hasPubspec;
  final bool isFlutter;
  final int? newestMillis;
}
