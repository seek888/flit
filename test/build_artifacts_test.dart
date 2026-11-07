import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flit/core/host_platform.dart';
import 'package:flit/features/run/web_runner.dart';
import 'package:flit/features/terminal/run_sessions.dart';
import 'package:flit/features/workspace/project_actions.dart';
import 'package:flit/features/workspace/project_documents.dart';

import 'support/fake_session_process.dart';

/// `builtArtifacts` 是「构建完用户能看到产物」的唯一链路：只有成功会话才推，
/// Web 产物在桌面是目录（build/web），Android 是入口文件（build/web/index.html）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProjectDocuments documents;
  late RunSessions executions;
  late WebRunController web;
  late ProjectActions actions;
  final processes = <FakeProcess>[];
  final commands = <String?>[];
  bool saveSucceeds = true;

  setUp(() {
    setHostPlatform(HostPlatform.windows);
    processes.clear();
    commands.clear();
    saveSucceeds = true;
    documents = ProjectDocuments(
      '/project',
      read: (_) async => 'old',
      write: (_, _) async => saveSucceeds,
    );
    executions = RunSessions(
      projectPath: '/project',
      launcher:
          ({
            required command,
            required workingDirectory,
            required rows,
            required columns,
          }) async {
            commands.add(command);
            final process = FakeProcess();
            processes.add(process);
            return process;
          },
    );
    web = WebRunController(
      executions,
      allocatePort: () async => 12345,
      prepareWeb: (_) async {},
    );
    actions = ProjectActions(
      path: '/project',
      documents: documents,
      executions: executions,
      web: web,
      devices: () async => const [],
      prepareWeb: (_) async {},
    );
  });

  tearDown(() async {
    actions.dispose();
    web.dispose();
    await executions.closeAll();
    await documents.close();
    setHostPlatform(null);
  });

  test('a successful web build reports the build/web directory', () async {
    final artifacts = <String>[];
    final watch = actions.builtArtifacts.listen(artifacts.add);
    final build = await actions.build(ProjectBuild.web);
    expect(commands.single, buildWebCommand);
    expect(commands.single, isNot(contains('bash')));
    await processes.single.finish();
    await build.done;
    await Future<void>.delayed(Duration.zero);
    expect(artifacts, ['build/web']);
    await watch.cancel();
  });

  test('a failed web build reports no artifact', () async {
    final artifacts = <String>[];
    final watch = actions.builtArtifacts.listen(artifacts.add);
    final build = await actions.build(ProjectBuild.web);
    await processes.single.finish(1);
    await build.done;
    await Future<void>.delayed(Duration.zero);
    expect(artifacts, isEmpty);
    await watch.cancel();
  });

  test('desktop APK build runs flutter directly and reports the apk', () async {
    final artifacts = <String>[];
    final watch = actions.builtArtifacts.listen(artifacts.add);
    final build = await actions.build(ProjectBuild.debugApk);
    expect(
      commands.single,
      'flutter build apk --debug --target-platform android-arm64 2>&1',
    );
    await processes.single.finish();
    await build.done;
    await Future<void>.delayed(Duration.zero);
    expect(artifacts, ['build/app/outputs/flutter-apk/app-debug.apk']);
    await watch.cancel();
  });

  test('web artifact falls back to index.html on Android', () {
    setHostPlatform(HostPlatform.android);
    expect(ProjectBuild.web.configuration.artifactPath, 'build/web/index.html');
    expect(ProjectBuild.web.configuration.command, buildWebCommand);
  });
}
