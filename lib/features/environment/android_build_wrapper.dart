import 'package:flit/l10n/strings.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../services/desktop_toolchain.dart';
import '../../services/shell.dart';
import '../../services/toolchain/gradle_wrapper.dart';
import '../terminal/run_sessions.dart';
import 'android_component_probe.dart';
import 'setup_runner.dart';
import 'toolchain_catalog.dart';

export 'android_component_probe.dart' show AndroidComponent;

/// 组件检查的注入点：Android 侧是 bash 探测脚本的解析结果，桌面侧是纯 Dart
/// 目录扫描（[AndroidComponentProbe]），测试可以整体替换。
typedef AndroidComponentCheck =
    Future<List<AndroidComponent>> Function(
      List<AndroidComponent> components, {
      bool baseline,
      bool device,
    });

/// UI 只展示请求和返回选择；下载地址、版本匹配和重试不进入 Widget。
class AndroidRepairRequest {
  const AndroidRepairRequest(
    this.components, {
    required this.afterFailure,
    this.error,
  });
  final List<AndroidComponent> components;
  final bool afterFailure;
  final String? error;
}

typedef ConfirmAndroidRepair =
    Future<bool> Function(AndroidRepairRequest request);
typedef AndroidLaunch =
    Future<RunSession> Function(
      RunConfiguration configuration,
      void Function(String)? onText,
    );

/// Android 构建的唯一补包入口，覆盖 APK 和设备 flutter run。
///
/// 前置检查只处理基础工具和字面量版本，不模拟执行 Gradle。动态版本、插件和
/// 多模块依赖交给真实构建诊断；只有明确的缺包错误才允许安装。一次启动最多
/// 做一次失败恢复，避免重试循环。关闭项目/会话或启动新任务后，旧回调失效。
class AndroidBuildWrapper {
  AndroidBuildWrapper({
    required this.executions,
    ToolchainCatalog? catalog,
    Future<Map<dynamic, dynamic>> Function(String)? probe,
    Future<List<AndroidComponent>> Function()? requirements,
    AndroidComponentCheck? check,
    AndroidComponentProbe? componentProbe,
    Future<void> Function(List<AndroidComponent>)? install,
    GradleWrapperCache? gradleCache,
  }) : catalog = catalog ?? ToolchainCatalog(),
       _probe =
           probe ??
           ((command) => Shell.instance.exec(command, timeoutMs: 60000)),
       _requirements = requirements,
       _checkOverride = check,
       _componentProbe = componentProbe,
       _installOverride = install,
       _gradleCache = gradleCache;

  final RunSessions executions;
  final ToolchainCatalog catalog;
  final Future<Map<dynamic, dynamic>> Function(String) _probe;
  final Future<List<AndroidComponent>> Function()? _requirements;
  final AndroidComponentCheck? _checkOverride;

  /// 桌面端组件探测（默认 `DesktopToolchain().sdkDir` 的结构扫描）。
  final AndroidComponentProbe? _componentProbe;

  /// 桌面端组件补齐（默认走 D3 的 `DesktopToolchain.ensureComponents`）。
  final Future<void> Function(List<AndroidComponent>)? _installOverride;

  /// 桌面端 Gradle 发行版缓存（默认私有 `gradle-home`；单测可注入）。
  final GradleWrapperCache? _gradleCache;
  int _generation = 0;
  bool _closed = false;

  /// 与环境页共享安装互斥，防止两个入口同时覆盖 SDK 或同一 staging 目录。
  static final installationBusy = ValueNotifier(false);
  static bool get installing => installationBusy.value;
  static set installing(bool value) => installationBusy.value = value;

  void cancelPending() {
    _generation++;
  }

  void dispose() {
    _closed = true;
    _generation++;
  }

