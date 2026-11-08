import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../host_platform.dart';
import '../theme.dart';

/// 桌面滚动行为：鼠标/触控板也能拖动，滚动条更细、悬停变粗。
class FlitScrollBehavior extends MaterialScrollBehavior {
  const FlitScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (!isDesktopPlatform) {
      return super.buildScrollbar(context, child, details);
    }
    // Scrollbar 自己根据指针是否停在滚动条上解析 hovered 状态：细条 8px，
    // 悬停 12px；thumb 默认 border 色，悬停变亮，避免在深色底上找不到滚动条。
    return ScrollbarTheme(
      data: ScrollbarThemeData(
        thickness: WidgetStateProperty.resolveWith<double?>(
          (states) => states.contains(WidgetState.hovered) ? 12 : 8,
        ),
        radius: const Radius.circular(4),
        thumbColor: WidgetStateProperty.resolveWith<Color?>(
          (states) => states.contains(WidgetState.hovered)
              ? AppColors.textSecondary
              : AppColors.border,
        ),
        trackVisibility: const WidgetStatePropertyAll<bool>(false),
        crossAxisMargin: 2,
        minThumbLength: 24,
      ),
      child: Scrollbar(
        controller: details.controller,
        interactive: true,
        child: child,
      ),
    );
  }
}