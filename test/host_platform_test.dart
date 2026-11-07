import 'dart:io';

import 'package:flit/core/host_platform.dart';
import 'package:flit/services/shell.dart' as shell;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => setHostPlatform(null));

  HostPlatform expectedHost() {
    if (Platform.isAndroid) return HostPlatform.android;
    if (Platform.isWindows) return HostPlatform.windows;
    if (Platform.isMacOS) return HostPlatform.macos;
    return HostPlatform.linux;
  }

  test('hostPlatform follows dart:io Platform by default', () {
    // test/flutter_test_config.dart 为了兼容 Android 语义测试，进程启动时把
    // 平台固定成 android；这里要验证真实探测，先清掉覆盖。
    setHostPlatform(null);
    expect(hostPlatform, expectedHost());
    expect(isDesktopPlatform, !Platform.isAndroid);
    expect(isWindowsPlatform, Platform.isWindows);
  });

  test('setHostPlatform overrides detection and null restores it', () {
    setHostPlatform(HostPlatform.android);
    expect(hostPlatform, HostPlatform.android);
    expect(isDesktopPlatform, isFalse);
    expect(isWindowsPlatform, isFalse);

    setHostPlatform(HostPlatform.windows);
    expect(isDesktopPlatform, isTrue);
    expect(isWindowsPlatform, isTrue);

    setHostPlatform(HostPlatform.macos);
    expect(isDesktopPlatform, isTrue);
    expect(isWindowsPlatform, isFalse);
    expect(hostPlatform.isCaseInsensitiveFs, isTrue);

    setHostPlatform(HostPlatform.linux);
    expect(isDesktopPlatform, isTrue);
    expect(hostPlatform.isCaseInsensitiveFs, isFalse);

    setHostPlatform(null);
    expect(hostPlatform, expectedHost());
  });

  test('shell.dart keeps the compatible platform exports', () {
    // 历史调用方都是 `import services/shell.dart` 拿 isDesktopPlatform；
    // seam 换实现后这个导出名必须保持可用。
    setHostPlatform(HostPlatform.android);
    expect(shell.isDesktopPlatform, isFalse);
    expect(shell.hostPlatform, HostPlatform.android);

    setHostPlatform(HostPlatform.windows);
    expect(shell.isDesktopPlatform, isTrue);
    expect(shell.hostPlatform, HostPlatform.windows);
  });

  test('terminalEnvSource only exists on Android', () {
    setHostPlatform(HostPlatform.android);
    expect(shell.terminalEnvSource, contains('env.sh'));
    setHostPlatform(HostPlatform.windows);
    expect(shell.terminalEnvSource, isEmpty);
    setHostPlatform(HostPlatform.linux);
    expect(shell.terminalEnvSource, isEmpty);
  });
}