  Future<RunSession> start(
    RunConfiguration configuration, {
    required AndroidLaunch launch,
    required ConfirmAndroidRepair confirm,
    required Future<void> Function() save,
    bool device = false,
  }) async {
    final generation = ++_generation;
    bool current() => !_closed && generation == _generation;
    if (installing) {
      throw StateError(strings.aToolchainIsBeingInstalledPleaseWait);
    }
    await save();
    final declared = await (_requirements?.call() ?? _readRequirements());
    final missing = await _check(declared, baseline: true, device: device);
    if (!current()) throw StateError(strings.projectClosedOrTaskCancelled);
    if (missing.isNotEmpty &&
        !await _repair(missing, confirm, current, afterFailure: false)) {
      throw StateError(strings.requiredComponentsAreMissingBuildNotStarted);
    }
    if (!current()) throw StateError(strings.projectClosedOrTaskCancelled);
    // 桌面端先把工程需要的 Gradle 发行版落到私有 gradle-home（国内镜像），
    // 否则 gradlew 会直连 services.gradle.org，国内网络下构建会秒失败。
    final gradleLog = <String>[];
    if (isDesktopPlatform) {
      final cache =
          _gradleCache ?? GradleWrapperCache(layout: ToolchainLayout.defaultLayout());
      try {
        await for (final line in cache.ensure(executions.projectPath)) {
          gradleLog.add(line);
        }
      } catch (error) {
        throw StateError('Gradle 发行版准备失败：$error');
      }
      if (!current()) throw StateError(strings.projectClosedOrTaskCancelled);
    }
    final diagnostics = AndroidBuildDiagnostics();
    final session = await launch(configuration, diagnostics.add);
    for (final line in gradleLog) {
      session.log.line(line);
    }
    // 返回首个会话，让控制台立即显示；后续流程的异常写回原控制台，不能成为
    // 未处理的异步异常。重试仍走 ProjectActions，成功产物只由真实构建报告。
    unawaited(
      _recover(session, configuration, diagnostics, launch, confirm, current),
    );
    return session;
  }

  Future<void> _recover(
    RunSession session,
    RunConfiguration configuration,
    AndroidBuildDiagnostics diagnostics,
    AndroidLaunch launch,
    ConfirmAndroidRepair confirm,
    bool Function() current,
  ) async {
    bool valid() =>
        current() &&
        !session.disposed &&
        !session.stopRequested &&
        identical(executions.forConfiguration(configuration.id), session) &&
        executions.conflictFor(configuration) == null &&
        !executions.starting;
    try {
      final code = await session.done;
      diagnostics.finish();
      if (code == 0 || !valid()) return;
      if (diagnostics.blocker != null) {
        await confirm(
          AndroidRepairRequest(
            diagnostics.components,
            afterFailure: true,
            error: diagnostics.blocker,
          ),
        );
        return;
      }
      if (diagnostics.components.isEmpty) return;
      final missing = diagnostics.components;
      if (!await _repair(missing, confirm, valid, afterFailure: true)) return;
      if (!valid()) return;
      // 不再包裹第二次启动：新缺失/其他错误保持原始输出，由用户决定下一步。
      await launch(configuration, null);
    } catch (error) {
      if (!session.disposed) {
        session.log.err(strings.componentRepairIncompleteP(error));
      }
    }
  }

  Future<List<AndroidComponent>> _readRequirements() async {
    final result = <AndroidComponent>[];
    // 常用入口的明确声明只是提前发现问题的优化；不递归扫描缓存和插件源码。
    for (final relative in [
      'build.gradle',
      'build.gradle.kts',
      'app/build.gradle',
      'app/build.gradle.kts',
      'android/build.gradle',
      'android/build.gradle.kts',
      'android/app/build.gradle',
      'android/app/build.gradle.kts',
    ]) {
      final file = File('${executions.projectPath}/$relative');
      if (await file.exists()) {
        result.addAll(declaredComponents(await file.readAsString()));
      }
    }
    return _unique(result);
  }

