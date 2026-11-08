import 'package:flutter_test/flutter_test.dart';

import 'package:flit/features/environment/toolchain_catalog.dart';
import 'package:flit/services/toolchain/installer.dart' show FlutterReleaseInfo;
import 'package:flit/services/toolchain/sdk_manager.dart';

/// 桌面端「版本目录」不再查 GitHub：Android 组件来自 sdkmanager 包列表，
/// Flutter 来自镜像清单。这里只测纯映射，不触网。
void main() {
  const packages = <SdkPackage>[
    (path: 'platforms;android-36', version: '2', description: 'Platform 36', installed: true),
    (path: 'build-tools;36.0.0', version: '36.0.0', description: 'Build-Tools 36', installed: true),
    (path: 'ndk;28.2.13676358', version: '28.2.13676358', description: 'NDK 28', installed: false),
    (path: 'ndk;27.2.12479018', version: '27.2.12479018', description: 'NDK 27', installed: false),
    (path: 'cmake;3.31.6', version: '3.31.6', description: 'CMake 3.31.6', installed: false),
    (path: 'cmake;3.22.1', version: '3.22.1', description: 'CMake 3.22.1', installed: true),
    (path: 'platform-tools', version: '37.0.1', description: 'Platform-Tools', installed: true),
    (
      path: 'system-images;android-36;google_apis;x86_64',
      version: '2',
      description: 'System image',
      installed: false,
    ),
  ];

  test('maps SDK packages to catalog entries with existing tag conventions', () {
    final entries = ToolchainCatalog.desktopEntries(packages);
    final tags = entries.map((entry) => entry.tag).toSet();

    expect(tags, contains('platform-36'));
    expect(tags, contains('sdk-36.0.0'));
    expect(tags, contains('ndk-28.2.13676358'));
    expect(tags, contains('ndk-27.2.12479018'));
    expect(tags, contains('cmake-3.31.6'));
    expect(tags, contains('cmake-3.22.1'));
    // 共享工具与系统镜像不作为可下载版本列出。
    expect(tags.any((tag) => tag.startsWith('system-images')), isFalse);
    expect(entries.every((entry) => entry.url.startsWith('sdkmanager:')), isTrue);
  });

  test('newest versions come first', () {
    final cmake = ToolchainCatalog.desktopEntries(packages)
        .where((entry) => entry.component == 'cmake')
        .map((entry) => entry.tag)
        .toList();
    expect(cmake, <String>['cmake-3.31.6', 'cmake-3.22.1']);

    final ndk = ToolchainCatalog.desktopEntries(packages)
        .where((entry) => entry.component == 'ndk')
        .map((entry) => entry.tag)
        .toList();
    expect(ndk, <String>['ndk-28.2.13676358', 'ndk-27.2.12479018']);
  });

  test('descriptions become display names', () {
    final cmake = ToolchainCatalog.desktopEntries(packages).firstWhere(
      (entry) => entry.tag == 'cmake-3.22.1',
    );
    expect(cmake.name, 'CMake 3.22.1');
    expect(cmake.component, 'cmake');
  });

  test('Flutter mirror releases become flutter-sdk entries', () {
    const releases = <FlutterReleaseInfo>[
      (
        version: '3.47.9',
        url: 'https://storage.flutter-io.cn/flutter_infra_release/releases/'
            'stable/windows/flutter_windows_3.47.9-stable.zip',
        archiveName: 'flutter_windows_3.47.9-stable.zip',
        sha256:
            'd8e2b5977e09082c6440f89dc1aa887b94c8fbcc3b39222797046295a3f68a9e',
      ),
    ];
    final entries = ToolchainCatalog.desktopFlutterEntries(releases);
    expect(entries.single.component, 'flutter-sdk');
    expect(entries.single.tag, 'flutter-3.47.9');
    expect(entries.single.sha256, releases.single.sha256);
    expect(entries.single.url, contains('storage.flutter-io.cn'));
  });

  test('desktop default tags match what the SDK stage installs', () {
    expect(ToolchainCatalog.desktopSources['platforms']!.defaultTag, 'platform-36');
    expect(ToolchainCatalog.desktopSources['build-tools']!.defaultTag, 'sdk-36.0.0');
    expect(
      ToolchainCatalog.desktopSources['ndk']!.defaultTag,
      'ndk-28.2.13676358',
    );
    expect(ToolchainCatalog.desktopSources['cmake']!.defaultTag, 'cmake-3.22.1');
    // 桌面端目录不应再依赖 GitHub 仓库。
    for (final source in ToolchainCatalog.desktopSources.values) {
      expect(source.repo, isEmpty);
    }
  });
}