import 'package:flit/l10n/strings.dart';

import '../../services/desktop_toolchain.dart';
import '../../services/shell.dart';
import 'setup_runner.dart';
import 'environment_controller.dart'
    show parseStageMarker, readyStageIds, stripAnsi;

/// A read-only snapshot. All required components must report DONE in a successful
/// check; partial output must never unlock project creation or execution.
class EnvironmentStatus {
  const EnvironmentStatus({
    required this.bootstrapped,
    this.completed = 0,
    this.checkFailed = false,
  });

  final bool bootstrapped;
  final int completed;
  final bool checkFailed;

  bool get ready =>
      bootstrapped && !checkFailed && completed == readyStageIds.length;

  String get label {
    if (checkFailed) return strings.checkFailedOpenDevelopmentEnvironment;
    if (!bootstrapped) return strings.notInstalledSetUpDevelopmentEnvironment;
    if (ready) return strings.allComponentsReady;
    return strings.pPComponentsReady(completed, readyStageIds.length);
  }

  factory EnvironmentStatus.fromCheck({
    required int exitCode,
    required String output,
  }) {
    final states = <String, String>{};
    for (final line in output.split(RegExp(r'[\r\n]'))) {
      final marker = parseStageMarker(stripAnsi(line));
      if (marker != null) states[marker.$1] = marker.$2;
    }
    return EnvironmentStatus(
      bootstrapped: true,
      completed: readyStageIds.where((id) => states[id] == 'DONE').length,
      checkFailed: exitCode != 0 || !readyStageIds.every(states.containsKey),
    );
  }

  static Future<EnvironmentStatus> inspect() => _inspect().timeout(
    const Duration(seconds: 130),
    onTimeout: () =>
        const EnvironmentStatus(bootstrapped: false, checkFailed: true),
  );

  /// 桌面端：直接查私有工具链目录，不跑 bash 脚本。
  /// 输出与 check.sh 相同的 __STAGE__ 标记，UI 的阶段卡片照旧工作。
  static Future<EnvironmentStatus> _inspectDesktop() async {
    try {
      final tc = DesktopToolchain();
      final st = await tc.status();
      final states = <String, bool>{
        'android_jdk': st.jdk,
        'android_ndk': true, // 桌面用官方 SDK；NDK 按需另装，不阻塞基本构建
        'android_cmake': true,
        'android_gradle': true, // Gradle Wrapper 自己下载到 GRADLE_USER_HOME
        'android_sdk': st.androidSdk && st.aapt2 && st.platform,
        'flutter_tools': true, // git/gh 走系统 git，缺了也不影响构建
        'flutter_sdk': st.flutter,
        'flutter_warmup': true,
      };
      final buf = StringBuffer();
      states.forEach((id, ok) {
        buf.writeln('__STAGE__$id:${ok ? 'DONE' : 'MISSING'}');
      });
      final allOk = states.values.every((v) => v);
      return EnvironmentStatus.fromCheck(
        exitCode: allOk ? 0 : 1,
        output: buf.toString(),
      );
    } catch (_) {
      return const EnvironmentStatus(bootstrapped: true, checkFailed: true);
    }
  }

  static Future<EnvironmentStatus> _inspect() async {
    if (isDesktopPlatform) return _inspectDesktop();
    try {
      final status = await Shell.instance.bootstrapStatus();
      if (status['bootstrapped'] != true) {
        return const EnvironmentStatus(bootstrapped: false);
      }
      final home = status['home'] as String? ?? '';
      if (home.isEmpty) {
        return const EnvironmentStatus(bootstrapped: true, checkFailed: true);
      }
      final prefix = status['prefix'] as String? ?? '';
      if (prefix.isEmpty) {
        return const EnvironmentStatus(bootstrapped: true, checkFailed: true);
      }
      await SetupRunner(home: home, prefix: prefix).installScripts();
      final result = await Shell.instance.exec(
        'bash ${shQuote('$home/.flit/scripts/check.sh')}',
        timeoutMs: 120000,
      );
      return EnvironmentStatus.fromCheck(
        exitCode: result['exitCode'] as int? ?? -1,
        output: result['output'] as String? ?? '',
      );
    } catch (_) {
      return const EnvironmentStatus(bootstrapped: false, checkFailed: true);
    }
  }
}
