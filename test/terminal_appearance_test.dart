import 'package:flit/core/app_scope.dart';
import 'package:flit/services/adb_connection_method.dart';
import 'package:flit/features/settings/appearance_preferences.dart';
import 'package:flit/features/terminal/console_session.dart';
import 'package:flit/features/terminal/terminal_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'support/app_scope.dart';
import 'support/fake_session_process.dart';

class RecordingPreferences extends AppearancePreferences {
  int terminalWrites = 0;
  @override
  Future<void> load() async {}

  @override
  Future<void> update({
    double? editor,
    double? terminal,
    String? terminalFont,
    double? terminalLineHeight,
    String? theme,
    bool? wrap,
    bool? backgroundNoticeShown,
    bool? adbPaired,
    String? adbHost,
    String? adbConnectPort,
    AdbConnectionMethod? adbConnectionMethod,
    int? adbPairingRevision,
    String? runDevice,
  }) {
    if (terminal != null) terminalWrites++;
    if (terminal != null) terminalSize = terminal;
    if (terminalFont != null) this.terminalFont = terminalFont;
    if (terminalLineHeight != null) {
      this.terminalLineHeight = terminalLineHeight;
    }
    notifyListeners();
    return Future.value();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RecordingPreferences preferences;
  late FakeProcess process;
  late ConsoleSession session;
  late AppServices services;
  var launches = 0;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    messenger.setMockMethodCallHandler(
      const MethodChannel('flit/env'),
      (_) async => {'home': '/test/home', 'prefix': '/test/usr'},
    );
    preferences = RecordingPreferences();
    await preferences.load();
    process = FakeProcess();
    launches = 0;
    session = ConsoleSession(
      title: 'shell',
      kind: SessionKind.shell,
      launcher:
          ({
            required command,
            required workingDirectory,
            required rows,
            required columns,
          }) async {
            launches++;
            return process;
          },
    );
    await session.start(command: 'bash');
    services = testServices(preferences: preferences);
  });

  tearDown(() async {
    preferences.dispose();
    messenger.setMockMethodCallHandler(const MethodChannel('flit/env'), null);
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          navigatorObservers: [services.routeObserver],
          home: Scaffold(
            body: TerminalHost(
              session: session,
              expanded: true,
              onToggle: () {},
              preferredHeight: 420,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'pinch updates cell geometry, saves once, and keeps the process and input client',
    (tester) async {
      await open(tester);
      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      state.requestKeyboard();
      await tester.pump();
      final columns = session.terminal.viewWidth;
      final center = tester.getCenter(find.byType(TerminalView));
      final first = await tester.startGesture(
        center - const Offset(40, 0),
        pointer: 1,
      );
      final second = await tester.startGesture(
        center + const Offset(40, 0),
        pointer: 2,
      );
      await tester.pump();
      await first.moveBy(const Offset(-30, 0));
      await second.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(
        tester
            .widget<TerminalView>(find.byType(TerminalView))
            .textStyle
            .fontSize,
        closeTo(22.75, .1),
      );
      expect(session.terminal.viewWidth, lessThan(columns));
      expect(preferences.terminalWrites, 0);
      await second.up();
      await first.up();
      await tester.pumpAndSettle();
      expect(preferences.terminalWrites, 1);
      expect(preferences.terminalSize, 23);
      expect(
        tester.state<TerminalViewState>(find.byType(TerminalView)),
        same(state),
      );
      expect(state.hasInputConnection, isTrue);
      expect(launches, 1);
      expect(process.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
      final closing = session.close();
      await tester.pump();
      await closing;
    },
  );

  testWidgets(
    'one finger scroll remains scrolling and pinch does not open the keyboard',
    (tester) async {
      await open(tester);
      session.terminal.write(List.generate(100, (i) => 'line $i\r\n').join());
      await tester.pumpAndSettle();
      final center = tester.getCenter(find.byType(TerminalView));
      final before = session.scrollController.offset;
      await tester.dragFrom(center, const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(session.scrollController.offset, lessThan(before));
      expect(preferences.terminalWrites, 0);
      final first = await tester.startGesture(
        center - const Offset(60, 0),
        pointer: 1,
      );
      final second = await tester.startGesture(
        center + const Offset(60, 0),
        pointer: 2,
      );
      await first.moveBy(const Offset(20, 0));
      await second.moveBy(const Offset(-20, 0));
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(preferences.terminalSize, 8.5);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(session.controller.selection, isNull);
      expect(process.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
      final closing = session.close();
      await tester.pump();
      await closing;
    },
  );

  testWidgets(
    'font settings apply live to existing view and reset selected font',
    (tester) async {
      await open(tester);
      final view = tester.state<TerminalViewState>(find.byType(TerminalView));
      await tester.tap(find.byTooltip('终端字体与缩放'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('放大终端字号'));
      await tester.pumpAndSettle();
      expect(preferences.terminalSize, 14);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('系统等宽字体').last);
      await tester.pumpAndSettle();
      final style = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .textStyle;
      expect(style.fontFamily, 'monospace');
      expect(style.fontSize, 14);
      await tester.ensureVisible(find.text('恢复终端默认外观'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复终端默认外观'));
      await tester.pumpAndSettle();
      expect(preferences.terminalFont, 'JetBrainsMono');
      expect(preferences.terminalSize, 13);
      expect(preferences.terminalLineHeight, 1.2);
      await tester.tap(find.byKey(const ValueKey('adaptive-sheet-close')));
      await tester.pumpAndSettle();
      expect(
        tester.state<TerminalViewState>(find.byType(TerminalView)),
        same(view),
      );
      expect(launches, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      final closing = session.close();
      await tester.pump();
      await closing;
    },
  );
}
