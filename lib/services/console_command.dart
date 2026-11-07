import '../core/host_platform.dart';

/// POSIX → 宿主平台命令归一的纯函数层（可单测、无 IO）。
///
/// Flit 的历史命令字符串都是给 Android 的 bash 拼的：`shQuote` 单引号、
/// `mkdir -p && cd`、`VAR=val cmd` 前缀、`</dev/null`、`source env.sh`。
/// 桌面端不能把这些原样丢给 cmd.exe/sh，所以这里做「最小必要翻译」：
/// - Android：原样返回（Android 仍然需要 bash 包装）；
/// - Linux/macOS 桌面：去掉 Android 专属的 env.sh source 与 /dev/null 重定向；
/// - Windows：把 `mkdir -p`/`cd` 前缀翻译成 cmd 写法，把 POSIX 单引号参数
///   换成 cmd 双引号（并转义 `%`/`!`/内层 `"`），`;` → `&`，多行 → `&` 链。
///
/// 注意这里只保证「形状可执行」：真正的参数应该走 Dart 的 Process/argv
/// （见各调用方的桌面分支），不要用本函数给 Git/Flutter 拼参数。

/// 把一个 argv 值转成可以安全放进 cmd.exe 命令行的单个参数。
///
/// 双引号内部 `& | < > ^` 已失去 cmd 语法意义（无需转义）；需要处理的是
/// 会先于引号解析的 `%` 与延迟展开的 `!`，以及内层 `"`（用 `\"`，交给
/// 子进程的 CommandLineToArgvW 还原）。
String quoteForCmd(String value) {
  final buffer = StringBuffer('"');
  for (var i = 0; i < value.length; i++) {
    final ch = value[i];
    switch (ch) {
      case '"':
        buffer.write(r'\"');
      case '%':
        buffer.write('^%');
      case '!':
        buffer.write('^!');
      default:
        buffer.write(ch);
    }
  }
  buffer.write('"');
  return buffer.toString();
}

/// 未加引号的裸 token：cmd 元字符逐个 `^` 转义（路径/描述优先用 [quoteForCmd]）。
String escapeCmdToken(String value) {
  const special = r'&|<>^()%!"';
  final buffer = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final ch = value[i];
    if (special.contains(ch)) buffer.write('^');
    buffer.write(ch);
  }
  return buffer.toString();
}

/// 归一一条要交给宿主 shell 执行的命令字符串。
String normalizeConsoleCommand(
  String command, {
  required HostPlatform platform,
}) {
  if (platform == HostPlatform.android) return command;
  var c = command.trim();
  if (c.isEmpty) return c;
  // 桌面端没有 android_build.sh 这层 bash 包装。
  c = c.replaceFirst(RegExp(r'^bash\s+"[^"]*android_build\.sh"\s+'), '');
  if (platform == HostPlatform.windows) return _normalizeForCmd(c);
  return _normalizeForPosix(c);
}

String _normalizeForPosix(String command) {
  var c = command.replaceFirst(
    RegExp(
      r'''^if \[ -f "\$HOME/\.flit/env\.sh" \]; then \. "\$HOME/\.flit/env\.sh" \|\| exit \$\?; fi;\s*''',
    ),
    '',
  );
  c = c.replaceAll(RegExp(r'\s*</dev/null'), '');
  return c.trim();
}

String _normalizeForCmd(String command) {
  var c = command;
  // cmd 没有 /dev/null：重定向直接去掉；stty 是 PTY 概念，桌面不需要。
  c = c.replaceAll(RegExp(r'\s*</dev/null'), '');
  c = c.replaceAll(RegExp(r'\bstty\s+-echo\s*;?'), '');
  // cmd /c 不把换行当命令分隔符：多行脚本按行用 & 串起来。
  if (c.contains('\n')) {
    c = c
        .split('\n')
        .map((line) => _stripLinePrefix(line.trim()))
        .where((line) => line.isNotEmpty)
        .join(' & ');
  }
  // POSIX 的 `;` 链在 cmd 里是 `&`（引号内的分号是字面量，不能动）。
  c = _replaceOutsideQuotes(c, ';', ' & ');
  c = _rewriteDirectoryPrefix(c);
  c = _convertSingleQuotes(c);
  c = _collapseSpacesOutsideQuotes(c);
  return c.trim();
}