  /// 组件检查的唯一入口：注入点 → 桌面纯 Dart 探测 → Android bash 协议。
  /// 返回值已去重，并应用「已声明 Build Tools 版本就不补默认版本」的豁免。
  Future<List<AndroidComponent>> _check(
    List<AndroidComponent> components, {
    bool baseline = false,
    bool device = false,
  }) async {
    final injected = _checkOverride;
    final List<AndroidComponent> raw;
    if (injected != null) {
      raw = await injected(components, baseline: baseline, device: device);
    } else if (isDesktopPlatform) {
      raw = await (_componentProbe ?? AndroidComponentProbe()).check(
        components,
        baseline: baseline,
        device: device,
      );
    } else {
      raw = await _probeMissing(components, baseline: baseline, device: device);
    }
    final missing = _unique(raw);
    // 已声明 Build Tools 时装该版本即可，它同时提供 AAPT2，无须再装默认版本。
    if (baseline &&
        components.any(
          (c) =>
              c.id == 'build-tools' && c.version != ToolchainCatalog.sdkVersion,
        ) &&
        !components.any(
          (c) =>
              c.id == 'build-tools' && c.version == ToolchainCatalog.sdkVersion,
        )) {
      missing.removeWhere(
        (c) =>
            c.id == 'build-tools' && c.version == ToolchainCatalog.sdkVersion,
      );
    }
    return missing;
  }

  /// Android 侧继续走 bash 探测脚本（脚本与 termux 工具链绑定，桌面不可用）。
  Future<List<AndroidComponent>> _probeMissing(
    List<AndroidComponent> components, {
    bool baseline = false,
    bool device = false,
  }) async {
    final args = [
      if (baseline) '--baseline',
      if (device) '--device',
      for (final c in components) '${c.id}:${c.version}',
    ];
    final result = await _probe(
      'bash "\$HOME/.flit/scripts/android_components.sh" ${args.map(shQuote).join(' ')}',
    );
    if (result['exitCode'] != 0) {
      throw StateError(
        strings.androidEnvironmentCheckFailedCompleteSetupIn(
          result['output'] ?? '',
        ),
      );
    }
    return [
      for (final line in (result['output'] as String? ?? '').split(
        RegExp(r'[\r\n]'),
      ))
        if (RegExp(r'^__MISSING__([a-z-]+):([0-9.]*)$').hasMatch(line))
          AndroidComponent(
            line.substring(11).split(':')[0],
            line.split(':').last,
          ),
    ];
  }

  Future<bool> _repair(
    List<AndroidComponent> missing,
    ConfirmAndroidRepair confirm,
    bool Function() current, {
    required bool afterFailure,
  }) async {
    // 普通打包可与 run 并存，但修复会替换共用工具链，仍需停止使用它的任务。
    if (executions.active != null) {
      if (current()) {
        await confirm(
          AndroidRepairRequest(
            missing,
            afterFailure: afterFailure,
            error: strings
                .installingComponentsChangesTheSharedDevelopmentEnvironment,
          ),
        );
      }
      return false;
    }
    // 桌面端不再拼 bash 脚本：组件补齐直接调 D3 的 sdkmanager/安装器，
    // 进度/许可证/镜像都在该层内部处理。
    if (isDesktopPlatform) {
      return _repairDesktop(
        missing,
        confirm,
        current,
        afterFailure: afterFailure,
      );
    }
    final commands = <String>[];
    final requested = [...missing];
    var managerPlanned = false;
    try {
      for (final component in missing) {
        try {
          commands.add(await _installCommand(component));
        } on HttpException catch (error) {
          // 仅 Platform 可回退到 Google，且只有明确的 404；网络故障不能伪装成缺包。
          if (component.id != 'platforms' || error.message != 'HTTP 404') {
            rethrow;
          }
          final manager = await _check([
            const AndroidComponent('cmdline-tools'),
          ]);
          if (manager.isNotEmpty && !managerPlanned) {
            managerPlanned = true;
            requested.addAll(manager);
            commands.add(await _installCommand(manager.single));
          }
          commands.add(
            'bash "\$HOME/.flit/scripts/android_platform.sh" ${shQuote(component.version)}',
          );
        }
      }
    } catch (error) {
      if (current()) {
        await confirm(
          AndroidRepairRequest(
            _unique(requested),
            afterFailure: afterFailure,
            error: strings.matchingVersionOrDownloadInformationUnavailableP(
              error,
            ),
          ),
        );
      }
      return false;
    }
    if (!current() ||
        !await confirm(
          AndroidRepairRequest(_unique(requested), afterFailure: afterFailure),
        ) ||
        !current()) {
      return false;
    }
    if (installing || executions.active != null || executions.starting) {
      throw StateError(strings.aTaskIsRunningStopItAnd);
    }
    installing = true;
    try {
      final repair = await executions.start(
        RunConfiguration(
          id: 'android-components',
          title: strings.installAndroidBuildComponents,
          command: commands.join(' && '),
          exclusive: true,
        ),
      );
      final code = await repair.done;
      if (code != 0 || repair.stopRequested || repair.disposed || !current()) {
        return false;
      }
      // 安装器验证包内版本和二进制；再从 SDK 路径复查，防止软链接或残包误报成功。
      final remaining = await _check(missing);
      if (remaining.isNotEmpty) {
        throw StateError(
          strings.stillUnavailableAfterInstallationP(
            remaining.map((c) => c.title).join('、'),
          ),
        );
      }
      return current();
    } finally {
      installing = false;
    }
  }

