import 'dart:io';

import 'package:flit/services/desktop_shell.dart';
import 'package:flit/services/desktop_toolchain.dart';
import 'package:flutter_test/flutter_test.dart';

/// 新建项目预检（`<tool> --version`）在桌面端的回归测试。
///
/// 用户目录可能带空格（`C:\Users\John Doe\AppData\Local\FlitDesk`），所以
/// 这里特意用含空格的 home：预检必须走 argv（[DesktopShell.runBinary]），
/// 不能把 `"<工具链>/flutter/bin/flutter.bat"` 拼进 cmd 命令串。
void main() {
  test(
    'which + runBinary 能找到并执行含空格路径下的 flutter.bat',
    () async {
      final home = Directory.systemTemp.createTempSync('flit home ');
      addTearDown(() {
        try {
          home.deleteSync(recursive: true);
        } catch (_) {}
      });
      final bin = Directory(
        '${home.path}${Platform.pathSeparator}flutter'
        '${Platform.pathSeparator}bin',
      )..createSync(recursive: true);
      File(
        '${bin.path}${Platform.pathSeparator}flutter.bat',
      ).writeAsStringSync('@echo Flutter 9.9.9 (fake)\r\n');

      final shell = DesktopShell(toolchain: DesktopToolchain(home: home.path));

      final exe = shell.which('flutter');
      expect(exe, isNotNull, reason: '私有工具链 bin 目录里的 flutter.bat 应被找到');
      expect(File(exe!).existsSync(), isTrue);

      final result = await shell.runBinary(
        exe,
        const <String>['--version'],
        timeoutMs: 30000,
      );
      expect(result['exitCode'], 0, reason: '${result['output']}');
      expect(result['output'], contains('Flutter 9.9.9'));
      expect(result['output'], isNot(contains('不是内部或外部命令')));
    },
    skip: !Platform.isWindows,
  );
}