import 'package:flutter_test/flutter_test.dart';
import 'package:flit/core/host_platform.dart';
import 'package:flit/features/workspace/project_actions.dart';

/// 构建命令的平台分支断言（纯函数，不启动进程）。
///
/// Windows 上「打包 APK」必须直接跑 `flutter build apk`：脚本前缀
/// （`bash "$HOME/.flit/scripts/android_build.sh"`）在 cmd 里不存在 bash，
/// 也不能依赖 console 的字符串归一化把它剥掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => setHostPlatform(null));

  test('desktop APK commands have no bash / $HOME / .flit scripts prefix', () {
    final debug = buildApkCommand(release: false, desktop: true);
    final release = buildApkCommand(release: true, desktop: true);
    expect(
      debug,
      'flutter build apk --debug --target-platform android-arm64 2>&1',
    );
    expect(
      release,
      'flutter build apk --release --target-platform android-arm64 2>&1',
    );
    for (final command in [debug, release]) {
      expect(command, isNot(contains('bash')));
      expect(command, isNot(contains(r'$HOME')));
      expect(command, isNot(contains('.flit/scripts')));
    }
  });

  test('Android APK commands keep the script environment prefix', () {
    final command = buildApkCommand(release: false, desktop: false);
    expect(
      command,
      'bash "\$HOME/.flit/scripts/android_build.sh" '
      'flutter build apk --debug --target-platform android-arm64 2>&1',
    );
  });

  test('APK artifact paths are stable and platform independent', () {
    expect(
      ProjectBuild.debugApk.resolvedArtifactPath,
      'build/app/outputs/flutter-apk/app-debug.apk',
    );
    expect(
      ProjectBuild.releaseApk.resolvedArtifactPath,
      'build/app/outputs/flutter-apk/app-release.apk',
    );
    setHostPlatform(HostPlatform.windows);
    expect(
      ProjectBuild.releaseApk.configuration.artifactPath,
      'build/app/outputs/flutter-apk/app-release.apk',
    );
  });

  test('web build keeps its command and gains an artifact entry', () {
    expect(buildWebCommand, 'flutter build web --release 2>&1');
    setHostPlatform(HostPlatform.windows);
    expect(ProjectBuild.web.configuration.command, buildWebCommand);
    expect(ProjectBuild.web.configuration.artifactPath, 'build/web');
    // Android 没有目录型文件卡：用 index.html 作为入口，避免打开目录失败。
    setHostPlatform(HostPlatform.android);
    expect(ProjectBuild.web.configuration.artifactPath, 'build/web/index.html');
  });

  test('ProjectBuild.command follows the host seam (windows vs android)', () {
    setHostPlatform(HostPlatform.windows);
    expect(
      ProjectBuild.debugApk.configuration.command,
      isNot(contains('bash')),
    );
    expect(
      ProjectBuild.debugApk.configuration.command,
      contains('flutter build apk --debug'),
    );
    setHostPlatform(HostPlatform.android);
    expect(
      ProjectBuild.debugApk.configuration.command,
      startsWith('bash "\$HOME/.flit/scripts/android_build.sh" '),
    );
  });

  test('desktop device run command has no bash prefix', () {
    final desktop = flutterRunCommand('127.0.0.1:5555', desktop: true);
    expect(desktop, 'flutter run -d "127.0.0.1:5555" 2>&1');
    expect(desktop, isNot(contains('bash')));
    final android = flutterRunCommand('127.0.0.1:5555', desktop: false);
    expect(android, contains('android_build.sh'));
    expect(android, contains("'127.0.0.1:5555'"));
  });

  test('dart compile exe uses baseName and never mkdir -p', () {
    final desktop = dartExeCommand('/projects/My App', desktop: true);
    expect(
      desktop,
      'dart compile exe "bin/My App.dart" -o "build/My App" 2>&1',
    );
    expect(desktop, isNot(contains('mkdir')));

    // Windows 绝对路径：baseName 必须取最后一段，而不是整条路径。
    final windows = dartExeCommand(
      r'C:\Users\me\projects\demo_app',
      desktop: true,
    );
    expect(windows, contains('bin/demo_app.dart'));
    expect(windows, contains(r'C:\Users'));

    final android = dartExeCommand('/projects/demo', desktop: false);
    expect(android, "dart compile exe 'bin/demo.dart' -o 'build/demo' 2>&1");
    expect(android, isNot(contains('mkdir')));
  });

  test('dart exe task id is stable so the build dir can be pre-created', () {
    expect(dartExeConfigurationId, 'build-dart-exe');
  });
}
