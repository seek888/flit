import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flit/features/environment/desktop_setup_runner.dart';
import 'package:flit/services/desktop_toolchain.dart';

/// 桌面端「已安装组件」判据：目录名与路径拼接必须一致。
///
/// 回归点：`platforms` 的目录名本身是 `android-36`，扫描已装目录时拿到的
/// version 就是目录名；如果路径拼成 `platforms/android-android-36`，
/// 装好的 Platform 会永远显示「未安装」（截图中的真实缺陷）。
void main() {
  late Directory root;
  late ToolchainLayout layout;

  void writeFile(String relative, [String content = 'x']) {
    final file = File(layout.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  String sep(String relative) => relative.replaceAll('/', Platform.pathSeparator);

  void writePlatform(String dirName, {String api = '36'}) {
    writeFile(
      sep('android-sdk/platforms/$dirName/android.jar'),
      'jar',
    );
    writeFile(
      sep('android-sdk/platforms/$dirName/source.properties'),
      'AndroidVersion.ApiLevel=$api\n',
    );
  }

  void writeBuildTools(String version) {
    final base = 'android-sdk/build-tools/$version';
    for (final exe in <String>['aapt2.exe', 'd8.bat', 'apksigner.bat', 'aidl.exe', 'zipalign.exe', 'aapt.exe']) {
      writeFile(sep('$base/$exe'));
    }
    writeFile(sep('$base/lib/d8.jar'), 'jar');
    writeFile(
      sep('$base/source.properties'),
      'Pkg.Revision = $version\n',
    );
  }

  void writeNdk(String revision) {
    final base = 'android-sdk/ndk/$revision';
    writeFile(sep('$base/source.properties'), 'Pkg.Revision = $revision\n');
    writeFile(
      sep('$base/toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe'),
    );
  }

  void writeCmake(String version) {
    final base = 'android-sdk/cmake/$version';
    writeFile(sep('$base/source.properties'), 'Pkg.Revision = $version\n');
    writeFile(sep('$base/bin/cmake.exe'));
    writeFile(sep('$base/bin/ninja.exe'));
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('flit-desktop-probe-');
    layout = ToolchainLayout(
      home: root.path,
      windows: true,
      baseEnvironment: <String, String>{'Path': ''},
    );
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test('an installed platform is reported even though its dir has android- prefix', () {
    writePlatform('android-36');
    final probe = DesktopComponentProbe(layout: layout);

    expect(probe.usable(const (id: 'platforms', version: '36')), isTrue);
    expect(probe.usable(const (id: 'platforms', version: 'android-36')), isTrue);
    expect(probe.usable(const (id: 'platforms', version: '37.2')), isFalse);

    final installed = probe.installedComponents();
    expect(
      installed.where((entry) => entry.id == 'platforms').map((entry) => entry.version),
      contains('android-36'),
    );
  });

  test('runner listInstalled resolves the platform directory correctly', () async {
    writePlatform('android-36');
    final runner = DesktopSetupRunner(
      toolchain: DesktopToolchain(layout: layout),
    );

    final installed = await runner.listInstalled();
    final paths = installed.map((tool) => tool.path).toList();
    expect(paths, contains('android-sdk/platforms/android-36'));
    expect(
      installed.any((tool) => tool.component == 'platforms' && tool.version == 'android-36'),
      isTrue,
    );
  });

  test('build-tools, ndk and cmake are recognised when complete', () {
    writeBuildTools('36.0.0');
    writeNdk('28.2.13676358');
    writeCmake('3.22.1');
    final probe = DesktopComponentProbe(layout: layout);

    expect(probe.usable(const (id: 'build-tools', version: '36.0.0')), isTrue);
    expect(probe.usable(const (id: 'ndk', version: '28.2.13676358')), isTrue);
    expect(probe.usable(const (id: 'cmake', version: '3.22.1')), isTrue);
  });

  test('incomplete build-tools is not usable', () {
    writeBuildTools('36.0.0');
    File(
      layout.join(
        root.path,
        sep('android-sdk/build-tools/36.0.0/apksigner.bat'),
      ),
    ).deleteSync();
    final probe = DesktopComponentProbe(layout: layout);
    expect(probe.usable(const (id: 'build-tools', version: '36.0.0')), isFalse);
  });
}