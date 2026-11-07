import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flit/features/projects/projects_page.dart';
import 'package:flit/features/projects/create_project_page.dart';
import 'package:flit/features/projects/clone_project_page.dart';
import 'package:flit/core/app_scope.dart';
import 'package:flit/core/host_platform.dart';
import 'package:flit/services/shared_storage_access.dart';

import 'support/app_scope.dart';
import 'support/fake_session_process.dart';
import 'support/flit_plugins.dart';
import 'support/host_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 首页/工程存储用例 mock 了 flit/env 通道；Windows CI 上必须固定成 android，
  // 否则 Shell 会走 DesktopShell 绕过通道桩（路径/文案断言全变）。
  useHostPlatform(HostPlatform.android);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final requests = <Object?>[];
  final commands = <String>[];
  late AppServices services;
  // 工程根扫描的输出(name\tkind\tepoch)
  var listing = 'my_app\tflutter\t1700000000\nnotes\tfolder\t\n';

  setUp(() {
    requests.clear();
    commands.clear();
    listing = 'my_app\tflutter\t1700000000\nnotes\tfolder\t\n';
    // 首页测试不跑任何进程
    services = testServices(launcher: noProcess);
    // 关闭工程会 dispose 语言服务(flit/lsp): 不 mock 会等真实异步而卡死
    mockFlitPlugins(messenger);
    // 工程根在应用内部, 首页不再碰共享存储权限; 这里只为编辑器的导入浏览器兜底
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (call) async {
        if (call.method == 'requestPermissions') {
          requests.add(call.arguments);
          return {
            for (final permission in call.arguments as List) permission: 0,
          };
        }
        return 0;
      },
    );
    messenger.setMockMethodCallHandler(const MethodChannel('flit/env'), (
      call,
    ) async {
      if (call.method == 'bootstrapStatus') return {'home': '/private/home'};
      if (call.method == 'exec') {
        final command = (call.arguments as Map)['cmd'] as String;
        commands.add(command);
        if (command.contains('-maxdepth 1 -type d')) {
          return {'exitCode': 0, 'output': listing};
        }
        return {'exitCode': 0, 'output': 'OK'};
      }
      return null;
    });
  });

  Future<void> open(WidgetTester tester, {bool environmentReady = true}) async {
    await tester.pumpWidget(
      testApp(
        services: services,
        home: ProjectsPage(
          environmentReady: environmentReady,
          onOpenProject: (_) {},
          onOpenEnvironment: () {},
          onOpenSettings: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('home lists projects under the internal root with their kind', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('my_app'), findsOneWidget);
    expect(find.textContaining('Flutter 工程'), findsOneWidget);
    expect(find.text('notes'), findsOneWidget);
    expect(find.textContaining('文件夹'), findsOneWidget);
    expect(find.text('工程 · 2'), findsOneWidget);
    expect(find.byTooltip('项目存储位置'), findsNothing);
    // 扫描只跑在工程根, 不是别的目录
    expect(
      commands.single,
      startsWith("mkdir -p '/private/home/projects' && cd "),
    );
  });

  testWidgets('empty root shows the create/clone empty state', (tester) async {
    listing = '';
    await open(tester);
    expect(find.text('还没有工程'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '新建项目'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '克隆仓库'), findsOneWidget);
  });

  testWidgets('list waits for the environment: no scan before bash exists', (
    tester,
  ) async {
    await open(tester, environmentReady: false);
    expect(find.text('开发环境未就绪'), findsOneWidget);
    expect(commands, isEmpty);
    await open(tester);
    expect(commands, hasLength(1));
    expect(find.text('my_app'), findsOneWidget);
  });

  testWidgets(
    'storage hint explains backup; create and clone land in the root',
    (tester) async {
      await open(tester);
      // 卸载即删没有系统回调, 首页常驻一行提示, 点开给出备份方式与真实路径
      await tester.tap(find.text('工程存在应用内部，卸载即删 · 备份方式'));
      await tester.pumpAndSettle();
      expect(find.text('工程保存在哪里？'), findsOneWidget);
      expect(find.textContaining('/private/home/projects'), findsOneWidget);
      expect(find.textContaining('GitHub'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('新建项目'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CreateProjectPage>(find.byType(CreateProjectPage))
            .projectRoot,
        '/private/home/projects',
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('克隆仓库'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CloneProjectPage>(find.byType(CloneProjectPage))
            .targetDir,
        '/private/home/projects',
      );
      expect(requests, isEmpty);
    },
  );

  testWidgets('import permission shares the explanation and can be declined', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  SharedStorageAccess.request(context, purpose: '复制共享文件到当前项目。'),
              child: const Text('导入'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(find.textContaining('复制共享文件'), findsOneWidget);
    expect(requests, isEmpty);
    await tester.tap(find.text('暂不授权'));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
  });

  testWidgets('home refuses to delete or rename the open project', (
    tester,
  ) async {
    // 经工作区打开(唯一入口); 打开即激活, 探测命令也进 commands, 断言只看 rm
    final session = await services.workspace.open(
      '/private/home/projects/my_app',
    );
    await open(tester);
    await tester.tap(find.byTooltip('更多').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除工程「my_app」？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.text('请先关闭该工程，再重命名或删除它'), findsOneWidget);
    // 守卫在发命令之前: 没有任何 rm 到达 shell
    expect(commands.where((c) => c.contains('rm -rf')), isEmpty);

    // The close chain has real-clock pieces (autosave timer): let them drain.
    await tester.pumpWidget(const SizedBox());
    final closing = services.workspace.closeActive();
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(await closing, isTrue);
    expect(session.closed, isTrue);
  });
}
