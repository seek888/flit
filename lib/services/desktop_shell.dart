import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'desktop_toolchain.dart';
import 'local_fs.dart';
import 'toolchain/hash.dart' as toolchain_hash;

/// 桌面端的进程/系统能力实现，替代 Android 的 flit_env 原生插件。
///
/// 所有子进程都注入 [DesktopToolchain.childEnvironment]：私有 JDK / Flutter /
/// Android SDK 永远优先于系统里装的东西，用户机器不需要预先配任何环境变量。
class DesktopShell {
  DesktopShell({
    DesktopToolchain? toolchain,
    Map<String, String> Function()? proxyEnvironment,
  }) : toolchain = toolchain ?? DesktopToolchain(),
       _proxyEnvironment = proxyEnvironment;

  final DesktopToolchain toolchain;
  final Map<String, String> Function()? _proxyEnvironment;

  static final DesktopShell instance = DesktopShell();

  /// AutoProxy 接线点：应用启动后设置一次
  /// `DesktopShell.proxyEnvironment = proxy.envVars;`，之后所有子进程与
  /// `environment()` 都会带上代理变量（未设置时直连）。
  static Map<String, String> Function()? proxyEnvironment;

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
      final result = await Process.run(
        shell.first,
        shell.sublist(1),
        environment: environment(),
        stdoutEncoding: const SystemEncoding(),
        stderrEncoding: const SystemEncoding(),
        runInShell: false,
      ).timeout(Duration(milliseconds: timeoutMs));
      final out = '${result.stdout}${result.stderr}';
      return <String, dynamic>{'exitCode': result.exitCode, 'output': out};
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
  bool hasBinary(String name) => which(name) != null;

  /// 以 argv 直接运行一个已知可执行文件（`.bat/.cmd` 也走这里）。
  ///
  /// 不要把它拼成 `cmd /c "<path>" --version` 这类命令字符串：Dart 会把
  /// 传给 `cmd.exe` 的参数整体再包一层引号、内层 `"` 转义成 `\"`，cmd
  /// 于是把 `\"` 当成命令名的一部分，报「不是内部或外部命令」——新建
  /// 项目预检里的 flutter.bat 就是这样失败的。直接传 argv 时由系统
  /// 负责引用（见 [ToolchainProcessGateway] 的说明）。
  Future<Map<String, dynamic>> runBinary(
    String executable,
    List<String> arguments, {
    int timeoutMs = 120000,
    String? workingDirectory,
  }) async {
    try {
      final result = await toolchain.process.run(
        executable,
        arguments,
        environment: environment(),
        timeout: Duration(milliseconds: timeoutMs),
        workingDirectory: workingDirectory,
      );
      return <String, dynamic>{
        'exitCode': result.exitCode,
        'output': '${result.stdout}${result.stderr}',
      };
    } on ToolchainException catch (error) {
      return <String, dynamic>{'exitCode': -1, 'output': error.message};
    } catch (error) {
      return <String, dynamic>{'exitCode': -1, 'output': '$error'};
    }
  }

  /// 找可执行文件绝对路径（找不到返回 null）。
  ///
  /// 只查已知 bin 目录 + PATH，不递归扫整棵 1 GB 的 SDK/Flutter 树；
  /// Windows 命中 `.bat/.cmd` 时返回真实文件路径，不再盲目拼 `.exe`。
  String? which(String name) {
    for (final directory in _searchDirectories) {
      final hit = _resolveIn(directory, name);
      if (hit != null) return hit;
    }
    final path =
        Platform.environment[Platform.isWindows ? 'Path' : 'PATH'] ?? '';
    final sep = Platform.isWindows ? ';' : ':';
    for (final entry in path.split(sep)) {
      final directory = entry.trim().replaceAll('"', '');
      if (directory.isEmpty) continue;
      final hit = _resolveIn(directory, name);
      if (hit != null) return hit;
    }
    return null;
  }

