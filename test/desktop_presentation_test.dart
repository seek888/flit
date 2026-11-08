import 'package:flit/core/desktop/desktop_presentation.dart';
import 'package:flit/core/host_platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _opener({
  required String label,
  required Future<void> Function(BuildContext context) onOpen,
}) => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => onOpen(context),
          child: Text(label),
        ),
      ),
    ),
  ),
);

void main() {
  tearDown(() => setHostPlatform(null));

  group('showAdaptiveSheet', () {
    testWidgets('桌面显示 Dialog 而不是 BottomSheet', (tester) async {
      setHostPlatform(HostPlatform.windows);
      await tester.pumpWidget(
        _opener(
          label: 'open',
          onOpen: (context) => showAdaptiveSheet<void>(
            context: context,
            title: '面板标题',
            builder: (_) => const Text('面板内容'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('面板标题'), findsOneWidget);
      expect(find.text('面板内容'), findsOneWidget);
    });

    testWidgets('Android 显示 BottomSheet', (tester) async {
      setHostPlatform(HostPlatform.android);
      await tester.pumpWidget(
        _opener(
          label: 'open',
          onOpen: (context) => showAdaptiveSheet<void>(
            context: context,
            title: '面板标题',
            builder: (_) => const Text('面板内容'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('面板内容'), findsOneWidget);
    });

    testWidgets('Esc 关闭桌面面板', (tester) async {
      setHostPlatform(HostPlatform.windows);
      await tester.pumpWidget(
        _opener(
          label: 'open',
          onOpen: (context) => showAdaptiveSheet<void>(
            context: context,
            title: '面板标题',
            builder: (_) => const Text('面板内容'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });
  });

  group('showConfirmDialog', () {
    testWidgets('确定返回 true，Esc 返回 false', (tester) async {
      setHostPlatform(HostPlatform.windows);
      bool? result;
      await tester.pumpWidget(
        _opener(
          label: 'confirm',
          onOpen: (context) async {
            result = await showConfirmDialog(
              context: context,
              title: '删除文件？',
              message: '不可恢复',
              destructive: true,
            );
          },
        ),
      );

      await tester.tap(find.text('confirm'));
      await tester.pumpAndSettle();
      expect(find.text('删除文件？'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, isTrue);

      await tester.tap(find.text('confirm'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });
  });

  group('showPromptDialog', () {
    testWidgets('Enter 提交输入值', (tester) async {
      setHostPlatform(HostPlatform.windows);
      String? result;
      await tester.pumpWidget(
        _opener(
          label: 'prompt',
          onOpen: (context) async {
            result = await showPromptDialog(
              context: context,
              title: '重命名',
              initialValue: 'old.dart',
            );
          },
        ),
      );
      await tester.tap(find.text('prompt'));
      await tester.pumpAndSettle();
      expect(find.text('重命名'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'new.dart');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(result, 'new.dart');
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('校验失败不关闭', (tester) async {
      setHostPlatform(HostPlatform.windows);
      String? result;
      await tester.pumpWidget(
        _opener(
          label: 'prompt',
          onOpen: (context) async {
            result = await showPromptDialog(
              context: context,
              title: '新建文件',
              validator: (value) =>
                  (value == null || value.trim().isEmpty) ? '名称不能为空' : null,
            );
          },
        ),
      );
      await tester.tap(find.text('prompt'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('名称不能为空'), findsOneWidget);
      expect(result, isNull);
      expect(find.byType(AlertDialog), findsOneWidget);
    });

    testWidgets('Esc 取消返回 null', (tester) async {
      setHostPlatform(HostPlatform.windows);
      String? result = 'sentinel';
      await tester.pumpWidget(
        _opener(
          label: 'prompt',
          onOpen: (context) async {
            result = await showPromptDialog(context: context, title: '重命名');
          },
        ),
      );
      await tester.tap(find.text('prompt'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(result, isNull);
    });
  });
}