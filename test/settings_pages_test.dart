import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flit/core/app_scope.dart';
import 'package:flit/core/theme.dart';
import 'package:flit/features/device/device_connect_page.dart';
import 'package:flit/features/device/device_pairing_guide_page.dart';
import 'package:flit/features/editor/editor_settings_page.dart';
import 'package:flit/features/environment/environment_page.dart';
import 'package:flit/features/projects/create_project_page.dart';
import 'package:flit/features/projects/projects_page.dart';
import 'package:flit/features/projects/clone_project_page.dart';
import 'package:flit/features/settings/app_versions_page.dart';
import 'package:flit/features/settings/env_vars_page.dart';
import 'package:flit/features/settings/settings_page.dart';
import 'package:flit/features/terminal/terminal_settings.dart';
import 'package:flit/services/app_releases.dart';
import 'package:flit/l10n/app_localizations.dart';
import 'package:flit/l10n/strings.dart';

import 'support/app_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Future<Map<String, Object>> Function(String) execute;
  final commands = <String>[];

  setUp(() {
    commands.clear();
    execute = (command) async {
      if (command.endsWith('env -0')) {
        return {
          'exitCode': 0,
          'output':
              'HOME=/data/user/0/com.seek888.flit/files/home\x00JAVA_HOME=/prefix/lib/jvm/java-17-openjdk\x00PATH=/prefix/bin:/system/bin\x00SPECIAL=value=one\nsecond line\x00',
        };
      }
      if (command.toString().endsWith('adb devices -l')) {
        return {
          'exitCode': 0,
          'output': 'List of devices attached\n127.0.0.1:32100 unauthorized\n',
        };
      }
      if (command.startsWith('[ -e')) return {'exitCode': 1, 'output': ''};
      return {
        'exitCode': 0,
        'output': command.contains('git --version')
            ? 'git version 2.50'
            : 'Flutter 3.47 · stable',
      };
    };
    // permission_handler 通道未 mock 会永远等不到回复, 授予即可
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (call) async => 1, // PermissionStatus.granted
    );
    messenger.setMockMethodCallHandler(const MethodChannel('flit/device'), (
      call,
    ) async {
      if (call.method == 'pairingReadiness') {
        return {'supported': true, 'notificationsEnabled': true};
      }
      if (call.method == 'pairingStatus') return <String, Object>{};
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('flit/env'), (
      call,
    ) async {
      if (call.method == 'bootstrapStatus') return {'bootstrapped': false};
      if (call.method == 'systemProxy') return null;
      if (call.method == 'exec') {
        final command = (call.arguments as Map)['cmd'] as String;
        commands.add(command);
        return execute(command);
      }
      return false;
    });
  });

  Finder field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );
  Finder button(String label) => find.widgetWithText(FilledButton, label);
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  Future<void> open(
    WidgetTester tester,
    Widget page, {
    Size size = const Size(320, 740),
    GlobalKey? boundary,
    bool wait = true,
    Locale? locale,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    final services = testServices();
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          locale: locale,
          supportedLocales: locale == null
              ? const [Locale('en')]
              : AppLocalizations.supportedLocales,
          localizationsDelegates: locale == null
              ? null
              : AppLocalizations.localizationsDelegates,
          theme: flitTheme(),
          navigatorObservers: [services.routeObserver],
          home: RepaintBoundary(key: boundary, child: page),
        ),
      ),
    );
    if (wait) {
      await settle(tester);
    } else {
      await tester.pump();
    }
  }

  tearDown(() {
    strings = lookupAppLocalizations(const Locale('zh'));
    messenger.setMockMethodCallHandler(const MethodChannel('flit/env'), null);
  });

  testWidgets('English pages fit narrow phones and landscape', (tester) async {
    final handler = FlutterError.onError;
    FlutterError.onError = (details) {
      debugPrint(details.toString());
      handler?.call(details);
    };
    addTearDown(() => FlutterError.onError = handler);
    strings = lookupAppLocalizations(const Locale('en'));
    final releases = AppReleases()..fetchJson = (_) async => [];
    final pages = <Widget>[
      const SettingsPage(),
      const DeviceConnectPage(autoConnectOnOpen: false),
      const DevicePairingGuidePage(),
      const CreateProjectPage(projectRoot: '/home/projects'),
      const CloneProjectPage(targetDir: '/home/projects'),
      const EditorSettingsPage(),
      const TerminalSettingsPage(),
      const EnvVarsPage(),
      AppVersionsPage(releases: releases),
      const EnvironmentPage(),
    ];
    for (final size in [const Size(320, 740), const Size(700, 360)]) {
      for (final page in pages) {
        await open(tester, page, locale: const Locale('en'), size: size);
        expect(
          tester.takeException(),
          isNull,
          reason: '${page.runtimeType} $size',
        );
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  test('environment parser keeps multiline values and equals signs', () {
    expect(parseEnvironment('Z=\x00TEXT=a=b\nsecond\x00'), [
      ('TEXT', 'a=b\nsecond'),
      ('Z', ''),
    ]);
  });

  testWidgets(
    'environment failure is not an empty success; search shows other variables',
    (tester) async {
      execute = (_) async => {'exitCode': 1, 'output': 'broken'};
      await open(tester, const EnvVarsPage());
      expect(find.textContaining('读取失败'), findsOneWidget);
      expect(find.text('没有匹配的变量'), findsNothing);
      execute = (_) async => {
        'exitCode': 0,
        'output': 'HOME=/home\x00SPECIAL=a=b\nsecond\x00',
      };
      await tester.tap(find.text('重试'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'SPECIAL');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ExpansionTile, 'SPECIAL'), findsOneWidget);
      await tester.tap(find.text('SPECIAL').last);
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        'a=b\nsecond',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Dart checks Dart; an obsolete Flutter check cannot disable creation',
    (tester) async {
      final flutter = Completer<Map<String, Object>>();
      execute = (cmd) async => cmd.endsWith('flutter --version')
          ? flutter.future
          : {'exitCode': 0, 'output': 'Dart SDK 3.12'};
      await open(
        tester,
        const CreateProjectPage(projectRoot: '/home/projects'),
        wait: false,
      );
      // An active progress indicator intentionally never settles.
      await tester.tap(find.text('Dart'));
      await settle(tester);
      expect(commands.any((cmd) => cmd.endsWith('dart --version')), true);
      expect(tester.widget<FilledButton>(button('创建项目')).onPressed, isNotNull);
      flutter.complete({'exitCode': 127, 'output': 'missing flutter'});
      await settle(tester);
      expect(tester.widget<FilledButton>(button('创建项目')).onPressed, isNotNull);
      expect(find.text('组织标识（可选）'), findsNothing);
      expect(find.text('高级设置'), findsNothing);
    },
  );

  testWidgets(
    'creation preflight exceptions release button and preserve form',
    (tester) async {
      await open(
        tester,
        const CreateProjectPage(projectRoot: '/home/projects'),
      );
      execute = (_) async =>
          throw PlatformException(code: 'exec', message: 'failed to launch');
      await tester.tap(button('创建项目'));
      await settle(tester);
      expect(tester.widget<FilledButton>(button('创建项目')).onPressed, isNotNull);
      await tester.drag(find.byType(ListView), const Offset(0, -1800));
      await tester.pumpAndSettle();
      expect(find.textContaining('创建前检查失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('clone preflight rejects an existing directory', (tester) async {
    await open(tester, const CloneProjectPage(targetDir: '/home/projects'));
    await tester.enterText(
      field('仓库地址'),
      'https://github.com/example/project.git',
    );
    tester.testTextInput.hide();
    await tester.pump();
    execute = (_) async => {'exitCode': 0, 'output': ''};
    await tester.tap(button('克隆仓库'));
    await settle(tester);
    // 账户行会并发探测 gh 状态, 预检命令不一定是最后一条
    expect(
      commands.lastWhere((c) => c.contains('[ -e ')),
      contains('/home/projects'),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -1600));
    await tester.pumpAndSettle();
    expect(find.textContaining('已存在'), findsOneWidget);
    expect(tester.widget<FilledButton>(button('克隆仓库')).onPressed, isNotNull);
  });

  testWidgets(
    'project creation and cloning require the complete development environment',
    (tester) async {
      var openedEnvironment = false;
      await open(
        tester,
        ProjectsPage(
          environmentReady: false,
          onOpenProject: (_) {},
          onOpenEnvironment: () => openedEnvironment = true,
          onOpenSettings: () {},
        ),
      );
      await tester.tap(find.byTooltip('新建项目'));
      await settle(tester);
      expect(find.byType(CreateProjectPage), findsNothing);
      expect(openedEnvironment, true);
      openedEnvironment = false;
      await tester.tap(find.byTooltip('克隆仓库'));
      await settle(tester);
      expect(find.byType(CloneProjectPage), findsNothing);
      expect(openedEnvironment, true);
    },
  );

  testWidgets('pages fit narrow screens and tablet width; render previews', (
    tester,
  ) async {
    if (const bool.fromEnvironment('PAGES_PREVIEW')) {
      await tester.runAsync(() async {
        for (final family in ['Roboto', 'monospace', 'JetBrainsMono']) {
          await (FontLoader(family)..addFont(
                File(
                  const String.fromEnvironment('PREVIEW_FONT'),
                ).readAsBytes().then(ByteData.sublistView),
              ))
              .load();
        }
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
    }
    final appReleases = AppReleases()
      ..fetchJson = (_) async => [
        {
          'tag_name': 'v1.0.0-preview.1',
          'name': 'Flit v1.0.0-preview.1',
          'prerelease': true,
          'published_at': '2026-10-29T11:17:00Z',
          'assets': [
            {
              'name': 'flit-v1.0.0-preview.1-202610291117-1e99594.apk',
              'size': 987,
              'browser_download_url': 'https://example/flit.apk',
            },
          ],
        },
      ];
    final pages = <String, Widget>{
      'device': const DeviceConnectPage(autoConnectOnOpen: false),
      'pairing-guide': const DevicePairingGuidePage(),
      'create': const CreateProjectPage(projectRoot: '/home/projects'),
      'settings': const SettingsPage(),
      'editor-settings': const EditorSettingsPage(),
      'terminal-settings': const TerminalSettingsPage(),
      'variables': const EnvVarsPage(),
      'app-versions': AppVersionsPage(releases: appReleases),
      'clone': const CloneProjectPage(targetDir: '/home/projects'),
      'environment': const EnvironmentPage(),
      'projects': ProjectsPage(
        environmentReady: false,
        onOpenProject: (_) {},
        onOpenEnvironment: () {},
        onOpenSettings: () {},
      ),
    };
    for (final entry in pages.entries) {
      final boundary = GlobalKey();
      await open(tester, entry.value, boundary: boundary);
      expect(tester.takeException(), isNull, reason: entry.key);
      if (const bool.fromEnvironment('PAGES_PREVIEW')) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            'build/page-${entry.key}.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      final lists = find.byType(ListView);
      if (lists.evaluate().isNotEmpty) {
        await tester.drag(lists.first, const Offset(0, -1600));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '${entry.key} scrolled');
      }
      tester.view.physicalSize = const Size(700, 360);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '${entry.key} landscape');
      tester.view.physicalSize = const Size(1100, 800);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '${entry.key} tablet');
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
    }
  });
}
