import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flit/features/environment/setup_runner.dart';
import 'package:flit/features/environment/toolchain_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'sourcing generated environment is idempotent and never rewrites APT',
    () async {
      final root = Directory.systemTemp.createTempSync('flit-env-');
      addTearDown(() => root.deleteSync(recursive: true));
      final home = Directory('${root.path}/home')..createSync();
      final prefix = Directory('${root.path}/usr')..createSync();
      final source = File('${prefix.path}/etc/apt/sources.list');
      source.parent.createSync(recursive: true);
      source.writeAsStringSync('keep this configuration\n');
      final catalog = ToolchainCatalog()
        ..fetchJson = (_) async =>
            throw StateError('Environment checks must stay offline');
      await SetupRunner(
        home: home.path,
        prefix: prefix.path,
        catalog: catalog,
      ).installScripts();
      final environment = File('${home.path}/.flit/env.sh').readAsStringSync();
      expect(environment, isNot(contains('.tar.xz')));
      expect(environment, isNot(contains('SHA256=')));
      expect(environment, isNot(contains('toolchain_manifest')));
      final result = await Process.run(
        'bash',
        [
          '-eu',
          '-c',
          r'''
. "$HOME/.flit/env.sh"
first_path=$PATH
first_lib=$LD_LIBRARY_PATH
. "$HOME/.flit/env.sh"
[ "$PATH" = "$first_path" ]
[ "$LD_LIBRARY_PATH" = "$first_lib" ]
[ "$FLUTTER_VERSION" = "3.47.8" ]
[ "$ADB_EMU" = "0" ]
[ "${PATH%%:*}" = "$HOME/toolchains/flutter/current/bin" ]
case ":$PATH:" in *":$ANDROID_HOME/platform-tools:$PREFIX/bin:"*) ;; *) exit 2 ;; esac
printf '%s\n' "$PATH" "$LD_LIBRARY_PATH"
''',
        ],
        environment: {
          'HOME': home.path,
          'PREFIX': prefix.path,
          'PATH':
              '${prefix.path}/bin:${home.path}/toolchains/android-sdk/platform-tools:/usr/bin:/bin',
          'LD_LIBRARY_PATH': '${prefix.path}/lib',
        },
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(source.readAsStringSync(), 'keep this configuration\n');
      expect(
        Directory('${prefix.path}/etc/apt/sources.list.d').existsSync(),
        isFalse,
      );
    },
    // 该用例用 bash 实际 source env.sh 来验证幂等；Windows 没有 bash
    // （Git 自带的 bash 不在 PATH 且行为不同），属平台专属用例。
    skip: Platform.isWindows ? '需要 POSIX bash' : false,
  );
  test(
    'default installation resolves one stage lazily and keeps initialization mode',
    () async {
      final requests = <String>[];
      final catalog = ToolchainCatalog()
        ..fetchJson = (url) async {
          requests.add(url);
          return {
            'tag_name': 'sdk-36.0.0',
            'assets': [
              {
                'name': 'android-sdk.tar.xz',
                'size': 1,
                'browser_download_url': 'https://example.invalid/sdk',
                'digest': 'sha256:${'a' * 64}',
              },
            ],
          };
        };
      final runner = SetupRunner(
        home: '/home',
        prefix: '/usr',
        catalog: catalog,
      );
      final plain = await runner.stageCommand('android_jdk');
      expect(plain, contains('android_jdk.sh'));
      expect(requests, isEmpty);
      final command = await runner.stageCommand('android_sdk');
      expect(requests.single, endsWith('/releases/tags/sdk-36.0.0'));
      expect(command, contains('--install'));
      expect(command, contains("'android-sdk' '36.0.0'"));
      expect(command, contains('https://example.invalid/sdk'));
    },
  );
}