  /// 桌面端补齐：确认后用 sdkmanager 安装（D3 的 DesktopToolchain.ensureComponents），
  /// 再按同一探测复查，防止安装器报成功但目录不完整。
  Future<bool> _repairDesktop(
    List<AndroidComponent> missing,
    ConfirmAndroidRepair confirm,
    bool Function() current, {
    required bool afterFailure,
  }) async {
    final requested = _unique(missing);
    if (!current() ||
        !await confirm(
          AndroidRepairRequest(requested, afterFailure: afterFailure),
        ) ||
        !current()) {
      return false;
    }
    if (installing || executions.active != null || executions.starting) {
      throw StateError(strings.aTaskIsRunningStopItAnd);
    }
    installing = true;
    try {
      final install = _installOverride ?? _installDesktopComponents;
      await install(requested);
      if (!current()) return false;
      final remaining = await _check(requested);
      if (remaining.isNotEmpty) {
        throw StateError(
          strings.stillUnavailableAfterInstallationP(
            remaining.map((c) => c.title).join('、'),
          ),
        );
      }
      return current();
    } catch (error) {
      if (current()) {
        await confirm(
          AndroidRepairRequest(
            requested,
            afterFailure: afterFailure,
            error: '${error is StateError ? error.message : error}',
          ),
        );
      }
      return false;
    } finally {
      installing = false;
    }
  }

  /// 桌面端安装通道：D3 的 `ensureComponents` 自动补 cmdline-tools、接受许可证，
  /// 并按组件映射成 `platforms;android-36` 这类 sdkmanager 包名。
  Future<void> _installDesktopComponents(
    List<AndroidComponent> components,
  ) async {
    final toolchain = DesktopToolchain();
    await toolchain.ensureComponents([
      for (final c in components) (id: c.id, version: c.version),
    ]);
  }

  /// Android 侧补装命令（catalog + bash 安装脚本）；桌面端不使用这个方法。
  Future<String> _installCommand(AndroidComponent component) async {
    final version = component.version;
    final tag = switch (component.id) {
      'platforms' => 'platform-$version',
      'build-tools' => 'sdk-$version',
      'cmake' => 'cmake-$version',
      'ndk' => ndkTag(version),
      'platform-tools' || 'cmdline-tools' => null,
      _ => throw StateError(
        strings.automaticInstallationIsNotSupportedForP(component.title),
      ),
    };
    final entry = await catalog.resolve(component.id, tag: tag);
    final command = SetupRunner.installCommand(entry);
    // r28c 只能定位候选产物，完整 Pkg.Revision 必须由安装器在发布目录前验证。
    return component.id == 'ndk' ? '$command ${shQuote(version)}' : command;
  }

