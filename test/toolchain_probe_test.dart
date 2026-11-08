import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flit/services/toolchain/layout.dart';
import 'package:flit/services/toolchain/probe.dart';

void main() {
  late Directory root;
  late ToolchainLayout layout;
  late ToolchainProbe probe;

  String exe() => layout.windows ? '.exe' : '';
  String bat() => layout.windows ? '.bat' : '';

  void writeFile(String path, [String content = 'x']) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('flit-toolchain-probe-');
    // 与宿主平台一致：Windows CI 上验证反斜杠路径与 .exe/.bat 判据。
    layout = ToolchainLayout(
      home: root.path,
      windows: Platform.isWindows,
      baseEnvironment: <String, String>{'Path': '', 'PATH': ''},
    );
    probe = ToolchainProbe(layout: layout);
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test('empty home reports every component missing and not ready', () {
    final status = probe.inspect();
    expect(status.jdk, isFalse);
    expect(status.androidSdk, isFalse);
    expect(status.aapt2, isFalse);
    expect(status.platform, isFalse);
    expect(status.flutter, isFalse);
    expect(status.git, isFalse);
    expect(status.commandLineTools, isFalse);
    expect(status.warmup, isFalse);
    expect(status.ready, isFalse);
  });

  test('structural criteria become true once the expected files exist', () {
    writeFile(
      layout.jdkReleaseFile,
      'JAVA_VERSION="17.0.11"\nIMPLEMENTOR="Eclipse Adoptium"\n',
    );
    writeFile(layout.javaExe);
    writeFile(layout.adbExe);
    writeFile(
      layout.join(
        layout.join(layout.platformsDir, 'android-36'),
        'android.jar',
      ),
    );
    writeFile(
      layout.join(
        layout.join(layout.platformsDir, 'android-36'),
        'source.properties',
      ),
      'AndroidVersion.ApiLevel=36\n',
    );
    writeFile(
      layout.join(layout.join(layout.buildToolsDir, '36.0.0'), 'aapt2${exe()}'),
    );
    writeFile(
      layout.join(
        layout.join(layout.buildToolsDir, '36.0.0'),
        'source.properties',
      ),
      'Pkg.Revision = 36.0.0\n',
    );
    writeFile(layout.sdkManagerBat);
    writeFile(layout.sdkManagerJar);
    writeFile(layout.flutterBat);
    writeFile(layout.flutterVersionFile, '3.47.8\n');
    writeFile(layout.gitExe);
    writeFile(layout.warmupMarkerFile, '{"ok":true,"version":"3.47.8"}');

    final status = probe.inspect();
    expect(status.jdk, isTrue);
    expect(status.androidSdk, isTrue);
    expect(status.aapt2, isTrue);
    expect(status.platform, isTrue);
    expect(status.flutter, isTrue);
    expect(status.git, isTrue);
    expect(status.commandLineTools, isTrue);
    expect(status.warmup, isTrue);
    expect(status.ready, isTrue);

    // 版本从文件读，不 exec
    expect(status.versions['jdk'], '17.0.11');
    expect(status.versions['flutter'], '3.47.8');
    expect(status.versions['androidSdk'], contains('Build Tools 36.0.0'));
    expect(status.versions['androidSdk'], contains('Platform API 36'));

    final markers = status.toStageMarkers();
    expect(markers.length, 8);
    final optional = markers.firstWhere((m) => m.id == 'android_ndk');
    expect(optional.ok, isTrue);
    expect(optional.note, '按需安装');
  });

  test(
    'deleting one artifact flips exactly that component (aapt2 unbound)',
    () {
      writeFile(layout.javaExe);
      writeFile(layout.jdkReleaseFile, 'JAVA_VERSION="17.0.11"\n');
      writeFile(layout.adbExe);
      writeFile(
        layout.join(
          layout.join(layout.platformsDir, 'android-35'),
          'android.jar',
        ),
      );
      writeFile(
        layout.join(
          layout.join(layout.platformsDir, 'android-35'),
          'source.properties',
        ),
        'AndroidVersion.ApiLevel=35\n',
      );
      // 只用 35.0.0：aapt2 不应绑定默认版本。
      writeFile(
        layout.join(
          layout.join(layout.buildToolsDir, '35.0.0'),
          'aapt2${exe()}',
        ),
      );
      writeFile(
        layout.join(
          layout.join(layout.buildToolsDir, '35.0.0'),
          'source.properties',
        ),
        'Pkg.Revision = 35.0.0\n',
      );
      expect(probe.inspect().aapt2, isTrue);
      expect(probe.inspect().platform, isTrue);

      File(
        layout.join(
          layout.join(layout.buildToolsDir, '35.0.0'),
          'aapt2${exe()}',
        ),
      ).deleteSync();
      expect(probe.inspect().aapt2, isFalse);
      expect(probe.inspect().ready, isFalse);
    },
  );

  test('version parsers read jdk/release and source.properties', () {
    expect(
      ToolchainProbe.parseJdkRelease('JAVA_VERSION="17.0.11"\r\n'),
      '17.0.11',
    );
    expect(ToolchainProbe.parseJdkRelease('no version here'), isNull);
    expect(
      ToolchainProbe.parsePkgRevision(
        'Pkg.Desc = Android SDK Build-Tools 36\r\nPkg.Revision = 36.0.0\r\n',
      ),
      '36.0.0',
    );
    expect(ToolchainProbe.parsePkgRevision('Pkg.Path=foo'), isNull);
    expect(
      ToolchainProbe.parseSourceProperty(
        'AndroidVersion.ApiLevel=34\n',
        'AndroidVersion.ApiLevel',
      ),
      '34',
    );
  });

  test('modern Flutter layout is detected via bin/cache/flutter.version.json', () {
    writeFile(layout.flutterBat);
    writeFile(layout.flutterVersionJson, '{"frameworkVersion":"3.47.9"}');
    writeFile(layout.flutterDartExe);
    // Flutter 3.x 后期不再提供 <flutter>/version。
    expect(File(layout.flutterVersionFile).existsSync(), isFalse);

    final status = probe.inspect();
    expect(status.flutter, isTrue);
    expect(status.versions['flutter'], '3.47.9');
  });

  test('flutter is installed with only the SDK-bundled cache artifacts', () {
    writeFile(layout.flutterBat);
    writeFile(layout.flutterToolsSnapshot);

    final status = probe.inspect();
    expect(status.flutter, isTrue);
    // 读不到版本时不撒谎：判已安装，但版本留空。
    expect(status.versions['flutter'], isNull);
  });

  test('warmup marker without a valid JSON is not treated as warmed', () {
    writeFile(layout.flutterBat);
    writeFile(layout.flutterVersionFile, '3.47.8\n');
    writeFile(layout.warmupMarkerFile, 'not json');
    expect(probe.inspect().warmup, isFalse);
    expect(probe.warmupMarked, isFalse);

    writeFile(layout.warmupMarkerFile, '{"skipped":true}');
    expect(probe.warmupMarked, isTrue);
    expect(probe.inspect().warmup, isTrue);
  });

  test('bat suffix is platform dependent but paths stay under home', () {
    expect(layout.sdkManagerBat.endsWith(bat()), isTrue);
    expect(layout.javaExe.endsWith(exe()), isTrue);
    expect(layout.home, root.path);
  });
}
