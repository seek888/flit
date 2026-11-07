import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flit/features/environment/desktop_setup_runner.dart';
import 'package:flit/features/environment/environment_controller.dart';
import 'package:flit/features/environment/installed_toolchain.dart';
import 'package:flit/features/environment/setup_event.dart';
import 'package:flit/services/desktop_toolchain.dart';

void main() {
  late Directory root;
  late DesktopSetupRunner runner;
  late ToolchainLayout layout;

  setUp(() {
    root = Directory.systemTemp.createTempSync('flit-desktop-runner-');
    final toolchain = DesktopToolchain(home: root.path);
    layout = toolchain.layout;
    runner = DesktopSetupRunner(toolchain: toolchain);
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test('desktop never needs a Termux bootstrap', () {
    expect(runner.needsBootstrap, isFalse);
  });

  test('plan is exactly readyStageIds (no drift between lists)', () {
    expect(runner.plan, readyStageIds);
    expect(runner.plan.length, 8);
    expect(runner.plan, isNot(contains('bootstrap')));
  });

  test('check() emits exactly the 8 readyStageIds in order', () {
    final markers = runner.check();
    expect(markers.map((marker) => marker.id).toList(), readyStageIds);
  });

  test(
    'empty home: required stages missing, optional stages DONE with note',
    () {
      final markers = {for (final marker in runner.check()) marker.id: marker};
      expect(markers['android_jdk']!.ok, isFalse);
      expect(markers['android_sdk']!.ok, isFalse);
      // CI/开发机通常已经装了系统 git，桌面端会「采用」它（不重复安装），
      // 所以 git 阶段在空 home 下也可能是 DONE —— 这里不强制 false。
      expect(markers['flutter_sdk']!.ok, isFalse);
      expect(markers['flutter_warmup']!.ok, isFalse);

      for (final id in <String>[
        'android_ndk',
        'android_cmake',
        'android_gradle',
      ]) {
        expect(markers[id]!.ok, isTrue, reason: id);
        expect(markers[id]!.note, isNotNull, reason: id);
      }
    },
  );

  test(
    'prepare() creates the private directories without writing scripts',
    () async {
      await runner.prepare();
      expect(Directory(layout.home).existsSync(), isTrue);
      expect(Directory(layout.cacheDir).existsSync(), isTrue);
      expect(Directory(layout.dotFlitDir).existsSync(), isTrue);
      // 桌面不部署 Android 的 16 个 .sh 脚本
      expect(
        Directory(
          '${layout.dotFlitDir}${Platform.pathSeparator}scripts',
        ).existsSync(),
        isFalse,
      );
    },
  );

  test('optional stage run yields DONE without touching the network', () async {
    final events = await runner.runStage('android_ndk').toList();
    expect(
      events.whereType<StageEvent>().map((event) => event.state).toList(),
      <String>['RUNNING', 'DONE'],
    );
    final logs = events.whereType<LogEvent>().map((event) => event.line);
    expect(logs.join(' '), contains('按需安装'));
  });

  test('listInstalled is empty on a fresh home', () async {
    expect(await runner.listInstalled(), isEmpty);
  });

  test('uninstall deletes the resolved component directory', () async {
    final flutterDir = Directory(layout.flutterDir)
      ..createSync(recursive: true);
    File(
      '${flutterDir.path}${Platform.pathSeparator}flutter${Platform.isWindows ? '.bat' : ''}',
    ).writeAsStringSync('x');
    expect(flutterDir.existsSync(), isTrue);

    await runner.uninstall(
      const InstalledToolchain(
        path: 'flutter/3.47.8',
        sizeKb: 1,
        active: true,
        complete: true,
        revision: '3.47.8',
      ),
    );
    expect(flutterDir.existsSync(), isFalse);
  });

  test('skipWarmup writes the offline marker without exec', () async {
    await runner.prepare();
    expect(runner.toolchain.probe.warmupMarked, isFalse);
    await runner.skipWarmup();
    expect(File(layout.warmupMarkerFile).existsSync(), isTrue);
    expect(runner.toolchain.probe.warmupMarked, isTrue);
    // 没有 Flutter SDK 时，结构判据仍然是 MISSING（不撒谎）
    expect(
      runner.check().firstWhere((m) => m.id == 'flutter_warmup').ok,
      isFalse,
    );
  });
}
