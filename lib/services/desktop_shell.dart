import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'desktop_toolchain.dart';
import 'local_fs.dart';

/// 桌面端的进程/系统能力实现，替代 Android 的 flit_env 原生插件。
///
/// 所有子进程都注入 [DesktopToolchain.childEnvironment]：
/// 私有 JDK / Flutter / Android SDK 永远优先于系统里装的东西，
/// 用户机器不需要预先配任何环境变量。
class DesktopShell {
  DesktopShell({DesktopToolchain? toolchain})
    : toolchain = toolchain ?? DesktopToolchain();

  final DesktopToolchain toolchain;

  static final DesktopShell instance = DesktopShell();

  /// 等价于 Android 侧的 bootstrapStatus()。
  Map<String, dynamic> bootstrapStatus() => <String, dynamic>{
    'home': toolchain.home,
    'prefix': toolchain.home,
    'bootstrapped': true,
    'platform': Platform.operatingSystem,
  };

  /// 执行一条命令：桌面端走系统 shell（Windows 用 cmd /c），并注入隔离环境。
  Future<Map<String, dynamic>> exec(
    String cmd, {
    int timeoutMs = 120000,
  }) async {
    final shimmed = await _posixShim(cmd);
    if (shimmed != null) return shimmed;
    final shell = Platform.isWindows
        ? <String>['cmd.exe', '/c', cmd]
        : <String>['/bin/sh', '-c', cmd];
    try {
      final r = await Process.run(
        shell.first,
        shell.sublist(1),
        environment: toolchain.childEnvironment,
        stdoutEncoding: const SystemEncoding(),
        stderrEncoding: const SystemEncoding(),
        runInShell: false,
      ).timeout(Duration(milliseconds: timeoutMs));
      final out = '${r.stdout}${r.stderr}';
      return <String, dynamic>{'exitCode': r.exitCode, 'output': out};
    } on TimeoutException catch (_) {
      return <String, dynamic>{
        'exitCode': 124,
        'output': '命令超时(${timeoutMs}ms): $cmd',
      };
    } catch (e) {
      return <String, dynamic>{'exitCode': -1, 'output': '$e'};
    }
  }

  /// PATH / 私有工具链里是否有这个可执行文件（替代 `command -v`）。
  bool hasBinary(String name) {
    if (_searchIn(toolchain.sdkDir, name) != null) return true;
    if (_searchIn(toolchain.jdkDir, name) != null) return true;
    if (_searchIn(toolchain.flutterDir, name) != null) return true;
    final path =
        Platform.environment[Platform.isWindows ? 'Path' : 'PATH'] ?? '';
    final sep = Platform.isWindows ? ';' : ':';
    for (final dir in path.split(sep)) {
      if (dir.trim().isEmpty) continue;
      if (_existsBinary(dir, name)) return true;
    }
    return false;
  }

  /// 找可执行文件绝对路径（找不到返回 null）。
  String? which(String name) {
    final direct =
        _searchIn(toolchain.sdkDir, name) ??
        _searchIn(toolchain.flutterDir, name) ??
        _searchIn(toolchain.jdkDir, name);
    if (direct != null) return direct;
    final path =
        Platform.environment[Platform.isWindows ? 'Path' : 'PATH'] ?? '';
    final sep = Platform.isWindows ? ';' : ':';
    for (final dir in path.split(sep)) {
      if (dir.trim().isEmpty) continue;
      final hit = _existsBinary(dir, name);
      if (hit)
        return _join(dir, name) +
            (Platform.isWindows && !name.contains('.') ? '.exe' : '');
    }
    return null;
  }

  bool _existsBinary(String dir, String name) {
    if (Platform.isWindows) {
      for (final ext in <String>['.exe', '.bat', '.cmd', '']) {
        if (File(_join(dir, '$name$ext')).existsSync()) return true;
      }
      return false;
    }
    return File(_join(dir, name)).existsSync();
  }

