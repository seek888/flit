import 'dart:async';
import 'dart:io';

import 'package:flit/features/environment/environment_controller.dart';
import 'package:flit/features/environment/installed_toolchain.dart';
import 'package:flit/features/environment/toolchain_catalog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flit/core/host_platform.dart';

import 'support/fake_session_process.dart';
import 'support/flit_plugins.dart';
import 'support/host_platform.dart';

void main() {
  // 本组断言的是 Android 安装脚本语义（flit/env mock + check.sh）。
  // Windows CI 宿主上必须固定成 Android，否则产品代码会走桌面分支绕过桩。
  useHostPlatform(HostPlatform.android);
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late EnvironmentController environment;
  final commands = <String>[];
  var projectBusy = false;
  var damaged = false;
  var checkCode = 0;
  var languageRestarts = 0;
  var listCode = 0;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('flit-environment-audit-');
    commands.clear();
    projectBusy = false;
    damaged = false;
    checkCode = 0;
    languageRestarts = 0;
    listCode = 0;
    mockFlitPlugins(binding.defaultBinaryMessenger);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flit/env'),
      (call) async {
        if (call.method == 'bootstrapStatus') {
          return {
            'home': root.path,
            'prefix': '${root.path}/usr',
            'bootstrapped': true,
          };
        }
        if (call.method == 'exec') {
          final isList = (call.arguments['cmd'] as String? ?? '').contains(
            '--list',
          );
          return {'exitCode': isList ? listCode : 0, 'output': ''};
        }
        return true;
      },
    );
    environment = EnvironmentController(
      projectBusy: () => projectBusy,
      onFlutterChanged: () async {
        languageRestarts++;
      },
      launcher:
          ({
            required command,
            required workingDirectory,
            required rows,
            required columns,
          }) async {
            commands.add(command!);
            final process = FakeProcess();
            if (command.contains('check.sh')) {
              for (final id in readyStageIds) {
                final state =
                    damaged &&
                        (id == 'android_gradle' || id == 'flutter_warmup')
                    ? 'PENDING'
                    : 'DONE';
                process.emit('__STAGE__$id:$state\n');
              }
              unawaited(process.finish(checkCode));
            } else {
              // 模拟安装命令退出 0，但后续只读 probe 发现未修好，不能继续推进。
              if (command.contains('android_gradle.sh')) {
                process.emit(
                  '__STAGE__android_gradle:DONE\n__STAGE__android_gradle:PENDING\n',
                );
              }
              unawaited(process.finish());
            }
            return process;
          },
    );
    await environment.init();
    expect(environment.allDone, true);
    commands.clear();
  });

  tearDown(() async {
    await environment.console?.close();
    environment.dispose();
    root.deleteSync(recursive: true);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flit/env'),
      null,
    );
  });

  const flutter = InstalledToolchain(
    path: 'flutter/3.48.0',
    sizeKb: 1,
    active: false,
    complete: true,
    revision: '',
  );

  test(
    'failed inventory keeps last local versions and exposes unknown state',
    () async {
      expect(environment.installedLoaded, isTrue);
      environment.installed = [flutter];
      listCode = 1;
      await environment.refreshStatus();
      expect(environment.installed, [flutter]);
      expect(environment.installedError, isNotNull);
      listCode = 0;
      await environment.refreshStatus();
      expect(environment.installed, isEmpty);
      expect(environment.installedError, isNull);
    },
  );

  test(
    'continuing setup rechecks stale readiness and stops on failed postcheck',
    () async {
      damaged = true;
      await environment.startPipeline();
      expect(commands.first, contains('check.sh'));
      expect(
        commands.any(
          (c) => c.contains('android_gradle.sh') && c.endsWith('--check'),
        ),
        true,
      );
      expect(environment.stages['android_gradle']!.state, 'FAILED');
      expect(environment.stages['flutter_warmup']!.state, 'BLOCKED');
      expect(environment.allDone, false);
      expect(environment.busy, false);
    },
  );

  test(
    'a nonzero check never reports all ready even after DONE markers',
    () async {
      checkCode = 7;
      await environment.refreshStatus();
      expect(environment.allDone, false);
    },
  );

  test(
    'running projects block install, switch, delete and initialization',
    () async {
      projectBusy = true;
      await environment.changeInstalled(flutter);
      await environment.changeInstalled(flutter, delete: true);
      await environment.startPipeline();
      await environment.installFromCatalog(
        const CatalogEntry(
          component: 'cmake',
          repo: 'example/repo',
          tag: 'cmake-3.22.1',
          name: 'cmake.tar.xz',
          url: 'https://example.test/cmake',
          size: 1,
          sha256: null,
        ),
      );
      expect(commands, isEmpty);
      expect(environment.installing, false);
    },
  );

  test(
    'switching Flutter restarts the language service and refreshes status',
    () async {
      await environment.changeInstalled(flutter);
      expect(commands.first, contains("--select '3.48.0'"));
      expect(languageRestarts, 1);
      expect(commands.last, contains('check.sh'));
      expect(environment.allDone, true);
    },
  );
}
