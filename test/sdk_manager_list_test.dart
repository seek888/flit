import 'package:flutter_test/flutter_test.dart';

import 'package:flit/services/toolchain/sdk_manager.dart';

/// `sdkmanager --list` 输出解析：桌面端版本目录的唯一真值源。
void main() {
  const output = '''
[==========                             ] 26% Fetch remote repository...
Loading package information...                                                  
Installed packages:
  Path                 | Version | Description                    | Location
  -------              | ------- | -------                        | -------
  build-tools;36.0.0   | 36.0.0  | Android SDK Build-Tools 36     | build-tools\\36.0.0
  cmake;3.22.1         | 3.22.1  | CMake 3.22.1                   | cmake\\3.22.1
  platform-tools       | 37.0.1  | Android SDK Platform-Tools 37.0.1 | platform-tools

Available Packages:
  Path                              | Version       | Description
  -------                           | -------       | -------
  build-tools;35.0.0                | 35.0.0        | Android SDK Build-Tools 35
  cmake;3.22.1                      | 3.22.1        | CMake 3.22.1
  cmake;3.31.6                      | 3.31.6        | CMake 3.31.6
  ndk;28.2.13676358                 | 28.2.13676358 | NDK (Side by side) 28.2.13676358
  platforms;android-36              | 2             | Android SDK Platform 36
  system-images;android-36;google_apis;x86_64 | 2   | Google APIs Intel x86_64 Atom System Image

Available Updates:
  Path        | Version | Description
  -------     | ------- | -------
''';

  test('parses installed and available packages with descriptions', () {
    final packages = SdkManager.parseListOutput(output);
    final byPath = {for (final package in packages) package.path: package};

    expect(
      byPath['cmake;3.22.1']!.installed,
      isTrue,
      reason: 'Installed 分段优先，同一路径不重复',
    );
    expect(byPath['cmake;3.22.1']!.version, '3.22.1');
    expect(byPath['cmake;3.22.1']!.description, 'CMake 3.22.1');

    expect(byPath['cmake;3.31.6']!.installed, isFalse);
    expect(byPath['ndk;28.2.13676358']!.version, '28.2.13676358');
    expect(byPath['platforms;android-36']!.description, 'Android SDK Platform 36');
    expect(byPath['build-tools;36.0.0']!.installed, isTrue);
    expect(byPath['build-tools;35.0.0']!.installed, isFalse);
    expect(byPath['platform-tools']!.version, '37.0.1');
    expect(byPath.containsKey('system-images;android-36;google_apis;x86_64'), isTrue);
  });

  test('deduplicates the same path and sorts by path', () {
    final packages = SdkManager.parseListOutput(output);
    final paths = packages.map((package) => package.path).toList();
    expect(paths.toSet().length, paths.length);
    expect(paths, orderedEquals(List<String>.of(paths)..sort()));
  });

  test('progress noise and header rows are ignored', () {
    final packages = SdkManager.parseListOutput(output);
    expect(
      packages.any((package) => package.path.contains('Fetch remote')),
      isFalse,
    );
    expect(packages.any((package) => package.path == 'Path'), isFalse);
    expect(
      packages.any((package) => package.path.startsWith('-------')),
      isFalse,
    );
  });

  test('empty output parses to an empty list', () {
    expect(SdkManager.parseListOutput(''), isEmpty);
    expect(SdkManager.parseListOutput('Loading package information...'), isEmpty);
  });
}