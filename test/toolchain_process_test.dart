import 'dart:convert';
import 'dart:io';

import 'package:flit/services/toolchain/process.dart';
import 'package:flutter_test/flutter_test.dart';

/// 子进程边界回归：Windows 的 `.bat/.cmd` 必须以 argv 直接启动。
///
/// 曾经的实现把批处理包成 `cmd.exe /c <bat> <args...>`；Dart 会把整条
/// 命令字符串再包一层引号、内层 `"` 转义成 `\"`，于是带空格的路径或
/// 参数被 cmd 拆坏（`flutter.bat` 报「不是内部或外部命令」，新建项目
/// 预检因此永远失败）。
void main() {
  test(
    'Windows .bat：路径与参数都含空格时仍按 argv 原样传入',
    () async {
      final root = Directory.systemTemp.createTempSync('flit process test');
      addTearDown(() {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      });
      final bat = File(
        '${root.path}${Platform.pathSeparator}echo args.bat',
      )..writeAsStringSync('@echo GOT1=[%1] GOT2=[%2]\r\n');

      final result = await const SystemToolchainProcess().run(
        bat.path,
        const <String>['a b', '--version'],
        timeout: const Duration(seconds: 30),
      );

      expect(result.exitCode, 0);
      final output = '${result.stdout}${result.stderr}';
      // 参数没被空格拆开，也没被 cmd 当成未知命令。
      expect(output, contains('a b'));
      expect(output, contains('--version'));
      expect(output, isNot(contains('不是内部或外部命令')));
    },
    skip: !Platform.isWindows,
  );

  test('decodeProcessOutput 优先按 UTF-8 解码，版本行的 · 不再变成乱码', () {
    final bytes = utf8.encode('Flutter 3.47.9 • channel stable');
    expect(decodeProcessOutput(bytes), 'Flutter 3.47.9 • channel stable');
  });

  test('decodeProcessOutput 遇到非 UTF-8 字节时退回系统编码', () {
    final bytes = <int>[0xC8, 0xFD, 0xB2, 0xE2, 0x3A, 0x20, 0x4F, 0x4B];
    final decoded = decodeProcessOutput(bytes);
    expect(decoded, isNotEmpty);
    expect(decoded, isNot(contains('\uFFFD')));
  });
}