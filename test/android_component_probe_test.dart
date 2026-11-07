import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flit/features/environment/android_build_wrapper.dart';
import 'package:flit/features/environment/android_component_probe.dart';
import 'package:flit/features/environment/toolchain_catalog.dart';
import 'package:flit/services/paths.dart';

/// 桌面端组件探测 = `android_components.sh` + `component_checks.sh` 的纯 Dart 等价物。
/// 用临时 SDK 目录验证 baseline / device / 项目声明三种语义，不执行任何进程。
void main() {
  late Directory temp;

  void write(String relative, [String content = 'x']) {
    final file = File(joinPath(temp.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  String sdkPath() => joinPath(temp.path, 'sdk');

  void installBuildTools(String version) {
    write(
      'sdk/build-tools/$version/source.properties',
      'Pkg.Revision=$version\n',
    );
    write('sdk/build-tools/$version/lib/d8.jar');
    for (final name in [
      'd8',
      'apksigner',
      'aidl',
      'zipalign',
      'aapt',
      'aapt2',
    ]) {
      write('sdk/build-tools/$version/$name');
    }
  }

  void installPlatforms(String api) {
    write('sdk/platforms/android-$api/android.jar');
    write(
      'sdk/platforms/android-$api/source.properties',
      'Pkg.Revision=$api\n',
    );
  }

  void installPlatformTools() => write('sdk/platform-tools/adb');

  void installCmdlineTools() {
    write('sdk/cmdline-tools/latest/bin/sdkmanager');
    write('sdk/cmdline-tools/latest/lib/sdkmanager.jar');
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('flit-probe-');
    write('jdk/bin/java');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  AndroidComponentProbe probe({String? javaExe}) => AndroidComponentProbe(
    sdkDir: sdkPath(),
    javaExe: javaExe ?? joinPath(temp.path, 'jdk/bin/java'),
  );

  test(
    'baseline reports the default build-tools when no aapt2 exists',
    () async {
      final missing = await probe().check(const [], baseline: true);
      expect(missing.map((c) => c.key), ['build-tools:36.0.0']);
    },
  );

  test('baseline accepts any build-tools version that ships aapt2', () async {
    // baseline 不绑定项目声明的版本：任一版本有可用 aapt2 即可。
    installBuildTools('35.0.0');
    expect(await probe().check(const [], baseline: true), isEmpty);
  });

  test('baseline with a broken JDK fails like the shell script', () async {
    await expectLater(
      probe(
        javaExe: joinPath(temp.path, 'missing/java'),
      ).check(const [], baseline: true),
      throwsStateError,
    );
  });

  test(
    'device flag only requires platform-tools and never checks the JDK',
    () async {
      // 没有 JDK 也不影响 device 检查（脚本的 --device 只查 platform-tools）。
      final missing = await probe(
        javaExe: joinPath(temp.path, 'missing/java'),
      ).check(const [], device: true);
      expect(missing.map((c) => c.key), ['platform-tools']);
      installPlatformTools();
      expect(
        await probe(
          javaExe: joinPath(temp.path, 'missing/java'),
        ).check(const [], device: true),
        isEmpty,
      );
    },
  );

  test('declared gradle literals are matched by exact version', () async {
    installBuildTools('36.0.0');
    installPlatforms('36');
    installCmdlineTools();
    final declared = AndroidBuildWrapper.declaredComponents('''
compileSdk = 36
buildToolsVersion "36.0.0"
''');
    expect(declared.map((c) => c.key), ['platforms:36', 'build-tools:36.0.0']);
    expect(await probe().check(declared), isEmpty);

    // 项目要 35 但只装了 36：build-tools 版本必须精确匹配（Pkg.Revision）。
    final mismatched = AndroidBuildWrapper.declaredComponents('''
compileSdk = 36
buildToolsVersion "35.0.0"
''');
    expect((await probe().check(mismatched)).map((c) => c.key), [
      'build-tools:35.0.0',
    ]);

    // 缺 Platform 时按声明版本报告。
    final platform = AndroidBuildWrapper.declaredComponents('compileSdk = 34');
    expect((await probe().check(platform)).map((c) => c.key), ['platforms:34']);
  });

  test('missing cmdline-tools is reported for repair', () async {
    const component = AndroidComponent('cmdline-tools');
    expect((await probe().check(const [component])).map((c) => c.key), [
      'cmdline-tools:',
    ]);
    installCmdlineTools();
    expect(await probe().check(const [component]), isEmpty);
  });

  test(
    'build-tools must be complete (d8/apksigner/aapt2 all present)',
    () async {
      installBuildTools('36.0.0');
      final probe36 = probe();
      const component = AndroidComponent('build-tools', '36.0.0');
      expect(await probe36.check(const [component]), isEmpty);
      // 删掉 aapt2：整套视为不可用，需要重装。
      File(joinPath(sdkPath(), 'build-tools/36.0.0/aapt2')).deleteSync();
      expect((await probe36.check(const [component])).map((c) => c.key), [
        'build-tools:36.0.0',
      ]);
    },
  );

  test('default build-tools version matches the catalog constant', () {
    expect(
      AndroidComponentProbe.defaultBuildToolsVersion,
      ToolchainCatalog.sdkVersion,
    );
  });
}
