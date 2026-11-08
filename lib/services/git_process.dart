import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/host_platform.dart';
import 'desktop_toolchain.dart';
import 'git_credentials.dart';
import 'shell.dart';

/// 一次 git 调用的结果。`out` 是 stdout+stderr 合并后的原文（失败时原样
/// 展示给用户，不做裁剪/翻译）。
typedef GitResult = ({int code, String out});

/// 可注入的进程边界：单测用它断言 argv / env，不在测试里真的启动 git。
typedef GitProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

const Encoding _utf8 = Utf8Codec(allowMalformed: true);

Future<ProcessResult> _runProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) => Process.run(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: environment,
  stdoutEncoding: _utf8,
  stderrEncoding: _utf8,
  runInShell: false,
);

/// 一个工程的 Git 进程边界。**所有参数都走 argv，绝不拼 shell 字符串**：
/// Windows 的 cmd.exe 不认 `VAR=val cmd`、单引号、`</dev/null`，
/// 拼串写法在桌面端整层不可用（见 docs/windows-port/analysis/02-features.md §5）。
///
/// 可执行文件解析顺序：
/// 1. 显式注入的 `executable`（单测/高级设置）；
/// 2. `DesktopToolchain().gitExe`（私有 MinGit 目录里的 `git.exe`）；
/// 3. `Shell.instance.which('git')`（PATH / 系统 Git for Windows）；
/// 4. 裸 `git`，交给 Process 按 PATH 找。
///
/// 环境变量固定注入：
/// - `GIT_CONFIG_GLOBAL` 指向 `<DesktopToolchain.home>\.flit\gitconfig`
///   （`credential.helper=store`，见 [GitCredentials]），不污染用户全局配置；
/// - `GIT_CONFIG_NOSYSTEM=1` 不读系统级 gitconfig；
/// - `GIT_TERMINAL_PROMPT=0` 绝不在没有终端的地方等输入；
/// - Windows 再加 `GIT_ASKPASS=echo` 兜底，避免弹窗。
class GitProcess {
  GitProcess(
    this.root, {
    Map<String, String>? environment,
    String? executable,
    DesktopToolchain? toolchain,
    GitCredentials? credentials,
    GitProcessRunner? runner,
    this.timeoutMs = 60000,
  }) : _environment = environment,
       _exe = executable,
       toolchain = toolchain ?? DesktopToolchain(),
       credentials =
           credentials ??
           GitCredentials(home: (toolchain ?? DesktopToolchain()).home),
       _runner = runner ?? _runProcess;

  /// 工程根（git 的 workingDirectory）。
  final String root;
  final Map<String, String>? _environment;
  final String? _exe;
  final DesktopToolchain toolchain;
  final GitCredentials credentials;
  final GitProcessRunner _runner;
  final int timeoutMs;

  /// 所有 git 子命令前都要带的「输出稳定化」参数：不做分页、不展开 pathspec、
  /// 不转义非 ASCII 路径、不输出颜色（机器解析用）。
  static const List<String> globalArgs = [
    '--no-pager',
    '--literal-pathspecs',
    '-c',
    'core.quotepath=false',
    '-c',
    'color.ui=false',
    // 二次保险：装饰器/交互凭据助手不能颠覆上面这些设置。
    '-c',
    'color.advice=false',
  ];

  /// 解析出来的 git 可执行文件绝对路径（或裸 `git`）。
  String get executable {
    if (_exe != null && _exe.isNotEmpty) return _exe;
    try {
      final bundled = toolchain.gitExe;
      if (File(bundled).existsSync()) return bundled;
    } catch (_) {
      // Android 上也有 DesktopToolchain，只是路径无意义；忽略即可。
    }
    if (isDesktopPlatform) {
      try {
        final found = Shell.instance.which('git');
        if (found != null && found.isNotEmpty) return found;
      } catch (_) {}
    }
    return 'git';
  }

  /// 子进程环境：工具链隔离环境 + 本工程的 git 专属变量。
  Map<String, String> get environment {
    final base = Map<String, String>.from(
      _environment ?? toolchain.childEnvironment,
    );
    base['GIT_TERMINAL_PROMPT'] = '0';
    base['GIT_CONFIG_NOSYSTEM'] = '1';
    base['GIT_CONFIG_GLOBAL'] = credentials.globalConfigPath;
    if (isWindowsPlatform) base['GIT_ASKPASS'] = 'echo';
    return base;
  }

