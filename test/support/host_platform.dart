import 'package:flit/core/host_platform.dart';
import 'package:flutter_test/flutter_test.dart';

/// 在一组测试里把宿主平台固定成 [platform]，结束后恢复真实探测。
///
/// 背景：Windows CI 上 `Platform.isAndroid` 为 false，产品代码会走桌面分支，
/// 所有 mock 了 `flit/env` 的 Android 语义测试都会绕过桩去跑真实 cmd —— 于是
/// 一个接一个失败。用这个 helper 在 `setUp` 里声明"本组测试按 Android 跑"，
/// 平台 seam 就会把产品代码导回 mock 路径；真正的桌面语义测试则固定成
/// windows（不依赖 runner 是不是 Windows）。
void useHostPlatform(HostPlatform platform) {
  setUp(() => setHostPlatform(platform));
  tearDown(() => setHostPlatform(null));
}

/// 只在 [body] 执行期间固定平台（适合单个 test 内的临时切换）。
T withHostPlatform<T>(HostPlatform platform, T Function() body) {
  setHostPlatform(platform);
  try {
    return body();
  } finally {
    setHostPlatform(null);
  }
}
