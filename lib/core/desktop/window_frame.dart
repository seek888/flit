// window_manager 0.6.0 把 0.5.x 的窗口 API 移到了 legacy.dart；这里的生命周期
// （ensureInitialized / waitUntilReadyToShow / WindowOptions / WindowListener）
// 正是该形状，桌面窗口行为由 verifier 在真实运行中复验。
// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/legacy.dart';

import '../../services/desktop_toolchain.dart';
import '../host_platform.dart';
import '../theme.dart';
import 'app_commands.dart';

/// 窗口几何：宽高 + 可选位置 + 是否最大化。
///
/// 序列化到 `<home>/.flit/window.json`，启动时恢复；非法数据返回 null，
/// 由调用方回落到默认 1280×800 居中。
class WindowGeometry {
  const WindowGeometry({
    required this.width,
    required this.height,
    this.x,
    this.y,
    this.maximized = false,
  });

  final double width;
  final double height;
  final double? x;
  final double? y;
  final bool maximized;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'width': width,
    'height': height,
    if (x != null) 'x': x,
    if (y != null) 'y': y,
    'maximized': maximized,
  };

  static WindowGeometry? fromJson(Object? json) {
    if (json is! Map) return null;
    final width = _finiteDouble(json['width']);
    final height = _finiteDouble(json['height']);
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    final hasX = json['x'] != null;
    final hasY = json['y'] != null;
    final x = hasX ? _finiteDouble(json['x']) : null;
    final y = hasY ? _finiteDouble(json['y']) : null;
    if ((hasX && x == null) || (hasY && y == null)) return null;
    return WindowGeometry(
      width: width,
      height: height,
      x: x,
      y: y,
      maximized: json['maximized'] == true,
    );
  }

  static double? _finiteDouble(Object? value) {
    final number = value is num
        ? value.toDouble()
        : (value is String ? double.tryParse(value) : null);
    if (number == null || !number.isFinite) return null;
    return number;
  }
}

/// 默认窗口尺寸与最小尺寸（与 Windows 桌面布局的下限一致）。
const Size defaultDesktopWindowSize = Size(1280, 800);
const Size minimumDesktopWindowSize = Size(960, 640);

/// 当前屏幕（主窗口所在显示器）的逻辑尺寸；测试/无显示器时给安全默认值。
Size desktopScreenSize() {
  try {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    final display = view?.display;
    if (display != null && display.size.width > 0) {
      final ratio = display.devicePixelRatio > 0
          ? display.devicePixelRatio
          : 1.0;
      return Size(
        display.size.width / ratio,
        display.size.height / ratio,
      );
    }
    if (view != null && view.physicalSize.width > 0) {
      return view.physicalSize / view.devicePixelRatio;
    }
  } catch (_) {
    // 测试环境没有绑定/显示器，走默认值。
  }
  return const Size(1920, 1080);
}

/// 把恢复出来的窗口夹回屏幕可见区域：至少留出标题栏与一部分内容，
/// 避免换显示器/降分辨率后窗口出现在屏幕外。
WindowGeometry clampWindowGeometry(WindowGeometry geometry, Size screen) {
  final maxWidth = math.max(minimumDesktopWindowSize.width, screen.width);
  final maxHeight = math.max(minimumDesktopWindowSize.height, screen.height);
  final width = geometry.width.clamp(minimumDesktopWindowSize.width, maxWidth);
  final height = geometry.height.clamp(
    minimumDesktopWindowSize.height,
    maxHeight,
  );
  double? x = geometry.x;
  double? y = geometry.y;
  if (x != null) x = _fitAxis(x, width, screen.width);
  if (y != null) y = _fitAxis(y, height, screen.height, allowNegative: false);
  return WindowGeometry(
    width: width,
    height: height,
    x: x,
    y: y,
    maximized: geometry.maximized,
  );
}