  static String ndkTag(String version) {
    final parts = version.split('.');
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
      throw StateError(strings.invalidNdkVersion);
    }
    final minor = int.parse(parts[1]);
    if (minor > 25) throw StateError(strings.unableToLocateNdkP(version));
    return 'ndk-r${parts[0]}${minor == 0 ? '' : String.fromCharCode(97 + minor)}';
  }

  static List<AndroidComponent> _unique(Iterable<AndroidComponent> values) =>
      {for (final c in values) c.key: c}.values.toList();

  /// 仅接受完整的一行字面量声明；flutter.ndkVersion、变量、函数交由失败诊断。
  static List<AndroidComponent> declaredComponents(String source) {
    final text = source.replaceAll(RegExp(r'/\*[\s\S]*?\*/|//[^\r\n]*'), '');
    final result = <AndroidComponent>[];
    for (final pair in [
      ('compileSdk(?:Version)?', 'platforms'),
      ('buildToolsVersion', 'build-tools'),
      ('ndkVersion', 'ndk'),
    ]) {
      final pattern = RegExp(
        '^\\s*${pair.$1}\\s*(?:=\\s*|\\(\\s*|\\s+)["\']?(?:android-)?([0-9]+(?:\\.[0-9]+)*)["\']?\\s*\\)?\\s*;?\\s*\$',
        multiLine: true,
      );
      for (final match in pattern.allMatches(text)) {
        final version = match[1]!;
        if (RegExp(
          pair.$2 == 'platforms' ? r'^\d+(?:\.\d+)?$' : r'^\d+\.\d+\.\d+$',
        ).hasMatch(version)) {
          result.add(AndroidComponent(pair.$2, version));
        }
      }
    }
    // 仅识别 cmake 块内、独占一行的字面量 version，避免把项目 version 当 CMake。
    for (final block in RegExp(r'\bcmake\s*\{([^{}]*)\}').allMatches(text)) {
      final match = RegExp(
        r'''^\s*version\s*(?:=\s*|\s+)["'](\d+\.\d+\.\d+)["']\s*;?\s*$''',
        multiLine: true,
      ).firstMatch(block[1]!);
      if (match != null) result.add(AndroidComponent('cmake', match[1]!));
    }
    return _unique(result);
  }
}

/// 按完整行解析 PTY 输出（ANSI 和 UTF-8 可以跨块）；只接受明确诊断，绝不把
/// 普通的版本提及、编译失败、网络错误当成缺包。限制行长，长日志不会无限占内存。
class AndroidBuildDiagnostics {
  String _pending = '';
  int _ndkContext = 0;
  int _packageContext = 0;
  final _found = <String, AndroidComponent>{};
  String? blocker;
  List<AndroidComponent> get components => _found.values.toList();
  void add(String chunk) {
    final lines = ('$_pending$chunk').split(RegExp(r'[\r\n]'));
    _pending = lines.removeLast();
    if (_pending.length > 32768) {
      _pending = _pending.substring(_pending.length - 32768);
    }
    for (final line in lines) {
      _line(line);
    }
  }

  void finish() {
    _line(_pending);
    _pending = '';
  }

  void _record(String id, String version) {
    if (!RegExp(
      id == 'platforms' ? r'^\d+(?:\.\d+)?$' : r'^\d+\.\d+\.\d+$',
    ).hasMatch(version)) {
      return;
    }
    final component = AndroidComponent(id, version);
    _found[component.key] = component;
  }

