import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Ctrl + 滚轮缩放。
///
/// 只在按住 Ctrl 时抢占滚轮事件：普通滚轮仍然滚动，不被编辑器字号拦截。
/// 回调参数固定为 ±1（向上滚 = +1 放大，向下滚 = -1 缩小），具体步长由
/// 使用方按 [stepZoom] 之类的纯函数换算。
class CtrlWheelZoom extends StatelessWidget {
  const CtrlWheelZoom({
    super.key,
    required this.child,
    required this.onZoom,
  });

  final Widget child;
  final void Function(double delta) onZoom;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: (event) {
      if (event is! PointerScrollEvent) return;
      if (!HardwareKeyboard.instance.isControlPressed) return;
      final dy = event.scrollDelta.dy;
      if (dy == 0) return;
      // 抢占解析权，避免同一个滚轮同时滚动外层列表。
      GestureBinding.instance.pointerSignalResolver.register(event, (_) {
        onZoom(dy < 0 ? 1 : -1);
      });
    },
    child: child,
  );
}

/// 把 [delta] 步进应用到 [current] 上，并夹在 [[min], [max]] 内。
///
/// 返回 null 表示没有变化（已到边界或 delta 为 0），调用方可据此跳过重建。
double? stepZoom(
  double current,
  double delta, {
  required double min,
  required double max,
}) {
  if (delta == 0) return null;
  final lower = min > max ? max : min;
  final upper = min > max ? min : max;
  final next = (current + delta).clamp(lower, upper).toDouble();
  if (next == current) return null;
  return next;
}