/// 把窗口的一个轴收回到屏幕内。
///
/// 只夹「起点」不够：1500 宽 + x=640 在 1707 可用逻辑宽下会把半个窗口推到屏幕外。
/// 所以按 `起点 + 尺寸` 夹：能整窗放下就整窗放下，放不下（比屏幕还大）就贴 0。
/// [allowNegative] 为真时允许负值（副屏在主屏左边），但至少留 160px 可见。
double _fitAxis(
  double value,
  double extent,
  double limit, {
  bool allowNegative = true,
}) {
  final minValue = allowNegative ? -(extent - 160) : 0.0;
  if (extent >= limit) return _clampAxis(value, minValue, 0.0);
  final maxValue = limit - extent;
  return _clampAxis(value, minValue, maxValue);
}

double _clampAxis(double value, double lower, double upper) {
  if (upper < lower) return lower;
  return value.clamp(lower, upper);
}

String _windowStateFile() {
  String home;
  try {
    home = DesktopToolchain.instance.home;
  } catch (_) {
    home = _fallbackHome();
  }
  return '$home${Platform.pathSeparator}.flit'
      '${Platform.pathSeparator}window.json';
}

String _fallbackHome() {
  final local = Platform.environment['LOCALAPPDATA'];
  if (local != null && local.isNotEmpty) return '$local\\FlitDesk';
  return '${Directory.current.path}${Platform.pathSeparator}FlitDesk';
}

/// 读取上次保存的窗口几何；文件不存在/内容非法都返回 null。
Future<WindowGeometry?> loadDesktopWindowGeometry() async {
  if (!isDesktopPlatform) return null;
  try {
    final file = File(_windowStateFile());
    if (!await file.exists()) return null;
    return WindowGeometry.fromJson(jsonDecode(await file.readAsString()));
  } catch (error) {
    debugPrint('读取窗口几何失败: $error');
    return null;
  }
}

/// 保存当前窗口几何。无窗口/无显示器（测试环境）时安全 no-op。
Future<void> saveDesktopWindowGeometry() async {
  if (!isDesktopPlatform) return;
  try {
    final bounds = await windowManager.getBounds();
    if (bounds.width <= 0 || bounds.height <= 0) return;
    final maximized = await windowManager.isMaximized();
    final geometry = WindowGeometry(
      width: bounds.width,
      height: bounds.height,
      x: bounds.left,
      y: bounds.top,
      maximized: maximized,
    );
    await writeDesktopWindowGeometry(geometry);
  } catch (error) {
    debugPrint('保存窗口几何失败: $error');
  }
}

/// 纯 IO：把几何写入状态文件（测试可直接验证内容），目录不存在时创建。
Future<void> writeDesktopWindowGeometry(WindowGeometry geometry) async {
  if (!isDesktopPlatform) return;
  try {
    final file = File(_windowStateFile());
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(geometry.toJson()));
  } catch (error) {
    debugPrint('写入窗口几何失败: $error');
  }
}

bool _windowSetupDone = false;
bool _closing = false;
String? _windowTitle;
_DesktopWindowListener? _windowListener;

/// 首帧后再应用上次几何：`setupDesktopWindow` 跑在 runApp 之前，此时
/// platformDispatcher 的 devicePixelRatio 往往还是 1.0，按它算出来的屏幕
/// 逻辑尺寸会把窗口夹到屏幕外（150% 缩放下实测右边缘超出 500px）。
WindowGeometry? _pendingRestore;

/// 首帧后恢复上次的窗口位置/大小（测试/无窗口环境安全 no-op）。
Future<void> applyRestoredWindowBounds() async {
  if (!isDesktopPlatform) return;
  final saved = _pendingRestore;
  _pendingRestore = null;
  if (saved == null) return;
  try {
    final screen = desktopScreenSize();
    final geometry = clampWindowGeometry(saved, screen);
    final x = geometry.x ?? math.max(0, (screen.width - geometry.width) / 2);
    final y = geometry.y ?? math.max(0, (screen.height - geometry.height) / 2);
    await windowManager.setBounds(
      Rect.fromLTWH(x, y, geometry.width, geometry.height),
    );
    if (geometry.maximized) await windowManager.maximize();
    await saveDesktopWindowGeometry();
  } catch (error) {
    debugPrint('恢复窗口几何失败: $error');
  }
}