  /// 跑一次 git。失败（非 0 退出码 / 超时 / 无法启动）都返回结果而不是抛异常，
  /// 由上层决定「展示原文」还是「当作无仓库」。
  Future<GitResult> run(
    List<String> args, {
    int? timeoutMs,
    String? workingDirectory,
  }) async {
    final exe = executable;
    final env = environment;
    try {
      final result = await _runner(
        exe,
        [...globalArgs, ...args],
        workingDirectory: workingDirectory ?? root,
        environment: env,
      ).timeout(Duration(milliseconds: timeoutMs ?? this.timeoutMs));
      final out = '${result.stdout}${result.stderr}';
      return (code: result.exitCode, out: out);
    } on TimeoutException {
      return (
        code: 124,
        out:
            'git 命令超时（${timeoutMs ?? this.timeoutMs} ms）：git ${args.join(' ')}',
      );
    } catch (error) {
      return (code: -1, out: '$error');
    }
  }

  /// `git --version`；用于克隆页/环境页的预检（不 spawn bash）。
  Future<String> version() async {
    final result = await run(['--version']);
    final first = result.out.split('\n').first.trim();
    return result.code == 0 ? first : '';
  }

  /// 克隆。`workingDirectory` 传父目录，目录由 git 自己创建；调用方负责确认
  /// 目标不存在。HTTPS 凭据来自 [GitCredentials]（credential.helper=store）。
  Future<GitResult> clone({
    required String url,
    required String parentDirectory,
    String? directory,
    String? branch,
    bool shallow = false,
    int timeoutMs = 300000,
  }) {
    final trimmedBranch = branch?.trim() ?? '';
    return run(
      [
        'clone',
        if (trimmedBranch.isNotEmpty) ...['--branch', trimmedBranch],
        if (shallow) ...['--depth', '1'],
        url,
        if (directory != null && directory.isNotEmpty) directory,
      ],
      workingDirectory: parentDirectory,
      timeoutMs: timeoutMs,
    );
  }

  /// 终端里展示用的等价命令文本（只用于显示，绝不拿去执行）。
  static String display(List<String> args) =>
      'git ${args.map(_displayArg).join(' ')}';

  static String _displayArg(String arg) {
    if (arg.isEmpty) return "''";
    if (RegExp(r'[^A-Za-z0-9_@%+=:,./-]').hasMatch(arg)) {
      return "'${arg.replaceAll("'", "'\\''")}'";
    }
    return arg;
  }

  /// `git@github.com:owner/repo.git` / `ssh://git@github.com/owner/repo.git`
  /// 这类需要 ssh 的地址。
  static bool isSshUrl(String url) {
    final value = url.trim();
    return value.startsWith('git@') || value.startsWith('ssh://');
  }

  /// 桌面端 SSH → HTTPS：MinGit 不带 ssh.exe，GitHub 的 HTTPS 才是可用路径。
  ///
  /// - `git@github.com:owner/repo.git` → `https://github.com/owner/repo.git`
  /// - `ssh://git@github.com/owner/repo.git` → `https://github.com/owner/repo.git`
  /// - `ssh://git@github.com:22/owner/repo.git` → 端口丢弃
  /// - 其它 host 同样处理（GitLab/Gitea 也用同一规则）
  /// - HTTPS / 本地路径 / 其它协议原样返回
  static String normalizeUrl(String url) {
    final value = url.trim();
    if (!isSshUrl(value)) return value;
    if (value.startsWith('ssh://')) {
      final uri = Uri.tryParse(value);
      if (uri == null || uri.host.isEmpty) return value;
      final path = uri.path.startsWith('/') ? uri.path : '/${uri.path}';
      return 'https://${uri.host}$path';
    }
    // scp 风格: [user@]host:path
    final match = RegExp(r'^(?:[^@/\s]+@)?([^:/\s]+):(.+)$').firstMatch(value);
    if (match == null) return value;
    final host = match.group(1)!;
    final path = match.group(2)!;
    return 'https://$host/${path.startsWith('/') ? path.substring(1) : path}';
  }

  /// 给「第一次用桌面端」的用户看的提示：SSH 地址会转成 HTTPS。
  static String? sshNotice(String url) =>
      isSshUrl(url) ? stringsDesktopSshToHttps : null;
}

/// 桌面端 SSH → HTTPS 的提示文案（本文件是 services 层，不依赖 l10n 资源；
/// 桌面专属文案目前直接硬编码中文，后续可迁到 strings）。
const String stringsDesktopSshToHttps =
    '桌面版暂不支持 SSH（MinGit 不含 ssh.exe），已自动改用 HTTPS 地址。';
