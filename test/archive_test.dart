import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flit/services/toolchain/archive.dart';
import 'package:flit/services/toolchain/errors.dart';
import 'package:flit/services/toolchain/process.dart';

/// 记录调用并按名字返回退出码/抛异常的假进程网关。
class _FakeGateway implements ToolchainProcessGateway {
  final List<String> executed = <String>[];
  final List<List<String>> arguments = <List<String>>[];
  final Map<String, int> exitCodes = <String, int>{};
  final Set<String> throwing = <String>{};

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 25),
    String? workingDirectory,
  }) async {
    executed.add(executable);
    arguments.add(args);
    if (throwing.contains(executable)) {
      throw ToolchainException('command not found: $executable');
    }
    final code = exitCodes[executable] ?? 0;
    return ProcessResult(0, code, '', code == 0 ? '' : 'failed');
  }

  @override
  Future<int> runWithStdin(
    String executable,
    List<String> args, {
    String stdinText = '',
    Map<String, String>? environment,
    Duration timeout = const Duration(minutes: 5),
    String? workingDirectory,
  }) async => 0;

  @override
  Stream<String> stream(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    Duration timeout = const Duration(minutes: 30),
    String? workingDirectory,
    void Function(int exitCode)? onClosed,
  }) => const Stream<String>.empty();
}

void main() {
  late Directory root;
  late _FakeGateway gateway;

  setUp(() {
    root = Directory.systemTemp.createTempSync('flit-archive-test-');
    gateway = _FakeGateway();
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test('windows uses tar.exe first and stops when it succeeds', () async {
    final extractor = ArchiveExtractor(process: gateway, windows: true);
    final destination = '${root.path}${Platform.pathSeparator}out';
    await extractor.extract('pkg.zip', destination);

    expect(gateway.executed, <String>['tar.exe']);
    expect(gateway.arguments.single, <String>[
      '-xf',
      'pkg.zip',
      '-C',
      destination,
    ]);
    expect(Directory(destination).existsSync(), isTrue);
  });

  test(
    'tar failure falls back to one PowerShell Expand-Archive command',
    () async {
      gateway.exitCodes['tar.exe'] = 1;
      final extractor = ArchiveExtractor(process: gateway, windows: true);
      final destination = '${root.path}${Platform.pathSeparator}out';
      await extractor.extract('pkg.zip', destination);

      expect(gateway.executed, <String>['tar.exe', 'powershell.exe']);
      final command = gateway.arguments.last;
      expect(command.first, '-NoProfile');
      expect(command.join(' '), contains('Expand-Archive -LiteralPath'));
      expect(command.join(' '), contains('-Force'));
    },
  );

  test(
    'missing tar.exe (ProcessException) also falls back to PowerShell',
    () async {
      gateway.throwing.add('tar.exe');
      final extractor = ArchiveExtractor(process: gateway, windows: true);
      await extractor.extract(
        'pkg.zip',
        '${root.path}${Platform.pathSeparator}out',
      );

      expect(gateway.executed, <String>['tar.exe', 'powershell.exe']);
    },
  );

  test('both extractors failing throws a readable ArchiveException', () async {
    gateway.throwing.add('tar.exe');
    gateway.exitCodes['powershell.exe'] = 1;
    final extractor = ArchiveExtractor(process: gateway, windows: true);

    await expectLater(
      extractor.extract('pkg.zip', '${root.path}${Platform.pathSeparator}out'),
      throwsA(
        isA<ArchiveException>().having(
          (error) => error.message,
          'message',
          allOf(contains('tar.exe'), contains('PowerShell')),
        ),
      ),
    );
  });

  test('posix uses unzip and reports its failure', () async {
    final extractor = ArchiveExtractor(process: gateway, windows: false);
    await extractor.extract(
      'pkg.zip',
      '${root.path}${Platform.pathSeparator}out',
    );
    expect(gateway.executed, <String>['unzip']);

    gateway.exitCodes['unzip'] = 2;
    await expectLater(
      extractor.extract('pkg.zip', '${root.path}${Platform.pathSeparator}out'),
      throwsA(isA<ArchiveException>()),
    );
  });
}