/// 去掉多行脚本里行首的注释符/续行符，避免 `# comment` 被当成命令。
String _stripLinePrefix(String line) {
  var s = line.trim();
  if (s.startsWith('#')) return '';
  while (s.endsWith(r'\')) {
    s = s.substring(0, s.length - 1).trimRight();
  }
  return s;
}

/// `mkdir -p 'X' && cd 'X' && rest` / `mkdir -p 'X' && rest` / `cd 'X' && rest`
/// → cmd 等价写法。目录已由 Dart 建好时调用方不需要这个前缀。
String _rewriteDirectoryPrefix(String command) {
  final withMkdir = RegExp(
    r"""^mkdir\s+-p\s+'([^']*)'\s*&&\s*(?:cd\s+'([^']*)'\s*&&\s*)?([\s\S]+)$""",
  ).firstMatch(command);
  if (withMkdir != null) {
    final created = quoteForCmd(withMkdir.group(1)!);
    final rest = withMkdir.group(3)!;
    final cdTo = withMkdir.group(2);
    if (cdTo == null) {
      return 'if not exist $created mkdir $created && $rest';
    }
    return 'if not exist $created mkdir $created & '
        'cd /d ${quoteForCmd(cdTo)} && $rest';
  }
  final cdOnly = RegExp(
    r"""^cd\s+'([^']*)'\s*&&\s*([\s\S]+)$""",
  ).firstMatch(command);
  if (cdOnly != null) {
    return 'cd /d ${quoteForCmd(cdOnly.group(1)!)} && ${cdOnly.group(2)!}';
  }
  return command;
}

/// 把 POSIX 单引号参数换成 cmd 双引号参数。
///
/// 支持 `shQuote` 对单引号本身的编码 `'\''`（→ 字面 `'`）；
/// 未闭合的引号原样保留，避免把半截命令改坏。
String _convertSingleQuotes(String command) {
  final out = StringBuffer();
  var i = 0;
  while (i < command.length) {
    if (command[i] != "'") {
      out.write(command[i]);
      i++;
      continue;
    }
    i++; // 吃掉开引号
    final value = StringBuffer();
    var closed = false;
    while (i < command.length) {
      if (command[i] == "'") {
        if (command.startsWith(r"'\''", i)) {
          value.write("'");
          i += 4;
          continue;
        }
        i++; // 吃掉闭引号
        closed = true;
        break;
      }
      value.write(command[i]);
      i++;
    }
    if (!closed) {
      out.write("'$value");
      break;
    }
    out.write(quoteForCmd(value.toString()));
  }
  return out.toString();
}

/// 引号外连续空格折成一个（`;` → ` & ` 时原命令里可能已有一个空格）。
String _collapseSpacesOutsideQuotes(String input) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  var lastWasSpace = false;
  while (i < input.length) {
    final ch = input[i];
    if (quote != null) {
      // 双引号里的 `\"` 是转义出来的字面引号，不能当闭合引号。
      if (quote == '"' && ch == r'\' && i + 1 < input.length) {
        out.write(ch);
        out.write(input[i + 1]);
        i += 2;
        continue;
      }
      out.write(ch);
      if (ch == quote) quote = null;
      lastWasSpace = false;
      i++;
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
      out.write(ch);
      lastWasSpace = false;
      i++;
      continue;
    }
    if (ch == ' ') {
      if (!lastWasSpace) out.write(ch);
      lastWasSpace = true;
      i++;
      continue;
    }
    lastWasSpace = false;
    out.write(ch);
    i++;
  }
  return out.toString();
}

/// 引号外的 [needle] 替换（引号内保持字面量）。
String _replaceOutsideQuotes(String input, String needle, String replacement) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < input.length) {
    final ch = input[i];
    if (quote != null) {
      out.write(ch);
      if (ch == quote) quote = null;
      i++;
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
      out.write(ch);
      i++;
      continue;
    }
    if (input.startsWith(needle, i)) {
      out.write(replacement);
      i += needle.length;
      continue;
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}