  List<String> get _searchDirectories {
    final layout = toolchain.layout;
    final directories = <String>[
      layout.jdkBinDir,
      layout.flutterBinDir,
      layout.platformToolsDir,
      layout.join(layout.cmdlineToolsDir, 'bin'),
      layout.gitCmdDir,
    ];
    // build-tools/<version>/ 里有 aapt2 / zipalign 等；逐版本列出即可。
    final buildTools = Directory(layout.buildToolsDir);
    if (buildTools.existsSync()) {
      try {
        directories.addAll(
          buildTools.listSync().whereType<Directory>().map((dir) => dir.path),
        );
      } catch (_) {}
    }
    return directories;
  }

  String? _resolveIn(String directory, String name) {
    final hasExtension = name.contains('.');
    final candidates = Platform.isWindows && !hasExtension
        ? <String>['$name.exe', '$name.bat', '$name.cmd', name]
        : <String>[name];
    for (final candidate in candidates) {
      final path = _join(directory, candidate);
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  String _join(String a, String b) => a.endsWith(Platform.pathSeparator)
      ? '$a$b'
      : '$a${Platform.pathSeparator}$b';

  /// SHA-256：纯 Dart（下载层同款），不依赖 certutil/sha256sum。
  Future<String> sha256OfFile(String path) async {
    try {
      return await toolchain_hash.sha256OfFile(path);
    } catch (_) {
      return '';
    }
  }

  /// 用系统默认程序打开 URL。
  ///
  /// Windows 用 `rundll32 url.dll,FileProtocolHandler <url>`：URL 作为单个
  /// 进程参数传入，不经过 cmd 解析，带 `&`/`%` 的链接不会被截断。
  Future<bool> openUrl(String url) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('rundll32.exe', <String>[
          'url.dll,FileProtocolHandler',
          url,
        ]);
        if (result.exitCode == 0) return true;
        final fallback = await Process.run('explorer.exe', <String>[url]);
        return fallback.exitCode == 0;
      }
      if (Platform.isMacOS) {
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

  /// 子进程可见的环境变量（替代 `env -0`）：私有工具链环境 + 代理变量。
  Map<String, String> environment({Map<String, String> extra = const {}}) {
    final merged = <String, String>{...toolchain.childEnvironment};
    merged.addAll(_proxyVars());
    merged.addAll(extra);
    return merged;
  }

  Map<String, String> _proxyVars() {
    final provider = _proxyEnvironment ?? proxyEnvironment;
    if (provider == null) return const <String, String>{};
    try {
      return provider();
    } catch (_) {
      return const <String, String>{};
    }
  }

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
      final path = which(name);
      if (path == null) {
        return <String, dynamic>{'exitCode': 127, 'output': ''};
      }
      final rest = c.split(';').last.trim();
      if (rest.startsWith(name) && rest.endsWith('--version')) {
        // 用 which() 命中的绝对路径（.bat/.cmd 由 cmd /c 启动）。
        return await _runSimple(path, const <String>['--version']);
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
    final existTest = RegExp(
      r"^\[ -e '(.+?)' \] \|\| \[ -L '(.+?)' \]$",
    ).firstMatch(c);
    if (existTest != null) {
      final p1 = existTest.group(1)!;
      return <String, dynamic>{
        'exitCode': LocalFs.instance.exists(p1) ? 0 : 1,
        'output': '',
      };
    }

    // [ -f 'P' ] && echo RESOLVED
    final fileTest = RegExp(
      r"^\[ -f '(.+?)' \] && echo RESOLVED$",
    ).firstMatch(c);
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

  /// 直接跑一个短命令；`.bat/.cmd` 由 ToolchainProcessGateway 用 `cmd /c` 启动。
  Future<Map<String, dynamic>> _runSimple(
    String executable,
    List<String> args,
  ) async {
    try {
      final result = await toolchain.process.run(
        executable,
        args,
        environment: environment(),
      );
      return <String, dynamic>{
        'exitCode': result.exitCode,
        'output': '${result.stdout}${result.stderr}',
      };
    } catch (e) {
      return <String, dynamic>{'exitCode': -1, 'output': '$e'};
    }
  }
}
