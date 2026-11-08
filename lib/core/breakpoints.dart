import 'package:flutter/material.dart';

/// Material 3 窗口尺寸类：按 MediaQuery 宽度划档，不按设备类型判断
/// (平板竖屏 600-840 走 medium, 与手机同布局; 横屏大屏 ≥840 才展开双栏)。
///
/// [desktop] 是 Windows 桌面档（≥1200）：永久侧栏 + 状态栏 + 更宽的内容区。
enum WindowSize { compact, medium, expanded, desktop }

WindowSize windowSizeOf(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width >= 1200) return WindowSize.desktop;
  if (width >= 840) return WindowSize.expanded;
  if (width >= 600) return WindowSize.medium;
  return WindowSize.compact;
}

/// 桌面宽屏（≥1000）：侧栏常驻，不再用抽屉。
///
/// 与 [WindowSize.desktop] 分开：1000-1200 之间的窗口仍算 expanded，但已经
/// 足够放下文件树侧栏，所以 dock 阈值更低。
bool useDesktopDock(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= 1000;