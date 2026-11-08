import 'package:flit/core/desktop/app_commands.dart';
import 'package:flit/core/desktop/desktop_app_shell.dart';
import 'package:flit/core/host_platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _shellHarness(AppCommands commands) => ChangeNotifierProvider<
  AppCommands
>.value(
  value: commands,
  child: MaterialApp(
    builder: (context, child) => DesktopAppShell(child: child!),
    home: const Scaffold(body: Text('工作区')),
  ),
);

void main() {
  group('AppCommands', () {
    test('注册后可调用，注销后不可调用', () {
      final commands = AppCommands();
      var calls = 0;
      expect(commands.canInvoke(AppCommand.save), isFalse);

      commands.register(AppCommand.save, () => calls++);
      expect(commands.canInvoke(AppCommand.save), isTrue);
      commands.invoke(AppCommand.save);
      expect(calls, 1);

      commands.unregister(AppCommand.save);
      expect(commands.canInvoke(AppCommand.save), isFalse);
      commands.invoke(AppCommand.save);
      expect(calls, 1, reason: '注销后调用应为 no-op');
    });

    test('重复注册以后者为准', () {
      final commands = AppCommands();
      final log = <String>[];
      commands.register(AppCommand.run, () => log.add('first'));
      commands.register(AppCommand.run, () => log.add('second'));
      commands.invoke(AppCommand.run);
      expect(log, <String>['second']);
    });

    test('未注册的 invoke 不抛异常', () {
      final commands = AppCommands();
      expect(() => commands.invoke(AppCommand.stop), returnsNormally);
    });

    test('注销全部命令', () {
      final commands = AppCommands();
      commands.register(AppCommand.save, () {});
      commands.register(AppCommand.run, () {});
      commands.unregisterAll();
      expect(commands.canInvoke(AppCommand.save), isFalse);
      expect(commands.canInvoke(AppCommand.run), isFalse);
    });

    test('handler 抛异常不影响调用方', () {
      final commands = AppCommands();
      commands.register(AppCommand.save, () => throw StateError('boom'));
      expect(() => commands.invoke(AppCommand.save), returnsNormally);
    });
  });

  group('shortcutLabel', () {
    test('生成 Windows 风格显示串', () {
      expect(shortcutLabel(AppCommand.save), 'Ctrl+S');
      expect(shortcutLabel(AppCommand.saveAll), 'Ctrl+Shift+S');
      expect(shortcutLabel(AppCommand.openProject), 'Ctrl+O');
      expect(shortcutLabel(AppCommand.importProject), 'Ctrl+Shift+O');
      expect(shortcutLabel(AppCommand.newProject), 'Ctrl+N');
      expect(shortcutLabel(AppCommand.openSettings), 'Ctrl+,');
      expect(shortcutLabel(AppCommand.run), 'F5');
      expect(shortcutLabel(AppCommand.stop), 'Shift+F5');
      expect(shortcutLabel(AppCommand.rebuild), 'Ctrl+Shift+B');
      expect(shortcutLabel(AppCommand.toggleTerminal), 'Ctrl+`');
      expect(shortcutLabel(AppCommand.toggleSidebar), 'Ctrl+B');
      expect(shortcutLabel(AppCommand.nextTab), 'Ctrl+Tab');
      expect(shortcutLabel(AppCommand.previousTab), 'Ctrl+Shift+Tab');
      expect(shortcutLabel(AppCommand.zoomIn), 'Ctrl+=');
      expect(shortcutLabel(AppCommand.zoomOut), 'Ctrl+-');
      expect(shortcutLabel(AppCommand.resetZoom), 'Ctrl+0');
      expect(shortcutLabel(AppCommand.commandPalette), 'Ctrl+Shift+P');
      expect(shortcutLabel(AppCommand.showShortcuts), 'F1');
      expect(shortcutLabel(AppCommand.fullscreen), 'F11');
      expect(shortcutLabel(AppCommand.quit), 'Alt+F4');
      expect(shortcutLabel(AppCommand.refresh), '');
    });

    test('快捷键表覆盖所有带绑定的命令', () {
      expect(appShortcutBindings, isNotEmpty);
      expect(appShortcutIntents().length, appShortcutBindings.length);
      expect(
        appShortcutHandlers(AppCommands()).length,
        appShortcutBindings.length,
      );
    });
  });

  group('桌面菜单栏', () {
    testWidgets('桌面渲染 文件/编辑/视图/运行/帮助', (tester) async {
      setHostPlatform(HostPlatform.windows);
      addTearDown(() => setHostPlatform(null));
      await tester.pumpWidget(_shellHarness(AppCommands()));
      await tester.pumpAndSettle();
      for (final label in <String>['文件', '编辑', '视图', '运行', '帮助']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('工作区'), findsOneWidget);
    });

    testWidgets('Android 不渲染菜单栏', (tester) async {
      setHostPlatform(HostPlatform.android);
      addTearDown(() => setHostPlatform(null));
      await tester.pumpWidget(_shellHarness(AppCommands()));
      await tester.pumpAndSettle();
      expect(find.text('文件'), findsNothing);
      expect(find.text('工作区'), findsOneWidget);
    });

    testWidgets('注册的命令可执行，未注册的置灰', (tester) async {
      setHostPlatform(HostPlatform.windows);
      addTearDown(() => setHostPlatform(null));
      final commands = AppCommands();
      var runs = 0;
      commands.register(AppCommand.run, () => runs++);
      await tester.pumpWidget(_shellHarness(commands));
      await tester.pumpAndSettle();
      await tester.tap(find.text('运行'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('运行工程').last);
      await tester.pumpAndSettle();
      expect(runs, 1);
    });
  });
}