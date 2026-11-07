import 'dart:io';

import '../../services/paths.dart';
import '../../services/shell.dart';

/// 文件在编辑器里的打开方式: 代码(文本编辑器) / 图片(预览卡) / 二进制(文件卡)。
enum FileKind { code, image, binary }

const _imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

/// 明确不是文本的: 只这一小张黑名单, 其余都按文本尝试(白名单漏得太多,
/// .kt/.toml/.arb 这类曾被当成二进制拒开)
const _binaryExtensions = {
  'apk', 'aab', 'jar', 'aar', 'so', 'a', 'o', 'dex', 'class', 'dill', //
  'snapshot', 'zip', '7z', 'rar', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'zst',
  'ttf', 'otf', 'woff', 'woff2', 'pdf', 'mp3', 'mp4', 'm4a', 'aac', 'ogg',
  'wav', 'flac', 'mov', 'avi', 'mkv', 'webm', 'ico', 'icns', 'psd', 'ai',
  'bin', 'dat', 'db', 'sqlite', 'keystore', 'jks', 'der', 'p12', 'pfx',
  'exe', 'dll', 'dylib', 'wasm',
};

/// 常见文本后缀直接认, 省一次嗅探
const _textExtensions = {
  'dart', 'yaml', 'yml', 'txt', 'md', 'json', 'xml', 'kt', 'kts', 'gradle', //
  'properties', 'java', 'c', 'cc', 'cpp', 'h', 'hpp', 'html', 'htm', 'css',
  'js', 'ts', 'tsx', 'jsx', 'sh', 'bash', 'lock', 'toml', 'ini', 'cfg',
  'conf', 'env', 'csv', 'tsv', 'sql', 'arb', 'plist', 'pro', 'cmake', 'iml',
  'svg', 'swift', 'm', 'mm', 'py', 'rb', 'rs', 'go', 'vue', 'bat', 'ps1',
  'gitignore', 'gitattributes', 'editorconfig', 'metadata', 'log', 'pem',
};

String _extensionOf(String path) {
  final name = baseName(path);
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

/// 只凭名字能判定的类型; 未知后缀与无后缀返回 null, 要用 [sniffCommand] 嗅探
FileKind? fileKindByName(String path) {
  final ext = _extensionOf(path);
  if (_imageExtensions.contains(ext)) return FileKind.image;
  if (_binaryExtensions.contains(ext)) return FileKind.binary;
  if (_textExtensions.contains(ext)) return FileKind.code;
  return null;
}

/// 嗅探(纯 Dart, 桌面端唯一实现): 读前 8KB, 出现 NUL 字节即二进制。
///
/// 读不出/空文件按文本处理（编辑器自己会报读不出，别把可编辑文件拒之门外）。
/// Android 仍可用下面的 shell 版；桌面端 cmd 没有 head/od/grep。
FileKind sniffFile(String absolutePath, {int sampleBytes = 8192}) {
  try {
    final file = File(absolutePath);
    if (!file.existsSync()) return FileKind.code;
    final length = file.lengthSync();
    if (length == 0) return FileKind.code;
    final raf = file.openSync();
    final List<int> bytes;
    try {
      bytes = raf.readSync(length < sampleBytes ? length : sampleBytes);
    } finally {
      raf.closeSync();
    }
    return bytes.contains(0) ? FileKind.binary : FileKind.code;
  } catch (_) {
    return FileKind.code;
  }
}

/// 嗅探(Android shell 版, 保留兼容): 前 8KB 出现 NUL 字节即二进制。
/// od 把 NUL 打成 \0, grep 按定长串找(正则里 \0 是非法回引)
String sniffCommand(String absolutePath) =>
    'head -c 8192 -- ${shQuote(absolutePath)} | od -An -c '
    r"| grep -qF '\0' && echo binary || echo text";

/// 解析嗅探输出
FileKind fileKindFromSniff(String output) =>
    output.trim().endsWith('binary') ? FileKind.binary : FileKind.code;

/// 文件卡上的动作: 分享永远第一, 格式特有动作随后。
enum FileCardAction { share, openExternal, installApk }

/// 文件卡的判断与分发: 一种格式一份动作清单, 卡片按清单渲染, 不散落条件分支。
/// - apk: 安装是主操作; 交给外部"打开"对安装包没有意义, 不提供;
/// - 其余(image/binary): 交给系统 + 分享。
List<FileCardAction> cardActions(String path) {
  if (_extensionOf(path) == 'apk') {
    return [FileCardAction.installApk, FileCardAction.share];
  }
  return [FileCardAction.share, FileCardAction.openExternal];
}

/// 编辑器内可切换渲染预览的文档格式(.md/.markdown/.svg); 其余文本为 null。
/// 仅凭后缀(这些格式嗅探必然是文本)。
String? renderableDocumentFormat(String path) {
  final ext = _extensionOf(path);
  return switch (ext) {
    'md' || 'markdown' => 'md',
    'svg' => 'svg',
    _ => null,
  };
}
