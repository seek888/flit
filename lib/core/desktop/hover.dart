import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../host_platform.dart';
import '../theme.dart';

/// 桌面悬停检测：把指针是否停在上面回传给 builder。
///
/// Android 没有鼠标，`enabled` 在非桌面平台自动失效（始终按未悬停渲染），
/// 这样同一套组件在手机上不会因为多包一层 MouseRegion 改变观感。
class HoverBuilder extends StatefulWidget {
  const HoverBuilder({
    super.key,
    required this.builder,
    this.enabled = true,
    this.cursor,
  });

  final Widget Function(BuildContext context, bool hovering) builder;
  final bool enabled;

  /// 悬停时使用的鼠标指针；null 表示不干预。
  final MouseCursor? cursor;

  @override
  State<HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<HoverBuilder> {
  bool _hovering = false;

  bool get _active => widget.enabled && isDesktopPlatform;

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(context, _active && _hovering);
    if (!_active) return child;
    return MouseRegion(
      cursor: widget.cursor ?? MouseCursor.defer,
      onEnter: (_) {
        if (!_hovering) setState(() => _hovering = true);
      },
      onExit: (_) {
        if (_hovering) setState(() => _hovering = false);
      },
      child: child,
    );
  }
}

/// 桌面列表行：悬停高亮、选中底色、右键菜单、双击，以及可点击时的箭头光标。
///
/// 手机端只保留点击/双击/长按语义，不画悬停底色。
class HoverRow extends StatefulWidget {
  const HoverRow({
    super.key,
    required this.child,
    this.onTap,
    this.onDoubleTap,
    this.onSecondaryTap,
    this.selected = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    this.dense = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onSecondaryTap;
  final bool selected;
  final EdgeInsetsGeometry padding;
  final bool dense;

  @override
  State<HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<HoverRow> {
  bool _hovering = false;

  bool get _interactive =>
      widget.onTap != null ||
      widget.onDoubleTap != null ||
      widget.onSecondaryTap != null;

  EdgeInsetsGeometry get _padding {
    if (!widget.dense) return widget.padding;
    final resolved = widget.padding;
    if (resolved is EdgeInsets) {
      return EdgeInsets.symmetric(
        horizontal: resolved.horizontal,
        vertical: math.max(1, resolved.vertical / 2),
      );
    }
    return resolved;
  }

  Color get _background {
    if (widget.selected) return AppColors.selected;
    if (_hovering) return AppColors.hover;
    return Colors.transparent;
  }

  @override
  Widget build(BuildContext context) {
    final hoverEnabled = isDesktopPlatform && _interactive;
    Widget row = AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: _background,
        borderRadius: BorderRadius.circular(4),
      ),
      padding: _padding,
      child: widget.child,
    );
    if (_interactive) {
      row = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onSecondaryTap: widget.onSecondaryTap,
        child: row,
      );
    }
    if (!hoverEnabled) return row;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_hovering) setState(() => _hovering = true);
      },
      onExit: (_) {
        if (_hovering) setState(() => _hovering = false);
      },
      child: row,
    );
  }
}