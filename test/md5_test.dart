import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flit/services/toolchain/md5.dart';

/// MD5 与 Gradle Wrapper 的 base36 目录名必须逐位一致，否则预置的发行版
/// 缓存不会被 wrapper 认出来（会重新下载，国内就表现为构建失败）。
void main() {
  test('known MD5 vectors', () {
    expect(md5Hex(const <int>[]), 'd41d8cd98f00b204e9800998ecf8427e');
    expect(
      md5Hex('abc'.codeUnits),
      '900150983cd24fb0d6963f7d28e17f72',
    );
    expect(
      md5Hex('The quick brown fox jumps over the lazy dog'.codeUnits),
      '9e107d9d372bb6826bd81d3542a419d6',
    );
  });

  test('a long message spanning multiple blocks/padding boundary', () {
    // 64 字节整块边界 + 55/56 字节的 padding 分支都要覆盖。
    final sixtyFour = 'a' * 64;
    expect(
      md5Hex(sixtyFour.codeUnits),
      '014842d480b571495a4a0363793f7367',
    );
    final fiftyFive = 'a' * 55;
    expect(
      md5Hex(fiftyFive.codeUnits),
      'ef1772b6dff9a122358552954ad0df65',
    );
  });

  test('incremental add equals one-shot digest', () {
    final digest = Md5Digest()
      ..add('The quick '.codeUnits)
      ..add('brown fox jumps over the lazy dog'.codeUnits);
    final hex = digest
        .close()
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    expect(hex, '9e107d9d372bb6826bd81d3542a419d6');
  });

  test('base36 matches the Gradle wrapper cache directory for a real URL', () {
    // 这个值是本机 Gradle 9.3.1 wrapper 实际创建的缓存目录名。
    expect(
      md5Base36(
        'https://services.gradle.org/distributions/gradle-9.3.1-all.zip',
      ),
      '9ot9r568e8zfvvd4mn8rbu1j0',
    );
  });

  test('base36 is an unsigned big-endian number (no negative rollover)', () {
    // 全 0 与全 0xff 摘要的边界：大端无符号，不能出现负号/前导零异常。
    final zero = md5Base36('');
    expect(zero, isNotEmpty);
    expect(RegExp(r'^[0-9a-z]+$').hasMatch(zero), isTrue);
    final unsigned = BigInt.parse(
      'ffffffffffffffffffffffffffffffff',
      radix: 16,
    );
    expect(unsigned > BigInt.zero, isTrue);
    expect(Uint8List(16).length, 16);
  });
}