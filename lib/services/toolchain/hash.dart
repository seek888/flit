import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// 纯 Dart SHA-256（不新增 pub 依赖；`pubspec.lock` 无法在本地更新）。
///
/// 大文件在后台 isolate 计算，避免 UI 卡顿；下载路径边写边算，
/// 不需要把整个文件读进内存。
class Sha256Digest {
  Sha256Digest() : _state = Uint32List.fromList(_initialState);

  static const List<int> _initialState = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];

  static const List<int> _roundConstants = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];

  final Uint32List _state;
  final Uint8List _block = Uint8List(64);
  int _blockLength = 0;
  int _totalLength = 0;

  /// 追加一段字节。可以多次调用；顺序与文件内容一致。
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

  /// 结束并返回小写十六进制摘要。只能调用一次。
  String close() {
    final bitLength = _totalLength * 8;
    final padLength = _blockLength < 56
        ? 56 - _blockLength
        : 120 - _blockLength;
    final padding = Uint8List(padLength + 8);
    padding[0] = 0x80;
    for (var i = 0; i < 8; i++) {
      padding[padLength + 7 - i] = (bitLength >> (8 * i)) & 0xff;
    }
    add(padding);

    final out = StringBuffer();
    for (final word in _state) {
      out.write(word.toRadixString(16).padLeft(8, '0'));
    }
    return out.toString();
  }

  static int _rotateRight(int value, int count) =>
      ((value >> count) | (value << (32 - count))) & 0xffffffff;

  void _compress(Uint8List block) {
    final schedule = Uint32List(64);
    for (var i = 0; i < 16; i++) {
      schedule[i] =
          (block[i * 4] << 24) |
          (block[i * 4 + 1] << 16) |
          (block[i * 4 + 2] << 8) |
          block[i * 4 + 3];
    }
    for (var i = 16; i < 64; i++) {
      final w15 = schedule[i - 15];
      final w2 = schedule[i - 2];
      final s0 = _rotateRight(w15, 7) ^ _rotateRight(w15, 18) ^ (w15 >> 3);
      final s1 = _rotateRight(w2, 17) ^ _rotateRight(w2, 19) ^ (w2 >> 10);
      schedule[i] = (schedule[i - 16] + s0 + schedule[i - 7] + s1) & 0xffffffff;
    }

    var a = _state[0];
    var b = _state[1];
    var c = _state[2];
    var d = _state[3];
    var e = _state[4];
    var f = _state[5];
    var g = _state[6];
    var h = _state[7];

    for (var i = 0; i < 64; i++) {
      final s1 = _rotateRight(e, 6) ^ _rotateRight(e, 11) ^ _rotateRight(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final temp1 =
          (h + s1 + ch + _roundConstants[i] + schedule[i]) & 0xffffffff;
      final s0 = _rotateRight(a, 2) ^ _rotateRight(a, 13) ^ _rotateRight(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xffffffff;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    _state[0] = (_state[0] + a) & 0xffffffff;
    _state[1] = (_state[1] + b) & 0xffffffff;
    _state[2] = (_state[2] + c) & 0xffffffff;
    _state[3] = (_state[3] + d) & 0xffffffff;
    _state[4] = (_state[4] + e) & 0xffffffff;
    _state[5] = (_state[5] + f) & 0xffffffff;
    _state[6] = (_state[6] + g) & 0xffffffff;
    _state[7] = (_state[7] + h) & 0xffffffff;
  }
}

/// 一段内存字节的 SHA-256（小写十六进制）。
String sha256Hex(List<int> bytes) {
  final digest = Sha256Digest()..add(bytes);
  return digest.close();
}

/// 文件 SHA-256；1 GB 级文件放后台 isolate，避免阻塞界面。
Future<String> sha256OfFile(String path) =>
    Isolate.run(() => _sha256OfFileSync(path));

String _sha256OfFileSync(String path) {
  final digest = Sha256Digest();
  final file = File(path);
  final handle = file.openSync();
  try {
    final buffer = Uint8List(1 << 20);
    while (true) {
      final read = handle.readIntoSync(buffer);
      if (read <= 0) break;
      digest.add(Uint8List.sublistView(buffer, 0, read));
    }
  } finally {
    handle.closeSync();
  }
  return digest.close();
}
