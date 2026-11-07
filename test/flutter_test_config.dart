import 'dart:async';

import 'package:flit/core/host_platform.dart';
import 'package:flutter_test/flutter_test.dart';

/// 测试默认按 Android 语义运行。
///
/// Flit 的主目标平台是 Android：绝大多数测试 mock 的是 `flit/*` 原生通道
/// （MethodChannel）与 bash 脚本。桌面 CI（windows-latest / 未来的 Linux 桌面）
/// 上真实平台是 desktop，产品代码会绕开这些 mock 去跑真实 cmd/Dart API，
/// 于是一批 Android 语义测试无谓失败。
///
/// 平台 seam 在测试进程里是全局可注入的（[setHostPlatform]），这里把默认值固定
/// 成 Android，让测试真正验证「Android 语义」；需要桌面语义的测试在 `setUp`
/// 里显式 `setHostPlatform(HostPlatform.windows)`（见 test/support/host_platform.dart）。
///
/// 注意：纯文件层的 [LocalFs] 仍然读真实平台来决定大小写/权限位语义，
/// 不受这个默认值影响 —— 它是「宿主文件系统事实」，不是产品分支。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setHostPlatform(HostPlatform.android);
  await testMain();
}