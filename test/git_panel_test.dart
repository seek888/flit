import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flit/core/app_scope.dart';
import 'package:flit/core/theme.dart';
import 'package:flit/features/git/git_panel.dart';
import 'package:flit/features/git/project_git.dart';
import 'package:flit/features/terminal/run_sessions.dart';
import 'package:flit/features/workspace/project_documents.dart';
import 'package:flit/services/git_repo.dart';
import 'support/app_scope.dart';
import 'support/fake_session_process.dart';
import 'support/project_scope.dart';

void main() {
  testWidgets(
    'narrow Git panel keeps navigation, distinguishes both diffs, and confirms discard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // safe.directory 白名单探测走 Shell 通道: mock 掉, 免得假时钟里永不回复
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('flit/env'),
            (call) async => {'exitCode': 0, 'output': ''},
          );
      final boundary = GlobalKey();
      if (const bool.fromEnvironment('GIT_PREVIEW')) {
        await tester.runAsync(() async {
          const fontPath = String.fromEnvironment('PREVIEW_FONT');
          await (FontLoader('Roboto')..addFont(
                File(fontPath).readAsBytes().then(ByteData.sublistView),
              ))
              .load();
          await (FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
              .load();
        });
      }
      final commands = <String>[];
      final invocations = <List<String>>[];
      String status = '## main\x00MM main.dart\x00';
      final repo = GitRepo(
        '/project',
        execute: (args) async {
          invocations.add(List<String>.of(args));
          commands.add(args.join(' '));
          if (args.contains('--show-prefix')) return (code: 0, out: '');
          if (args.contains('rev-parse')) {
            return (code: 0, out: '/project\n');
          }
          if (args.contains('status')) return (code: 0, out: status);
          if (args.contains('diff')) {
            return (
              code: 0,
              out: args.contains('--cached')
                  ? '+staged version'
                  : '+working version',
            );
          }
          return (code: 0, out: '');
        },
      );
      final documents = ProjectDocuments('/project');
      final runs = RunSessions(
        projectPath: '/project',
        launcher:
            ({
              required command,
              required workingDirectory,
              required rows,
              required columns,
            }) async {
              commands.add(command!);
              final process = FakeProcess();
              scheduleMicrotask(() => process.finish());
              return process;
            },
      );
      final git = ProjectGit(
        documents: documents,
        executions: runs,
        repository: repo,
      );
      await tester.pumpWidget(
        AppScope(
          services: testServices(launcher: noProcess),
          child: MaterialApp(
            theme: flitTheme(),
            home: Scaffold(
              body: RepaintBoundary(
                key: boundary,
                child: Material(
                  color: AppColors.bg,
                  child: scopedProject(git: git, child: const GitPanel()),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (const bool.fromEnvironment('GIT_PREVIEW')) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            'build/git-panel.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(find.text('提交更改 · 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('main.dart'));
      await tester.pumpAndSettle();
      expect(find.text('显示已暂存的差异'), findsOneWidget);
      expect(find.text('显示未暂存的差异'), findsOneWidget);
      await tester.tap(find.text('显示已暂存的差异'));
      await tester.pumpAndSettle();
      expect(find.text('+staged version'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(GitPanel), findsOneWidget);
      await tester.tap(find.text('main.dart'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('回滚未暂存的更改'));
      await tester.pumpAndSettle();
      expect(find.text('回滚更改？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      // 取消回滚后不能真的执行 git restore（argv 里不应出现 restore）
      expect(invocations.any((args) => args.contains('restore')), false);
      await tester.tap(find.text('提交更改 · 1'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'message');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      status = '## main\x00 M other.dart\x00';
      await tester.tap(find.byTooltip('刷新版本控制状态'));
      await tester.pumpAndSettle();
      expect(find.text('other.dart'), findsOneWidget);
      expect(find.text('main.dart'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await git.close();
      await runs.closeAll();
      await documents.close();
    },
  );
}
