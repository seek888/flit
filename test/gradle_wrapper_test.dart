import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flit/services/toolchain/archive.dart';
import 'package:flit/services/toolchain/download.dart';
import 'package:flit/services/toolchain/gradle_wrapper.dart';
import 'package:flit/services/toolchain/layout.dart';
import 'package:flit/services/toolchain/process.dart';

/// Gradle 发行版预置：布局、`.ok` 标记、镜像回退、缓存命中。
void main() {
  late Directory root;
  late Directory project;
  late ToolchainLayout layout;
  late String propertiesPath;

  const distributionUrl =
      'https://services.gradle.org/distributions/gradle-9.3.1-all.zip';

  setUp(() {
    root = Directory.systemTemp.createTempSync('flit-gradle-wrapper-');
    project = Directory('${root.path}${Platform.pathSeparator}proj')
      ..createSync(recursive: true);
    layout = ToolchainLayout(
      home: root.path,
      windows: true,
      baseEnvironment: <String, String>{'Path': ''},
    );
    propertiesPath = layout.join(
      project.path,
      'android${Platform.pathSeparator}gradle${Platform.pathSeparator}'
          'wrapper${Platform.pathSeparator}gradle-wrapper.properties',
    );
    final file = File(propertiesPath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      'distributionBase=GRADLE_USER_HOME\n'
      'distributionPath=wrapper/dists\n'
      'distributionUrl=https\\://services.gradle.org/distributions/'
          'gradle-9.3.1-all.zip\n'
      'zipStoreBase=GRADLE_USER_HOME\n'
      'zipStorePath=wrapper/dists\n',
    );
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test('parses java-properties escapes and optional checksum', () {
    final parsed = GradleWrapperCache.parseProperties(
      'distributionUrl=https\\://services.gradle.org/distributions/gradle-8.14-bin.zip\n'
      'distributionSha256Sum=abcd\n',
    );
    expect(parsed, isNotNull);
    expect(
      parsed!.distributionUrl,
      'https://services.gradle.org/distributions/gradle-8.14-bin.zip',
    );
    expect(parsed.distributionSha256Sum, 'abcd');
    expect(GradleWrapperCache.parseProperties('distributionBase=X'), isNull);
  });

  test('distribution dir is the wrapper cache path (name + base36 url hash)', () {
    final cache = GradleWrapperCache(layout: layout);
    final dir = cache.distributionDir(distributionUrl);
    expect(
      dir,
      '${layout.gradleHome}\\wrapper\\dists\\gradle-9.3.1-all'
      '\\9ot9r568e8zfvvd4mn8rbu1j0',
    );
    expect(cache.wrapperPropertiesFile(project.path), isNotNull);
  });

  test('ensure downloads from the domestic mirror and writes the .ok marker', () async {
    final cache = GradleWrapperCache(
      layout: layout,
      downloader: Downloader(transport: _FakeTransport()),
      archive: _FakeArchive(),
      mirrorBaseUrl: 'https://mirrors.cloud.tencent.com/gradle',
    );

    final lines = await cache.ensure(project.path).toList();
    expect(lines.join('\n'), contains('Gradle 9.3.1'));
    expect(
      lines.join('\n'),
      contains('https://mirrors.cloud.tencent.com/gradle/gradle-9.3.1-all.zip'),
    );

    final target = cache.distributionDir(distributionUrl);
    expect(Directory('$target\\gradle-9.3.1\\bin').existsSync(), isTrue);
    expect(File('$target\\gradle-9.3.1-all.zip.ok').existsSync(), isTrue);
    expect(File('$target\\gradle-9.3.1-all.zip.ok').lengthSync(), 0);
    expect(cache.isReady(distributionUrl), isTrue);
  });

  test('a ready distribution is reused with no network at all', () async {
    final first = GradleWrapperCache(
      layout: layout,
      downloader: Downloader(transport: _FakeTransport()),
      archive: _FakeArchive(),
      mirrorBaseUrl: 'https://mirrors.cloud.tencent.com/gradle',
    );
    await first.ensure(project.path).drain<void>();
    expect(first.isReady(distributionUrl), isTrue);

    final transport = _FakeTransport();
    final second = GradleWrapperCache(
      layout: layout,
      downloader: Downloader(transport: transport),
      archive: _FakeArchive(),
    );
    final lines = await second.ensure(project.path).toList();
    expect(lines.join('\n'), contains('跳过下载'));
    expect(transport.requested, isEmpty);
  });

  test('missing .ok marker counts as not ready (wrapper would re-download)', () async {
    final cache = GradleWrapperCache(
      layout: layout,
      downloader: Downloader(transport: _FakeTransport()),
      archive: _FakeArchive(),
    );
    await cache.ensure(project.path).drain<void>();
    final target = cache.distributionDir(distributionUrl);
    File('$target\\gradle-9.3.1-all.zip.ok').deleteSync();
    expect(cache.isReady(distributionUrl), isFalse);
  });

  test('project without a wrapper is skipped instead of failing', () async {
    final other = Directory('${root.path}${Platform.pathSeparator}plain')
      ..createSync(recursive: true);
    final cache = GradleWrapperCache(layout: layout);
    final lines = await cache.ensure(other.path).toList();
    expect(lines.join('\n'), contains('没有 Gradle Wrapper'));
    expect(cache.isReady(distributionUrl), isFalse);
  });

  test('all mirrors failing reports the attempted sources', () async {
    final cache = GradleWrapperCache(
      layout: layout,
      downloader: Downloader(transport: _FailingTransport()),
      archive: _FakeArchive(),
      mirrorBaseUrl: 'https://mirrors.cloud.tencent.com/gradle',
      fallbackBaseUrls: const <String>[],
    );
    await expectLater(
      cache.ensure(project.path).drain<void>(),
      throwsA(
        isA<Exception>().having(
          (error) => '$error',
          'message',
          allOf(
            contains('mirrors.cloud.tencent.com'),
            contains('services.gradle.org'),
          ),
        ),
      ),
    );
  });
}

class _FakeTransport implements HttpTransport {
  final List<String> requested = <String>[];

  @override
  Future<HttpFetchResult> open(Uri uri, {Map<String, String>? headers}) async {
    requested.add(uri.toString());
    final bytes = Uint8List.fromList(List<int>.filled(1024, 1));
    return HttpFetchResult(
      statusCode: 200,
      finalUri: uri,
      headers: const <String, String>{},
      body: Stream<List<int>>.value(bytes),
      contentLength: bytes.length,
    );
  }
}

class _FailingTransport implements HttpTransport {
  @override
  Future<HttpFetchResult> open(Uri uri, {Map<String, String>? headers}) async {
    throw const SocketException('unreachable in test');
  }
}

class _FakeArchive extends ArchiveExtractor {
  _FakeArchive() : super(process: const _NoopProcess(), windows: true);

  @override
  Future<void> extract(String archive, String destination) async {
    final bin =
        '$destination${Platform.pathSeparator}gradle-9.3.1'
        '${Platform.pathSeparator}bin';
    Directory(bin).createSync(recursive: true);
    File('$bin${Platform.pathSeparator}gradle.bat').writeAsStringSync('@echo off');
  }
}

class _NoopProcess implements ToolchainProcessGateway {
  const _NoopProcess();

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 25),
    String? workingDirectory,
  }) async => ProcessResult(0, 0, '', '');

  @override
  Future<int> runWithStdin(
    String executable,
    List<String> arguments, {
    String stdinText = '',
    Map<String, String>? environment,
    Duration timeout = const Duration(minutes: 5),
    String? workingDirectory,
  }) async => 0;

  @override
  Stream<String> stream(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    Duration timeout = const Duration(minutes: 30),
    String? workingDirectory,
    void Function(int exitCode)? onClosed,
  }) async* {
    onClosed?.call(0);
  }
}