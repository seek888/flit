import 'dart:io';

import '../core/host_platform.dart';

/// 跨平台路径工具（纯 Dart，可单测）。
///
/// Flit 里工程内路径统一用 `/` 作为相对路径分隔符（文件树/清单协议），
/// 绝对路径则跟随宿主分隔符。所有拼接/取名/比较都必须经过这里，
/// 不能在业务代码里手写 `split('/')` 或 `'$root/$rel'`：
/// Windows 的绝对路径是 `C:\a\b`，`split('/')` 会返回整条路径。

/// 把 `\` 统一成 `/`（只用于比较/取名，不用于真实文件操作）。
String normalizeSeparators(String path) => path.replaceAll('\\', '/');

/// 去掉末尾分隔符（`/` 与其在数据根保留）。
String _trimTrailingSeparators(String path) {
  var s = path;
  while (s.length > 1 &&
      (s.endsWith('/') || s.endsWith(r'\')) &&
      !(s.length == 3 && s[1] == ':')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// 路径的最后一段（文件名或目录名），忽略末尾分隔符。
///
/// `baseName('C:\a\b') == 'b'`，`baseName('C:/a/b/') == 'b'`，
/// `baseName('/') == ''`，`baseName('') == ''`。
String baseName(String path) {
  final norm = _trimTrailingSeparators(normalizeSeparators(path));
  final index = norm.lastIndexOf('/');
  return index >= 0 ? norm.substring(index + 1) : norm;
}

/// 路径的父目录（保留原分隔符风格）；没有父目录时返回空串。
String dirName(String path) {
  final trimmed = _trimTrailingSeparators(path);
  final forward = trimmed.lastIndexOf('/');
  final backward = trimmed.lastIndexOf(r'\');
  final index = forward > backward ? forward : backward;
  if (index <= 0) return '';
  // 形如 `C:` 的盘符根: `C:\a` 的父目录是 `C:\`。
  if (index == 2 && trimmed[1] == ':') return trimmed.substring(0, 3);
  return trimmed.substring(0, index);
}

/// 把相对路径 [rel] 拼到根 [root] 上，使用宿主分隔符。
///
/// [rel] 里混用的 `/`、`\`、重复分隔符都会被归一；绝对路径原样返回。
String joinPath(String root, String rel) {
  final sep = Platform.pathSeparator;
  final cleaned = rel
      .replaceAll(RegExp(r'[\\/]+'), sep)
      .replaceFirst(RegExp('^${RegExp.escape(sep)}+'), '');
  if (cleaned.isEmpty) return root;
  if (rel.startsWith('/') || rel.startsWith(r'\') || _isDriveAbsolute(rel)) {
    return rel.replaceAll(RegExp(r'[\\/]+'), sep);
  }
  if (root.isEmpty) return cleaned;
  final trimmedRoot = _trimTrailingSeparators(root);
  // Windows 盘符根 `C:` / `C:\` 后面必须补分隔符。
  if (trimmedRoot.endsWith(':')) return '$trimmedRoot$sep$cleaned';
  return '$trimmedRoot$sep$cleaned';
}

bool _isDriveAbsolute(String path) =>
    path.length >= 3 && path[1] == ':' && (path[2] == '/' || path[2] == r'\');

/// [path] 是否严格位于 [root] 之内；是则返回归一后的相对路径（`/` 分隔），
/// 否则返回 null。比较时统一分隔符，Windows/macOS 忽略大小写。
///
/// 与 `path.startsWith('$root/')` 的区别：后者在 Windows 上永远不成立
/// （或者被混合分隔符欺骗），并且在大小写不敏感文件系统上会误判。
String? relativeInside(String root, String path) {
  final normalizedRoot = _trimTrailingSeparators(normalizeSeparators(root));
  var normalizedPath = normalizeSeparators(path);
  // 归一重复分隔符，避免 `C:\a\\b` 这类输入漏判。
  normalizedPath = normalizedPath.replaceAll(RegExp('/+'), '/');
  final rootCmp = _comparable(normalizedRoot);
  final pathCmp = _comparable(normalizedPath);
  if (pathCmp == rootCmp) return null;
  final prefix = rootCmp.endsWith('/') ? rootCmp : '$rootCmp/';
  if (!pathCmp.startsWith(prefix)) return null;
  return normalizedPath.substring(normalizedRoot.length + 1);
}

/// 两个路径是否指向同一位置（仅按字符串语义；需要真实路径时用 LocalFs.same）。
bool samePath(String a, String b) {
  if (a.isEmpty || b.isEmpty) return a.isEmpty && b.isEmpty;
  return _comparable(_collapse(normalizeSeparators(a))) ==
      _comparable(_collapse(normalizeSeparators(b)));
}

String _comparable(String path) =>
    hostPlatform.isCaseInsensitiveFs ? path.toLowerCase() : path;

/// 词法折叠 `.` / `..`，并去掉重复分隔符与末尾分隔符。
String _collapse(String path) {
  final absolute = path.startsWith('/');
  final parts = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty && parts.last != '..') {
        parts.removeLast();
      } else if (!absolute) {
        parts.add('..');
      }
      continue;
    }
    parts.add(part);
  }
  final joined = parts.join('/');
  if (absolute) return '/$joined';
  return joined;
}
