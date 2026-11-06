import 'dart:io';

import 'package:flit_env/flit_env.dart';

import 'desktop_shell.dart';

/// shell 单引号转义(拼终端命令用)
String shQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// 终端长命令统一前缀。
/// Android: PTY bash 的环境在启动那一刻冻结，命令自带 source 才能拿到最新 PATH。
/// 桌面: 环境由子进程注入，不需要 source。
String get terminalEnvSource {
  if (!Platform.isAndroid) return '';
  return r'if [ -f "$HOME/.flit/env.sh" ]; then . "$HOME/.flit/env.sh" || exit $?; fi; ';
}

/// 桌面端标志：Windows/Linux/macOS 走 DesktopShell，不再碰 Android 原生插件。
bool get isDesktopPlatform => !Platform.isAndroid;

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
