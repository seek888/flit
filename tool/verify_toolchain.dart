// 桌面工具链「真实网络」验证工具。
//
// 这个脚本把 Windows 工具链完整装进一个临时目录（默认走国内镜像），然后
// 真的执行 java / flutter / adb / git / sdkmanager 打印版本，最后输出结构判据
// 与 `__STAGE__/__VER__` marker。它同时是「镜像是否可用」的可执行证据：
// 每一步日志都会打印实际下载源。
//
// 用法：
//   dart tool/verify_toolchain.dart --home D:\flit-verify\home
//   dart tool/verify_toolchain.dart --stages jdk,sdk --official
//
// 选项：
//   --home <dir>     安装目录（默认：系统临时目录下的 flitdesk-verify）
//   --stages <list>  只跑指定阶段：jdk,sdk,git,flutter,warmup（默认全部）
//   --official       关闭国内镜像，走官方源（验证回退路径）
//   --clean          结束后删除安装目录
//
// 退出码：0 = 结构判据全部就绪，且 flutter 预热完成；1 = 有阶段失败。
//
// 注意：本脚本只 import `lib/services/toolchain`（纯 dart:io，不依赖 Flutter
// 框架），可以直接 `dart tool/verify_toolchain.dart`，不要求先 `flutter pub get`。
//
// ignore_for_file: avoid_print, avoid_relative_lib_imports
import 'dart:io';

import '../lib/services/toolchain/gradle_wrapper.dart';
import '../lib/services/toolchain/installer.dart';
import '../lib/services/toolchain/layout.dart';
import '../lib/services/toolchain/probe.dart';
import '../lib/services/toolchain/process.dart';
import '../lib/services/toolchain/sdk_manager.dart';

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  final home = options.home ??
      Directory.systemTemp
          .createTempSync('flitdesk-verify-')
          .path;
  final layout = ToolchainLayout(
    home: home,
    jdkMirrorBaseUrl: options.official ? '' : null,
    androidSdkRepoBase:
        options.official ? ToolchainLayout.officialAndroidSdkBase : null,
    flutterStorageBaseUrl:
        options.official ? ToolchainLayout.officialFlutterStorageBaseUrl : null,
    pubHostedUrl: options.official ? 'https://pub.dev' : null,
  );
  final installer = ToolchainInstaller(layout: layout);
  final probe = ToolchainProbe(layout: layout);
  final gateway = const SystemToolchainProcess();

  stdout.writeln('Flit 桌面工具链验证');
  stdout.writeln('  安装目录：${layout.home}');
  stdout.writeln('  ${installer.downloadSourceSummary}');
  stdout.writeln('  模式：${options.official ? '官方源' : '国内镜像（镜像失败自动回退官方）'}');

  final stages = <String, Stream<String> Function()>{
    'jdk': installer.installJdk,
    'sdk': installer.installAndroidSdk,
    'git': installer.installGit,
    'flutter': installer.installFlutter,
    'warmup': installer.warmUp,
  };

  if (options.gradleProject != null) {
    stages['gradle'] = () => GradleWrapperCache(
      layout: layout,
    ).ensure(options.gradleProject!);
  }

  var failed = false;
  for (final stage in options.stages) {
    final run = stages[stage];
    if (run == null) {
      stdout.writeln('\n[跳过] 未知阶段：$stage');
      continue;
    }
    stdout.writeln('\n=== 阶段 $stage ===');
    try {
      await for (final line in run()) {
        stdout.writeln('  $line');
      }
      stdout.writeln('[完成] $stage');
    } catch (error) {
      failed = true;
      stdout.writeln('[失败] $stage：$error');
    }
  }

  final status = probe.inspect();
  stdout.writeln('\n=== 结构判据 ===');
  stdout.writeln('  ${status.summary}');
  for (final marker in status.toStageMarkers()) {
    final note = marker.note == null ? '' : '（${marker.note}）';
    final version = marker.version == null ? '' : ' ${marker.version}';
    stdout.writeln(
      '  ${marker.id.padRight(16)} ${marker.ok ? 'DONE  ' : 'MISSING'}$version$note',
    );
  }
  stdout.writeln('\n=== __STAGE__/__VER__ ===');
  stdout.writeln(status.stageMarkerText());

  stdout.writeln('\n=== 组件自检（真实执行）===');
  final checks = <Future<void>>[
    _run(gateway, layout, 'java', layout.javaExe, const <String>['-version']),
    _run(gateway, layout, 'flutter', layout.flutterBat, const <String>['--version']),
    _run(gateway, layout, 'adb', layout.adbExe, const <String>['version']),
    _run(gateway, layout, 'git', _gitPath(layout), const <String>['--version']),
    _runSdkManager(gateway, layout),
  ];
  for (final check in checks) {
    await check;
  }

  stdout.writeln('\n=== 结论 ===');
  final ready = status.ready && (status.warmup || !options.stages.contains('warmup'));
  stdout.writeln(
    '  Flutter ${status.versions['flutter'] ?? '?'} · '
    'JDK ${status.versions['jdk'] ?? '?'} · '
    'SDK ${status.versions['androidSdk'] ?? '?'} · '
    'Git ${status.versions['git'] ?? '?'}',
  );
  stdout.writeln('  ${ready && !failed ? 'PASS（环境就绪）' : 'FAIL（见上面的失败/缺失项）'}');

  if (options.clean) {
    try {
      Directory(layout.home).deleteSync(recursive: true);
      stdout.writeln('  已清理：${layout.home}');
    } catch (error) {
      stdout.writeln('  清理失败：$error');
    }
  } else {
    stdout.writeln('  保留目录（可用 --clean 清理）：${layout.home}');
  }

  exitCode = ready && !failed ? 0 : 1;
}