/// 桌面窗口初始化：恢复几何、居中/最大化、阻止默认关窗并接管退出流程。
///
/// 必须在 `runApp` 之前调用；非桌面平台、测试环境（无窗口插件/无显示器）
/// 都安全 no-op，不抛异常。
Future<void> setupDesktopWindow() async {
  if (!isDesktopPlatform || _windowSetupDone) return;
  _windowSetupDone = true;
  try {
    await windowManager.ensureInitialized();
    final screen = desktopScreenSize();
    final saved = await loadDesktopWindowGeometry();
    final geometry = saved == null ? null : clampWindowGeometry(saved, screen);
    final size = geometry == null
        ? defaultDesktopWindowSize
        : Size(geometry.width, geometry.height);
    _pendingRestore = geometry;

    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: size,
        // 不交给 window_manager 居中：它在 150% DPI 下把物理像素当逻辑像素，
        // 会把窗口放到屏幕右外侧。位置由首帧后的 applyRestoredWindowBounds
        // 用真实 DPR 精确定位；没有历史几何时保持 main.cpp 的 (10,10)。
        center: false,
        minimumSize: minimumDesktopWindowSize,
        title: 'Flit',
        backgroundColor: AppColors.bg,
      ),
      () async {
        try {
          if (geometry?.maximized ?? false) {
            await windowManager.maximize();
          }
          await windowManager.show();
          await windowManager.focus();
        } catch (error) {
          debugPrint('桌面窗口显示失败: $error');
        }
      },
    );

    await windowManager.setPreventClose(true);
    _windowListener ??= _DesktopWindowListener(
      onClose: _handleWindowClose,
      // 拖动/缩放/最大化时防抖落盘：关窗那一刻再查 bounds 可能已被系统拆掉，
      // 只靠关闭流程会让「几何记忆」在多数退出路径上失效。
      onGeometryChanged: () => unawaited(saveDesktopWindowGeometry()),
    );
    windowManager.addListener(_windowListener!);
  } catch (error) {
    debugPrint('桌面窗口初始化跳过: $error');
  }
}

/// 关窗流程：先让页面保存（3 秒超时）→ 保存几何 → 真正销毁窗口。
Future<void> _handleWindowClose() async {
  if (_closing) return;
  _closing = true;
  try {
    await runAppBeforeCloseHandler();
    await saveDesktopWindowGeometry();
    await windowManager.destroy();
  } catch (error) {
    debugPrint('窗口关闭流程失败: $error');
  } finally {
    _closing = false;
  }
}

class _DesktopWindowListener with WindowListener {
  _DesktopWindowListener({
    required this.onClose,
    required this.onGeometryChanged,
  });

  final VoidCallback onClose;
  final VoidCallback onGeometryChanged;
  Timer? _debounce;

  /// 连续拖动/缩放只写一次盘：600ms 内没有新事件才落盘。
  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), onGeometryChanged);
  }

  @override
  void onWindowClose() => onClose();

  @override
  void onWindowResized() => _scheduleSave();

  @override
  void onWindowMoved() => _scheduleSave();

  @override
  void onWindowMaximize() => _scheduleSave();

  @override
  void onWindowUnmaximize() => _scheduleSave();
}

/// 修改窗口标题（幂等：相同标题不重复调用原生 API；非桌面 no-op）。
Future<void> setDesktopWindowTitle(String title) async {
  if (!isDesktopPlatform) return;
  final next = title.trim().isEmpty ? 'Flit' : title.trim();
  if (_windowTitle == next) return;
  _windowTitle = next;
  try {
    await windowManager.setTitle(next);
  } catch (error) {
    debugPrint('设置窗口标题失败: $error');
  }
}

/// 应用退出：桌面走 windowManager.close 触发关窗流程（保存几何后销毁）；
/// Android 交还系统。
Future<void> closeDesktopApp() async {
  if (!isDesktopPlatform) {
    SystemNavigator.pop();
    return;
  }
  try {
    await windowManager.close();
  } catch (error) {
    debugPrint('关闭窗口失败: $error');
  }
}