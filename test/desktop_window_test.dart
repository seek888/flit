import 'dart:convert';
import 'dart:ui' show Size;

import 'package:flit/core/desktop/desktop_zoom.dart';
import 'package:flit/core/desktop/window_frame.dart';
import 'package:flit/core/host_platform.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WindowGeometry', () {
    test('toJson / fromJson 往返保留全部字段', () {
      const geometry = WindowGeometry(
        width: 1440,
        height: 900,
        x: -120,
        y: 40,
        maximized: true,
      );
      final restored = WindowGeometry.fromJson(
        jsonDecode(jsonEncode(geometry.toJson())),
      );
      expect(restored, isNotNull);
      expect(restored!.width, 1440);
      expect(restored.height, 900);
      expect(restored.x, -120);
      expect(restored.y, 40);
      expect(restored.maximized, isTrue);
    });

    test('toJson / fromJson 往返：无位置 + 未最大化', () {
      const geometry = WindowGeometry(width: 1280, height: 800);
      final restored = WindowGeometry.fromJson(geometry.toJson());
      expect(restored, isNotNull);
      expect(restored!.width, 1280);
      expect(restored.height, 800);
      expect(restored.x, isNull);
      expect(restored.y, isNull);
      expect(restored.maximized, isFalse);
    });

    test('非法数据返回 null', () {
      expect(WindowGeometry.fromJson(null), isNull);
      expect(WindowGeometry.fromJson('not-a-map'), isNull);
      expect(WindowGeometry.fromJson(<String, dynamic>{}), isNull);
      expect(
        WindowGeometry.fromJson(<String, dynamic>{'width': 1280}),
        isNull,
        reason: '缺高度',
      );
      expect(
        WindowGeometry.fromJson(<String, dynamic>{'width': 0, 'height': 800}),
        isNull,
        reason: '宽必须为正',
      );
      expect(
        WindowGeometry.fromJson(<String, dynamic>{
          'width': -1280,
          'height': 800,
        }),
        isNull,
        reason: '负宽非法',
      );
      expect(
        WindowGeometry.fromJson(<String, dynamic>{
          'width': double.nan,
          'height': 800,
        }),
        isNull,
        reason: 'NaN 非法',
      );
      expect(
        WindowGeometry.fromJson(<String, dynamic>{
          'width': 1280,
          'height': 800,
          'x': 'left',
        }),
        isNull,
        reason: 'x 不是数字',
      );
    });

    test('字符串数字可解析，非法字符串拒绝', () {
      final restored = WindowGeometry.fromJson(<String, dynamic>{
        'width': '1280',
        'height': '800',
        'x': '-20',
        'y': '10',
      });
      expect(restored, isNotNull);
      expect(restored!.width, 1280);
      expect(restored.x, -20);
      expect(
        WindowGeometry.fromJson(<String, dynamic>{
          'width': 'wide',
          'height': 800,
        }),
        isNull,
      );
    });

    test('clamp 回屏幕可见区域', () {
      final clamped = clampWindowGeometry(
        const WindowGeometry(
          width: 4000,
          height: 3000,
          x: -9000,
          y: 5000,
        ),
        const Size(1920, 1080),
      );
      expect(clamped.width, lessThanOrEqualTo(1920));
      expect(clamped.height, lessThanOrEqualTo(1080));
      expect(clamped.width, greaterThanOrEqualTo(960));
      expect(clamped.height, greaterThanOrEqualTo(640));
      expect(clamped.x, greaterThanOrEqualTo(-(clamped.width - 160)));
      expect(clamped.y, lessThanOrEqualTo(1080));
    });
  });

  group('stepZoom', () {
    test('正常步进', () {
      expect(stepZoom(13, 1, min: 8, max: 32), 14);
      expect(stepZoom(13, -1, min: 8, max: 32), 12);
    });

    test('到达上/下边界返回 null', () {
      expect(stepZoom(32, 1, min: 8, max: 32), isNull);
      expect(stepZoom(8, -1, min: 8, max: 32), isNull);
    });

    test('步进跨越边界时夹紧', () {
      expect(stepZoom(31.5, 1, min: 8, max: 32), 32);
      expect(stepZoom(8.5, -1, min: 8, max: 32), 8);
    });

    test('delta 为 0 返回 null', () {
      expect(stepZoom(20, 0, min: 8, max: 32), isNull);
    });

    test('min/max 传反也能工作', () {
      expect(stepZoom(13, 1, min: 32, max: 8), 14);
    });
  });

  group('窗口 API 在无窗口插件/无显示器环境安全 no-op', () {
    test('setup/save/title 不抛异常', () async {
      setHostPlatform(HostPlatform.windows);
      addTearDown(() => setHostPlatform(null));
      await setupDesktopWindow();
      await saveDesktopWindowGeometry();
      await setDesktopWindowTitle('测试窗口');
      await setDesktopWindowTitle('测试窗口'); // 幂等
      expect(true, isTrue);
    });

    test('非桌面平台直接 no-op', () async {
      setHostPlatform(HostPlatform.android);
      addTearDown(() => setHostPlatform(null));
      await setupDesktopWindow();
      await saveDesktopWindowGeometry();
      await setDesktopWindowTitle('Flit');
    });
  });
}