  void _line(String raw) {
    final line = raw
        .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
        .replaceFirst(RegExp(r'^\s*(?:>\s*)+'), '');
    // 缺许可证、显式路径错误不能靠重复安装同版本解决，不把它们伪装成缺包。
    if (RegExp(
      r'licen[cs]es?.*(?:not accepted|not been accepted|not been agreed|not accepted)',
      caseSensitive: false,
    ).hasMatch(line)) {
      blocker = strings.androidSdkLicensesHaveNotBeenAccepted;
    }
    if (RegExp(
      r'(?:sdk\.dir|ndk\.dir|ndkPath|cmake\.dir).*(?:does not exist|not a valid|invalid|does not contain)',
      caseSensitive: false,
    ).hasMatch(line)) {
      blocker = strings.theSdkNdkCmakePathInThe;
    }
    // AGP 的部分错误把包 ID/完整 NDK 版本放在下一行；只在明确失败标题
    // 后的短窗口内解析，普通 SDK 安装列表或 Flutter 版本建议不会触发补包。
    if (_ndkContext > 0) {
      _ndkContext--;
      final match = RegExp(
        r'''Preferred NDK version is ['"](\d+\.\d+\.\d+)['"]''',
      ).firstMatch(line);
      if (match != null) _record('ndk', match[1]!);
    }
    if (line.contains('NDK not configured')) _ndkContext = 3;
    if (_packageContext > 0) {
      _packageContext--;
      final match = RegExp(
        r'^\s*(platforms;android-|build-tools;|ndk;|cmake;)([0-9]+(?:\.[0-9]+)*)\s',
      ).firstMatch('$line ');
      if (match != null) {
        final id = switch (match[1]) {
          'platforms;android-' => 'platforms',
          'build-tools;' => 'build-tools',
          'ndk;' => 'ndk',
          _ => 'cmake',
        };
        _record(id, match[2]!);
      }
    }
    if (RegExp(
      r'Failed to install the following (?:Android )?SDK (?:components|packages)',
      caseSensitive: false,
    ).hasMatch(line)) {
      _packageContext = 12;
    }
    if (RegExp(
      r'Cannot run program|A problem occurred starting process|Exec format error|No such file or directory',
      caseSensitive: false,
    ).hasMatch(line)) {
      for (final id in ['build-tools', 'ndk', 'cmake']) {
        final match = RegExp(
          // Windows 的 SDK 路径是 `C:\sdk\build-tools\35.0.0\aapt2.exe`，
          // 不能只认 `/`：版本前后、中间目录、可执行后缀都允许两种分隔符。
          '[/\\\\]$id[/\\\\]'
          r'''(\d+\.\d+\.\d+)[/\\](?:[^\r\n"']*[/\\])?(?:aapt2?|aidl|zipalign|clang(?:\+\+)?|cmake|ninja)(?:\.exe|\.bat)?(?:["'\s]|$)''',
        ).firstMatch(line);
        if (match != null) _record(id, match[1]!);
      }
    }
    for (final (needle, component) in [
      (
        'Flit: AAPT2 unavailable.',
        const AndroidComponent('build-tools', ToolchainCatalog.sdkVersion),
      ),
      ('Unable to locate adb', const AndroidComponent('platform-tools')),
    ]) {
      if (line.contains(needle)) _found[component.key] = component;
    }
    final rules = <(String, RegExp)>[
      (
        'platforms',
        RegExp(
          r'''Failed to find (?:target|Platform SDK) with (?:hash string|path):?\s*["']?(?:platforms;)?android-(\d+(?:\.\d+)?)(?![\w+-]|\.\d)''',
          caseSensitive: false,
        ),
      ),
      (
        'build-tools',
        RegExp(
          r'Failed to find Build Tools revision (\d+\.\d+\.\d+)(?![\w+-]|\.\d)',
          caseSensitive: false,
        ),
      ),
      (
        'build-tools',
        RegExp(
          r'Installed Build Tools revision (\d+\.\d+\.\d+) is corrupted',
          caseSensitive: false,
        ),
      ),
      (
        'ndk',
        RegExp(
          r'NDK (\d+\.\d+\.\d+) (?:was not found|not found|is not installed|not installed)',
          caseSensitive: false,
        ),
      ),
      (
        'ndk',
        RegExp(
          r'No version of NDK matched the requested version (\d+\.\d+\.\d+)(?![\w+-]|\.\d)',
          caseSensitive: false,
        ),
      ),
      (
        'ndk',
        RegExp(
          r'NDK at .*[/\\]ndk[/\\](\d+\.\d+\.\d+) did not have a source.properties file',
          caseSensitive: false,
        ),
      ),
      (
        'ndk',
        RegExp(
          r'''NDK not configured.*version (?:is )?['"]?(\d+\.\d+\.\d+)(?![\w+-]|\.\d)''',
          caseSensitive: false,
        ),
      ),
      (
        'cmake',
        RegExp(
          r'''CMake (?:version )?['"]?(\d+\.\d+\.\d+)['"]? (?:was not found|not found|is not installed|not installed)''',
          caseSensitive: false,
        ),
      ),
    ];
    for (final (id, pattern) in rules) {
      final match = pattern.firstMatch(line);
      if (match != null) {
        _record(id, match[1]!);
      }
    }
  }
}
