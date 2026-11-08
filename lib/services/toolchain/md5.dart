import 'dart:typed_data';

/// 纯 Dart MD5（RFC 1321）。
///
/// 为什么不加 `crypto` 依赖：与 `hash.dart` 的 SHA-256 一样，工具链层刻意
/// 不新增 pub 依赖（`pubspec.lock` 在离线/受限网络下不好更新）。这里只实现
/// Gradle Wrapper 需要的两件事：十六进制摘要，以及 Java `BigInteger(1, digest)`
/// 的大端数值 → base36（Gradle 用它算发行版缓存目录名）。
class Md5Digest {
  Md5Digest()
    : _state = Uint32List.fromList(const <int>[
        0x67452301,
        0xefcdab89,
        0x98badcfe,
        0x10325476,
      ]);

  /// 每轮左移量（RFC 1321 §3.4）。
  static const List<int> _shifts = <int>[
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, //
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, //
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, //
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, //
  ];

  /// K[i] = floor(2^32 × |sin(i+1)|)（写成常量，避免浮点精度差异）。
  static const List<int> _constants = <int>[
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, //
    0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501, //
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, //
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821, //
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, //
    0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8, //
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, //
    0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a, //
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, //
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, //
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, //
    0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, //
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, //
    0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1, //
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, //
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391, //
  ];

  final Uint32List _state;
  final Uint8List _block = Uint8List(64);
  int _blockLength = 0;
  int _totalLength = 0;

  /// 追加一段字节；可多次调用，顺序与内容一致。
  void add(List<int> bytes) {
    if (bytes.isEmpty) return;
    _totalLength += bytes.length;
    var offset = 0;

    if (_blockLength > 0) {
      final take = 64 - _blockLength < bytes.length
          ? 64 - _blockLength
          : bytes.length;
      _block.setRange(_blockLength, _blockLength + take, bytes);
      _blockLength += take;
      offset += take;
      if (_blockLength == 64) {
        _compress(_block);
        _blockLength = 0;
      }
    }

    while (bytes.length - offset >= 64) {
      _block.setRange(0, 64, bytes, offset);
      _compress(_block);
      offset += 64;
    }

    if (offset < bytes.length) {
      _block.setRange(0, bytes.length - offset, bytes, offset);
      _blockLength = bytes.length - offset;
    }
  }

  /// 结束并返回 16 字节摘要（小端序，与 RFC 一致）。只能调用一次。
  Uint8List close() {
    final bitLength = _totalLength * 8;
    final padLength = _blockLength < 56
        ? 56 - _blockLength
        : 120 - _blockLength;
    final padding = Uint8List(padLength + 8);
    padding[0] = 0x80;
    for (var i = 0; i < 8; i++) {
      padding[padLength + i] = (bitLength >> (8 * i)) & 0xff;
    }
    add(padding);

    final out = Uint8List(16);
    for (var word = 0; word < 4; word++) {
      final value = _state[word];
      out[word * 4] = value & 0xff;
      out[word * 4 + 1] = (value >> 8) & 0xff;
      out[word * 4 + 2] = (value >> 16) & 0xff;
      out[word * 4 + 3] = (value >> 24) & 0xff;
    }
    return out;
  }

  static int _rotateLeft(int value, int count) =>
      ((value << count) | (value >> (32 - count))) & 0xffffffff;

  void _compress(Uint8List block) {
    final words = Uint32List(16);
    for (var i = 0; i < 16; i++) {
      words[i] =
          block[i * 4] |
          (block[i * 4 + 1] << 8) |
          (block[i * 4 + 2] << 16) |
          (block[i * 4 + 3] << 24);
    }

    var a = _state[0];
    var b = _state[1];
    var c = _state[2];
    var d = _state[3];

    for (var i = 0; i < 64; i++) {
      int f;
      int g;
      if (i < 16) {
        f = (b & c) | ((~b & 0xffffffff) & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | ((~d & 0xffffffff) & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | (~d & 0xffffffff));
        g = (7 * i) % 16;
      }
      final sum = (a + f + _constants[i] + words[g]) & 0xffffffff;
      a = d;
      d = c;
      c = b;
      b = (b + _rotateLeft(sum, _shifts[i])) & 0xffffffff;
    }

    _state[0] = (_state[0] + a) & 0xffffffff;
    _state[1] = (_state[1] + b) & 0xffffffff;
    _state[2] = (_state[2] + c) & 0xffffffff;
    _state[3] = (_state[3] + d) & 0xffffffff;
  }
}

/// 小写十六进制 MD5。
String md5Hex(List<int> bytes) {
  final digest = Md5Digest()..add(bytes);
  return digest
      .close()
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

/// Java `new BigInteger(1, md5(bytes)).toString(36)`：大端无符号数值的三十二进制。
///
/// Gradle Wrapper 用 `MD5(distributionUrl)` 的 base36 作为发行版缓存目录名，
/// 必须逐位一致，否则预置的目录不会被识别（会重新下载或直接失败）。
String md5Base36(String text) {
  final digest = Md5Digest()..add(text.codeUnits.isEmpty
      ? const <int>[]
      : _utf8Bytes(text));
  final bytes = digest.close();
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  const digits = '0123456789abcdefghijklmnopqrstuvwxyz';
  final radix = BigInt.from(36);
  final buffer = StringBuffer();
  do {
    final remainder = (value % radix).toInt();
    buffer.write(digits[remainder]);
    value = value ~/ radix;
  } while (value > BigInt.zero);
  return String.fromCharCodes(buffer.toString().codeUnits.reversed);
}

/// UTF-8 编码（`dart:convert` 的常量开销在这里没必要，URL 基本是 ASCII）。
List<int> _utf8Bytes(String text) {
  final out = <int>[];
  for (final rune in text.runes) {
    if (rune <= 0x7f) {
      out.add(rune);
    } else if (rune <= 0x7ff) {
      out.add(0xc0 | (rune >> 6));
      out.add(0x80 | (rune & 0x3f));
    } else if (rune <= 0xffff) {
      out.add(0xe0 | (rune >> 12));
      out.add(0x80 | ((rune >> 6) & 0x3f));
      out.add(0x80 | (rune & 0x3f));
    } else {
      out.add(0xf0 | (rune >> 18));
      out.add(0x80 | ((rune >> 12) & 0x3f));
      out.add(0x80 | ((rune >> 6) & 0x3f));
      out.add(0x80 | (rune & 0x3f));
    }
  }
  return out;
}