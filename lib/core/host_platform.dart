import 'dart:io';

import 'package:flutter/foundation.dart';

/// Flit 运行所在的主机平台。
///
/// Android 是原始目标；Windows/Linux/macOS 统称「桌面」，都会绕过 Android
/// 原生插件、换成本地进程 + 文件 API（DesktopShell / LocalFs / PtyLauncher）。
/// Linux/macOS 与 Windows 共用桌面分支，只有 cmd.exe / 分隔符 / 大小写这类
/// 细节才按 [HostPlatform] 细分。
enum HostPlatform {
  android,
  windows,
  linux,
  macos;

  /// 是否桌面平台（非 Android）。
  bool get isDesktop => this != HostPlatform.android;

  bool get isWindows => this == HostPlatform.windows;

  /// Windows/macOS 的路径比较忽略大小写。
  bool get isCaseInsensitiveFs =>
      this == HostPlatform.windows || this == HostPlatform.macos;
}

HostPlatform? _override;

/// 当前主机平台（测试里可用 [setHostPlatform] 覆盖）。
HostPlatform get hostPlatform => _override ?? _detectedHostPlatform;

HostPlatform get _detectedHostPlatform {
  if (Platform.isAndroid) return HostPlatform.android;
  if (Platform.isWindows) return HostPlatform.windows;
  if (Platform.isMacOS) return HostPlatform.macos;
  return HostPlatform.linux;
}

/// 桌面端标志：Windows/Linux/macOS 走 DesktopShell，不再碰 Android 原生插件。
bool get isDesktopPlatform => hostPlatform.isDesktop;

/// 当前是否 Windows（避免到处散落 `Platform.isWindows`，测试可注入）。
bool get isWindowsPlatform => hostPlatform.isWindows;

/// 仅测试用：强制指定平台；传 null 恢复真实探测。
///
/// 生产代码永远不该调用 —— 平台是进程级事实，只在测试里为了在
/// Windows CI 上验证 Android 语义（以及反过来）才需要覆盖。
@visibleForTesting
void setHostPlatform(HostPlatform? platform) {
  _override = platform;
}