/// 私有 MinGit 优先，其次系统 PATH 里的 git（桌面端会「采用」系统 git）。
String _gitPath(ToolchainLayout layout) {
  if (File(layout.gitExe).existsSync()) return layout.gitExe;
  return layout.which('git') ?? layout.gitExe;
}

Future<void> _run(
  ToolchainProcessGateway gateway,
  ToolchainLayout layout,
  String label,
  String executable,
  List<String> arguments,
) async {
  if (!File(executable).existsSync()) {
    stdout.writeln('  $label: 未安装（$executable 不存在）');
    return;
  }
  try {
    final result = await gateway.run(
      executable,
      arguments,
      environment: layout.childEnvironment(),
      timeout: const Duration(minutes: 3),
    );
    final first = '${result.stdout}${result.stderr}'
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(3)
        .join(' | ');
    stdout.writeln('  $label: ${first.isEmpty ? '（无输出）' : first}');
  } catch (error) {
    stdout.writeln('  $label: 执行失败 $error');
  }
}

Future<void> _runSdkManager(
  ToolchainProcessGateway gateway,
  ToolchainLayout layout,
) async {
  final manager = SdkManager(layout: layout, process: gateway);
  final jar = manager.classpathJar;
  if (jar == null) {
    stdout.writeln('  sdkmanager: 未安装（缺少 classpath jar）');
    return;
  }
  try {
    final result = await gateway.run(
      layout.javaExe,
      <String>[...manager.commandPrefix, '--version'],
      environment: layout.childEnvironment(),
      timeout: const Duration(minutes: 3),
    );
    final text = '${result.stdout}${result.stderr}'
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(2)
        .join(' | ');
    stdout.writeln(
      '  sdkmanager: ${text.isEmpty ? '（无输出）' : text}'
      ' · 源 ${manager.repositorySource}',
    );
  } catch (error) {
    stdout.writeln('  sdkmanager: 执行失败 $error');
  }
}

class _Options {
  _Options({
    this.home,
    this.gradleProject,
    required this.stages,
    required this.official,
    required this.clean,
  });

  final String? home;

  /// 指定工程目录时可用 `--stages gradle` 验证 Gradle 发行版预置。
  final String? gradleProject;
  final Set<String> stages;
  final bool official;
  final bool clean;

  static const List<String> allStages = <String>[
    'jdk',
    'sdk',
    'git',
    'flutter',
    'warmup',
  ];

  static _Options parse(List<String> arguments) {
    String? home;
    String? gradleProject;
    var stages = allStages.toSet();
    var official = false;
    var clean = false;
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      switch (argument) {
        case '--home':
          if (i + 1 < arguments.length) home = arguments[++i];
        case '--gradle-project':
          if (i + 1 < arguments.length) gradleProject = arguments[++i];
        case '--stages':
          if (i + 1 < arguments.length) {
            stages = arguments[++i]
                .split(',')
                .map((value) => value.trim())
                .where((value) => value.isNotEmpty)
                .toSet();
          }
        case '--official':
          official = true;
        case '--clean':
          clean = true;
        default:
          stdout.writeln('忽略未知参数：$argument');
      }
    }
    return _Options(
      home: home,
      gradleProject: gradleProject,
      stages: stages,
      official: official,
      clean: clean,
    );
  }
}