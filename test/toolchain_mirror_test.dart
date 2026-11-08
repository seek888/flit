import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flit/services/toolchain/installer.dart';
import 'package:flit/services/toolchain/layout.dart';
import 'package:flit/services/toolchain/sdk_manager.dart';

/// 国内镜像/下载源的单测：全部只看 URL/环境变量/文件判据，不触网。
void main() {
  late Directory root;
  late ToolchainLayout layout;

  void writeFile(String path, [String content = 'x']) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('flit-toolchain-mirror-');
    layout = ToolchainLayout(
      home: root.path,
      windows: true,
      baseEnvironment: <String, String>{'Path': ''},
    );
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test('Android SDK defaults to the Tencent mirror with a repo template', () {
    expect(
      layout.androidSdkRepo,
      'https://mirrors.cloud.tencent.com/AndroidSDK',
    );
    expect(layout.androidSdkMirrored, isTrue);
    expect(
      layout.cmdlineToolsUrl,
      'https://mirrors.cloud.tencent.com/AndroidSDK/'
      'commandlinetools-win-${ToolchainLayout.cmdlineToolsBuild}_latest.zip',
    );
    expect(
      layout.sdkRepoOverride,
      'https://mirrors.cloud.tencent.com/AndroidSDK/',
      reason: 'sdkmanager 的 SDK_TEST_BASE_URL 必须是带尾斜杠的目录 URL',
    );
  });

  test('childEnvironment injects mirror variables for child processes', () {
    final environment = layout.childEnvironment();
    expect(
      environment['SDK_TEST_BASE_URL'],
      'https://mirrors.cloud.tencent.com/AndroidSDK/',
    );
    expect(environment['PUB_HOSTED_URL'], 'https://pub.flutter-io.cn');
    expect(
      environment['FLUTTER_STORAGE_BASE_URL'],
      'https://storage.flutter-io.cn',
    );
  });

  test('official SDK base disables the template and restores Google URLs', () {
    final official = ToolchainLayout(
      home: root.path,
      windows: true,
      baseEnvironment: <String, String>{'Path': ''},
      androidSdkRepoBase: ToolchainLayout.officialAndroidSdkBase,
    );
    expect(official.androidSdkMirrored, isFalse);
    expect(official.sdkRepoOverride, isNull);
    expect(official.cmdlineToolsUrl, official.officialCmdlineToolsUrl);
    expect(
      official.cmdlineToolsUrl,
      contains('https://dl.google.com/android/repository/'),
    );
    expect(official.childEnvironment().containsKey('SDK_TEST_BASE_URL'), isFalse);
  });

  test('an inherited SDK_TEST_BASE_URL never leaks into the child env', () {
    final inherited = ToolchainLayout(
      home: root.path,
      windows: true,
      baseEnvironment: <String, String>{
        'Path': '',
        'SDK_TEST_BASE_URL': 'http://poison.invalid/{url}',
      },
      androidSdkRepoBase: ToolchainLayout.officialAndroidSdkBase,
    );
    expect(inherited.childEnvironment()['SDK_TEST_BASE_URL'], isNull);
  });

  test('installer download candidates prefer the mirror, then Google', () {
    final installer = ToolchainInstaller(layout: layout);
    final urls = installer.cmdlineToolsUrls;
    expect(urls.length, 2);
    expect(urls.first, contains('mirrors.cloud.tencent.com'));
    expect(urls.last, contains('dl.google.com'));
    expect(installer.downloadSourceSummary, contains('腾讯镜像'));
    expect(installer.downloadSourceSummary, contains('storage.flutter-io.cn'));
  });

  test('parseJdkMirrorListing picks the newest build and builds absolute URL', () {
    const base = 'https://mirror.invalid/Adoptium/17/jdk/x64/windows';
    const html = '''
      <a href="../">Parent directory/</a>
      <a href="OpenJDK17U-jdk_x64_windows_hotspot_17.0.9_3.zip">old</a>
      <a href="OpenJDK17U-jdk_x64_windows_hotspot_17.0.20.1_1.zip">new</a>
      <a href="OpenJDK17U-jdk_x64_windows_hotspot_17.0.20.1_1.msi">msi</a>
    ''';
    final parsed = ToolchainInstaller.parseJdkMirrorListing(
      html,
      baseUrl: '$base/',
    );
    expect(parsed, isNotNull);
    expect(
      parsed!.url,
      '$base/OpenJDK17U-jdk_x64_windows_hotspot_17.0.20.1_1.zip',
    );
    expect(parsed.version, '17.0.20.1+1');
  });

  test('parseJdkMirrorListing returns null when no zip is listed', () {
    expect(
      ToolchainInstaller.parseJdkMirrorListing(
        '<a href="notes.txt">x</a>',
        baseUrl: 'https://mirror.invalid/Adoptium',
      ),
      isNull,
    );
  });

  test('sdkmanager uses the real classpath jar and the toolsdir property', () {
    final missing = SdkManager(layout: layout);
    expect(missing.classpathJar, isNull);
    expect(missing.available, isFalse);

    writeFile(layout.javaExe);
    writeFile(layout.sdkManagerClasspathJar);
    final manager = SdkManager(layout: layout);
    expect(manager.available, isTrue);
    final prefix = manager.commandPrefix;
    expect(
      prefix,
      contains('-Dcom.android.sdklib.toolsdir=${layout.cmdlineToolsDir}'),
    );
    final classpathIndex = prefix.indexOf('-classpath');
    expect(classpathIndex, greaterThanOrEqualTo(0));
    expect(prefix[classpathIndex + 1], layout.sdkManagerClasspathJar);
    expect(
      prefix,
      contains('com.android.sdklib.tool.sdkmanager.SdkManagerCli'),
    );
    expect(prefix, contains('--sdk_root=${layout.sdkDir}'));
    expect(manager.repositorySource, contains('mirrors.cloud.tencent.com'));
  });

  test('legacy lib/sdkmanager.jar layouts still resolve', () {
    writeFile(layout.javaExe);
    writeFile(layout.sdkManagerLegacyJar);
    final manager = SdkManager(layout: layout);
    expect(manager.classpathJar, layout.sdkManagerLegacyJar);
    expect(manager.commandPrefix, contains(layout.sdkManagerLegacyJar));
  });

  test('sdkmanager rejects an install before cmdline-tools exists', () async {
    // install() 是 async*，异常在订阅时才抛出。
    await expectLater(
      SdkManager(layout: layout).install(<String>['platform-tools']).drain<void>(),
      throwsA(isA<Exception>()),
    );
  });

  test('official Flutter source is only used when explicitly configured', () {
    final official = ToolchainLayout(
      home: root.path,
      windows: true,
      baseEnvironment: <String, String>{'Path': ''},
      flutterStorageBaseUrl: ToolchainLayout.officialFlutterStorageBaseUrl,
    );
    expect(
      official.flutterStorageBaseUrl,
      ToolchainLayout.officialFlutterStorageBaseUrl,
    );
    expect(layout.flutterStorageBaseUrl, 'https://storage.flutter-io.cn');
    expect(ToolchainLayout.defaultPubHostedUrl, 'https://pub.flutter-io.cn');
    expect(
      ToolchainLayout.defaultFlutterStorageBaseUrl,
      'https://storage.flutter-io.cn',
    );
  });
}