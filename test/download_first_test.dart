import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flit/services/toolchain/download.dart';
import 'package:flit/services/toolchain/errors.dart';
import 'package:flit/services/toolchain/hash.dart';

/// 多源下载回退的单测：完全离线，注入 fake transport。
void main() {
  late Directory root;
  late String destination;

  setUp(() {
    root = Directory.systemTemp.createTempSync('flit-download-first-');
    destination = '${root.path}${Platform.pathSeparator}pkg.bin';
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  final bytes = Uint8List.fromList(
    List<int>.generate(1200 * 1024, (index) => index % 251),
  );

  test('falls back to the next source when a mirror returns HTTP 500', () async {
    const mirror = 'https://mirror.invalid/pkg.bin';
    const official = 'https://official.invalid/pkg.bin';
    final transport = _FakeTransport(<String, _FakeResponse>{
      mirror: _FakeResponse.error(500),
      official: _FakeResponse.ok(bytes),
    });
    final downloader = Downloader(transport: transport);

    final result = await downloader.downloadFirst(<String>[
      mirror,
      official,
    ], destination, label: 'pkg');

    expect(result.url, official);
    expect(File(destination).lengthSync(), bytes.length);
    expect(transport.requested, <String>[mirror, official]);
  });

  test('falls back when the mirror content does not match the SHA-256', () async {
    const mirror = 'https://mirror.invalid/pkg.bin';
    const official = 'https://official.invalid/pkg.bin';
    final wrong = Uint8List.fromList(List<int>.filled(1200 * 1024, 7));
    final transport = _FakeTransport(<String, _FakeResponse>{
      mirror: _FakeResponse.ok(wrong),
      official: _FakeResponse.ok(bytes),
    });
    final downloader = Downloader(transport: transport);

    final result = await downloader.downloadFirst(
      <String>[mirror, official],
      destination,
      sha256: sha256Hex(bytes),
      label: 'pkg',
    );

    expect(result.url, official);
    expect(result.sha256, sha256Hex(bytes));
    expect(transport.requested, <String>[mirror, official]);
  });

  test('a matching cached file is reused without any request', () async {
    File(destination).writeAsBytesSync(bytes);
    final transport = _FakeTransport(const <String, _FakeResponse>{});
    final downloader = Downloader(transport: transport);

    final result = await downloader.downloadFirst(
      <String>['https://mirror.invalid/pkg.bin'],
      destination,
      sha256: sha256Hex(bytes),
      label: 'pkg',
    );

    expect(result.url, 'https://mirror.invalid/pkg.bin');
    expect(transport.requested, isEmpty);
  });

  test('all sources failing reports every attempted URL', () async {
    const first = 'https://mirror.invalid/pkg.bin';
    const second = 'https://official.invalid/pkg.bin';
    final transport = _FakeTransport(<String, _FakeResponse>{
      first: _FakeResponse.error(502),
      second: _FakeResponse.error(404),
    });
    final downloader = Downloader(transport: transport);

    await expectLater(
      downloader.downloadFirst(<String>[first, second], destination, label: 'pkg'),
      throwsA(
        isA<DownloadException>().having(
          (error) => error.message,
          'message',
          allOf(contains(first), contains(second)),
        ),
      ),
    );
    expect(File(destination).existsSync(), isFalse);
    expect(File('$destination.part').existsSync(), isFalse);
  });

  test('empty and duplicate candidates are skipped', () async {
    const url = 'https://official.invalid/pkg.bin';
    final transport = _FakeTransport(<String, _FakeResponse>{
      url: _FakeResponse.ok(bytes),
    });
    final downloader = Downloader(transport: transport);

    final result = await downloader.downloadFirst(
      <String>['', url, url],
      destination,
      label: 'pkg',
    );

    expect(result.url, url);
    expect(transport.requested, <String>[url]);
  });
}

class _FakeResponse {
  _FakeResponse._(this.statusCode, this.bytes);

  factory _FakeResponse.ok(List<int> bytes) =>
      _FakeResponse._(200, Uint8List.fromList(bytes));

  factory _FakeResponse.error(int statusCode) =>
      _FakeResponse._(statusCode, Uint8List(0));

  final int statusCode;
  final Uint8List bytes;
}

class _FakeTransport implements HttpTransport {
  _FakeTransport(this.responses);

  final Map<String, _FakeResponse> responses;
  final List<String> requested = <String>[];

  @override
  Future<HttpFetchResult> open(
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    final key = uri.toString();
    requested.add(key);
    final response = responses[key];
    if (response == null) {
      throw const SocketException('no fake response registered');
    }
    final body = response.statusCode >= 400
        ? const Stream<List<int>>.empty()
        : Stream<List<int>>.value(response.bytes);
    return HttpFetchResult(
      statusCode: response.statusCode,
      finalUri: uri,
      headers: const <String, String>{},
      body: body,
      contentLength: response.statusCode >= 400 ? 0 : response.bytes.length,
    );
  }
}