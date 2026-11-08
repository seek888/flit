import 'dart:io';

import 'package:flit_env/flit_env.dart';

import '../core/host_platform.dart';
import 'desktop_shell.dart';

export '../core/host_platform.dart'
    show HostPlatform, hostPlatform, isDesktopPlatform, setHostPlatform;

/// shell 单引号转义(拼终端命令用)
String shQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// 终端长命令统一前缀。
/// Android: PTY bash 的环境在启动那一刻冻结，命令自带 source 才能拿到最新 PATH。
/// 桌面: 环境由子进程注入，不需要 source。
String get terminalEnvSource {
  if (hostPlatform != HostPlatform.android) return '';
  return r'if [ -f "$HOME/.flit/env.sh" ]; then . "$HOME/.flit/env.sh" || exit $?; fi; ';
}

/// 进程边界门面：Android 侧是 flit_env 原生薄方法，桌面侧是本地进程 + 隔离环境。
class Shell {
  Shell._();
  static final Shell instance = Shell._();

  Future<Map<dynamic, dynamic>> bootstrapStatus() async {
    if (isDesktopPlatform) {
      return Map<dynamic, dynamic>.from(
        DesktopShell.instance.bootstrapStatus(),
      );
    }
    return FlitEnv.bootstrapStatus();
  }

  /// 原生全量解压 bootstrap 到 $PREFIX；桌面端没有这个概念，直接视为已部署。
  Future<bool> deployBootstrap(String zipPath) async {
    if (isDesktopPlatform) return true;
    return FlitEnv.deployBootstrap(zipPath);
  }

  /// 一次性执行(不进交互会话), 返回 (exitCode, output)
  Future<Map<dynamic, dynamic>> exec(
    String cmd, {
    int timeoutMs = 120000,
  }) async {
    if (isDesktopPlatform) {
      return Map<dynamic, dynamic>.from(
        await DesktopShell.instance.exec(cmd, timeoutMs: timeoutMs),
      );
    }
    return FlitEnv.exec(cmd, timeoutMs: timeoutMs);
  }

  /// 文件 sha256(产物校验用)
  Future<String> sha256OfFile(String path) async {
    if (isDesktopPlatform) return DesktopShell.instance.sha256OfFile(path);
    return FlitEnv.sha256(path);
  }

  /// 唤起系统浏览器 / 打开 URL
  Future<bool> openUrl(String url) async {
    if (isDesktopPlatform) return DesktopShell.instance.openUrl(url);
    return FlitEnv.openUrl(url);
  }

  /// 打开系统设置页(action 见 android.provider.Settings)；桌面端无对应概念。
  Future<bool> openSettings(String action) async {
    if (isDesktopPlatform) return false;
    return FlitEnv.openSettings(action);
  }

  // ---------- 桌面辅助能力（Android 端也安全，返回合理默认） ----------

  /// `command -v X` 的替代。
  bool hasBinary(String name) {
    if (isDesktopPlatform) return DesktopShell.instance.hasBinary(name);
    return false;
  }

  /// 可执行文件绝对路径（桌面端）。
  String? which(String name) {
    if (isDesktopPlatform) return DesktopShell.instance.which(name);
    return null;
  }

  /// 以 argv 直接执行已知可执行文件（桌面端；`.bat/.cmd` 也安全）。
  ///
  /// 与 [exec] 的区别：不经过 shell 的命令串解析，因此路径/参数里的空格、
  /// 引号不会被二次转义（`cmd /c "..."` 在 Windows 上会把内层引号变成
  /// `\"`，见 [DesktopShell.runBinary]）。Android 端没有 argv 边界，
  /// 退回引号化的 shell 命令。
  Future<Map<dynamic, dynamic>> runBinary(
    String executable,
    List<String> arguments, {
    int timeoutMs = 120000,
  }) async {
    if (isDesktopPlatform) {
      return Map<dynamic, dynamic>.from(
        await DesktopShell.instance.runBinary(
          executable,
          arguments,
          timeoutMs: timeoutMs,
        ),
      );
    }
    return exec(
      [executable, ...arguments].map(shQuote).join(' '),
      timeoutMs: timeoutMs,
    );
  }

  /// 子进程可见的环境变量（替代 `env -0`）。
  Map<String, String> environment() {
    if (isDesktopPlatform) return DesktopShell.instance.environment();
    return Map<String, String>.from(Platform.environment);
  }

  /// 在文件管理器里显示目录（桌面端）。
  Future<bool> revealDirectory(String path) async {
    if (isDesktopPlatform) return DesktopShell.instance.revealDirectory(path);
    return false;
  }
}