  String? _searchIn(String root, String name) {
    final dir = Directory(root);
    if (!dir.existsSync()) return null;
    try {
      for (final e in dir.listSync(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final leaf = e.path.split(Platform.pathSeparator).last;
        final lower = leaf.toLowerCase();
        if (Platform.isWindows) {
          if (lower == '$name.exe' ||
              lower == '$name.bat' ||
              lower == '$name.cmd')
            return e.path;
        } else if (leaf == name) {
          return e.path;
        }
      }
    } catch (_) {}
    return null;
  }

  String _join(String a, String b) => a.endsWith(Platform.pathSeparator)
      ? '$a$b'
      : '$a${Platform.pathSeparator}$b';

  /// SHA-256：Windows 用 certutil，类 Unix 用 sha256sum。
  Future<String> sha256OfFile(String path) async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('certutil.exe', <String>[
          '-hashfile',
          path,
          'SHA256',
        ]);
        final lines = '${r.stdout}'.split('\n').map((l) => l.trim()).toList();
        for (final l in lines) {
          if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(l)) return l.toLowerCase();
        }
        return '';
      }
      final r = await Process.run('sha256sum', <String>[path]);
      final first = '${r.stdout}'.split('\n').first.trim();
      return first.split(' ').first;
    } catch (_) {
      return '';
    }
  }

  /// 用系统默认程序打开 URL。
  Future<bool> openUrl(String url) async {
    try {
      if (Platform.isWindows) {
        await Process.run('cmd.exe', <String>['/c', 'start', '', url]);
      } else if (Platform.isMacOS) {
        await Process.run('open', <String>[url]);
      } else {
        await Process.run('xdg-open', <String>[url]);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 打开系统设置页：桌面端无对应概念。
  Future<bool> openSettings(String action) async => false;

  /// 在文件管理器中显示目录。
  Future<bool> revealDirectory(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', <String>[path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', <String>[path]);
      } else {
        await Process.run('xdg-open', <String>[path]);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 读取环境变量（替代 `env -0`）。
  Map<String, String> environment() =>
      Map<String, String>.from(toolchain.childEnvironment);

  /// 让 Dart 侧知道当前编码（终端输出用）。
  static String decode(List<int> bytes) =>
      utf8.decode(bytes, allowMalformed: true);
  // ---------- POSIX 命令兼容层 ----------
  //
  // Flit 原本假设有 bash：command -v / [ -e ] / cat / env -0 / find -printf。
  // Windows 没有这些内置命令，这里把「简单惯用法」翻译成 Dart 实现；
  // 复杂脚本（file_ops 的 realpath 门禁、编辑器读写）在调用方直接走 Dart 分支。

  Future<Map<String, dynamic>?> _posixShim(String cmd) async {
    final c = cmd.trim();

    // command -v X >/dev/null 2>&1 || exit 127; X --version
    if (c.contains('command -v ')) {
      final name = c
          .split('command -v ')
          .last
          .split(RegExp(r'[\s>]'))
          .first
          .trim();
      if (!hasBinary(name)) {
        return <String, dynamic>{'exitCode': 127, 'output': ''};
      }
      final path = which(name) ?? name;
      final rest = c.split(';').last.trim();
      if (rest.startsWith(name) && rest.endsWith('--version')) {
        return await _runSimple(name, const <String>['--version']);
      }
      return <String, dynamic>{'exitCode': 0, 'output': path};
    }

    // env -0
    if (c == 'env -0') {
      final env = environment();
      final buf = StringBuffer();
      env.forEach((k, v) => buf.write('$k=$v\u0000'));
      return <String, dynamic>{'exitCode': 0, 'output': buf.toString()};
    }

    // [ -e 'P' ] || [ -L 'P' ]
    final existTest = RegExp(r"^\[ -e '(.+?)' \] \|\| \[ -L '(.+?)' \]$")
        .firstMatch(c);
    if (existTest != null) {
      final p1 = existTest.group(1)!;
      return <String, dynamic>{
        'exitCode': LocalFs.instance.exists(p1) ? 0 : 1,
        'output': '',
      };
    }

    // [ -f 'P' ] && echo RESOLVED
    final fileTest = RegExp(r"^\[ -f '(.+?)' \] && echo RESOLVED$")
        .firstMatch(c);
    if (fileTest != null) {
      final p1 = fileTest.group(1)!;
      final ok = LocalFs.instance.isFile(p1);
      return <String, dynamic>{
        'exitCode': ok ? 0 : 1,
        'output': ok ? 'RESOLVED' : '',
      };
    }

    // cat 'P' 2>/dev/null
    final catMatch = RegExp(r"^cat '(.+?)'( 2>/dev/null)?$").firstMatch(c);
    if (catMatch != null) {
      final p1 = catMatch.group(1)!;
      if (!LocalFs.instance.isFile(p1)) {
        return <String, dynamic>{'exitCode': 1, 'output': ''};
      }
      return <String, dynamic>{
        'exitCode': 0,
        'output': LocalFs.instance.readText(p1),
      };
    }

    // 工程列表扫描：find . -mindepth 1 -maxdepth 1 -type d ... printf
    if (c.contains('-maxdepth 1') &&
        c.contains('-type d') &&
        c.contains("printf '%s\\t%s\\t%s\\n'")) {
      final quoted = _singleQuoted(c);
      final root = quoted.isNotEmpty ? quoted.first : toolchain.projectsDir;
      final probes = LocalFs.instance.scanProjects(root);
      final sb = StringBuffer();
      for (final p in probes) {
        final kind = p.isFlutter
            ? 'flutter'
            : (p.hasPubspec ? 'dart' : 'folder');
        final mtime = p.newestMillis == null
            ? ''
            : (p.newestMillis! ~/ 1000).toString();
        sb.write('${p.name}\t$kind\t$mtime\n');
      }
      return <String, dynamic>{'exitCode': 0, 'output': sb.toString()};
    }

    // 文件树：set -o pipefail; cd 'ROOT' && find . ... -printf
    if (c.contains('-mindepth 1') && c.contains("-type d -printf '%P/\\n'")) {
      final quoted = _singleQuoted(c);
      final root = quoted.isNotEmpty ? quoted.first : '';
      if (root.isEmpty) return <String, dynamic>{'exitCode': 2, 'output': ''};
      final lines = LocalFs.instance.listTree(root);
      return <String, dynamic>{'exitCode': 0, 'output': lines.join('\n')};
    }

    return null;
  }

  List<String> _singleQuoted(String s) {
    final out = <String>[];
    final re = RegExp(r"'([^']*)'");
    for (final m in re.allMatches(s)) {
      out.add(m.group(1)!);
    }
    return out;
  }

  Future<Map<String, dynamic>> _runSimple(String exe, List<String> args) async {
    try {
      final r = await Process.run(
        exe,
        args,
        environment: toolchain.childEnvironment,
      );
      return <String, dynamic>{
        'exitCode': r.exitCode,
        'output': '${r.stdout}${r.stderr}',
      };
    } catch (e) {
      return <String, dynamic>{'exitCode': -1, 'output': '$e'};
    }
  }
}
