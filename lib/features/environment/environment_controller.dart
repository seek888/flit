import 'package:flit/l10n/strings.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'android_build_wrapper.dart';
import 'bootstrap_installer.dart';
import 'setup_runner.dart';
import '../../services/desktop_toolchain.dart';
import '../../services/local_fs.dart';
import '../../services/shell.dart';
import '../terminal/console_session.dart';
import 'toolchain_catalog.dart';
import 'installed_toolchain.dart';

/// 安装步骤定义(展示顺序, 3 个可见阶段); OpenJDK 归入 Android 阶段作子项。
/// 各阶段实体仍是 assets/scripts/ 下的 .sh, 与组件 id 的映射见 stageScripts。
List<Map<String, String>> get stageDefs => [
  {
    'id': 'bootstrap',
    'title': strings.baseEnvironment,
    'hint': strings.bashPackageManager,
  },
  {
    'id': 'android_sdk',
    'title': strings.androidToolchain,
    'hint': strings.openjdkAndroidSdkNdkCmakeGradleConfiguration,
  },
  {
    'id': 'flutter_sdk',
    'title': strings.flutterToolchain,
    'hint': strings.flutterSdkGitAndGhWarmUp,
  },
];

/// 可见阶段 -> 子任务。子任务是管线的一等公民: 一个脚本 = 一个状态 = 一个可重试单位
/// = 卡片上一行; 脚本自带 probe(--check)/install, "算不算装好"与安装逻辑写在一处。
const stageParts = <String, List<String>>{
  'bootstrap': ['bootstrap'],
  'android_sdk': [
    'android_jdk',
    'android_sdk',
    'android_ndk',
    'android_cmake',
    'android_gradle',
  ],
  'flutter_sdk': ['flutter_tools', 'flutter_sdk', 'flutter_warmup'],
};

/// 可见阶段实际执行的脚本顺序(已 DONE 的子任务自动跳过, 重试从断点续)
const stageScripts = <String, List<String>>{
  'android_sdk': [
    'android_jdk',
    'android_sdk',
    'android_ndk',
    'android_cmake',
    'android_gradle',
  ],
  'flutter_sdk': ['flutter_tools', 'flutter_sdk', 'flutter_warmup'],
};

/// 安装就绪判据 = 全部子任务 DONE(bootstrap 由 bootstrapStatus 单独判)。
/// main.dart 的首页就绪探测从这里取 id, 不许自己再抄一份(改子任务必然漏改)。
final readyStageIds = [
  for (final parts in stageParts.values)
    for (final id in parts)
      if (id != 'bootstrap') id,
];

/// 子任务在卡片上的名字
Map<String, String> get partNames => <String, String>{
  'android_jdk': 'OpenJDK 17',
  'android_sdk': 'Android SDK',
  'android_ndk': 'NDK',
  'android_cmake': 'CMake',
  'android_gradle': strings.gradleConfiguration,
  'flutter_tools': strings.gitAndGh,
  'flutter_sdk': 'Flutter SDK',
  'flutter_warmup': strings.warmUp,
};

/// 过程性步骤不上卡片(下载解压/预热是内部动作, 不是"装了什么组件")
const hiddenParts = {'bootstrap', 'flutter_warmup'};

/// 各组件体积；du 不跟随 SDK 中的 NDK/CMake 链接，避免重复计数。
const _sizeProbeCmd = r'''
P=$(du -sk "$PREFIX" 2>/dev/null | cut -f1)
J=$(du -sk "$PREFIX/lib/jvm/java-17-openjdk" 2>/dev/null | cut -f1)
F=$(du -sk "$HOME/toolchains/flutter" 2>/dev/null | cut -f1)
U=$(du -sk "$HOME/.pub-cache" 2>/dev/null | cut -f1)
S=$(du -sk "$HOME/toolchains/android-sdk" 2>/dev/null | cut -f1)
G=$(du -sk "$HOME/.gradle" 2>/dev/null | cut -f1)
N=$(du -sk "$HOME/toolchains/ndk" 2>/dev/null | cut -f1)
M=$(du -sk "$HOME/toolchains/cmake" 2>/dev/null | cut -f1)
echo bootstrap:$(( ${P:-0} - ${J:-0} ))
echo android_jdk:${J:-0}
echo android_sdk:${S:-0}
echo android_ndk:${N:-0}
echo android_cmake:${M:-0}
echo android_gradle:${G:-0}
echo flutter_sdk:$(( ${F:-0} + ${U:-0} ))
''';

/// 在完整行上清洗 ANSI，避免 PTY 分块把颜色转义序列截断。
String stripAnsi(String s) =>
    s.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');

/// `__STAGE__<id>:<STATE>` → (id, state)。
/// 标记允许粘在其它输出之后(dl 采样的进度残片与脚本输出同行)。
(String, String)? parseStageMarker(String line) {
  final i = line.indexOf('__STAGE__');
  if (i < 0) return null;
  final body = line.substring(i + '__STAGE__'.length);
  final c = body.indexOf(':');
  if (c <= 0) return null;
  return (body.substring(0, c), body.substring(c + 1).trim());
}

/// `__VER__<id>:<文本>` → (id, 版本文本)
(String, String)? parseVersionMarker(String line) {
  final i = line.indexOf('__VER__');
  if (i < 0) return null;
  final body = line.substring(i + '__VER__'.length);
  final c = body.indexOf(':');
  if (c <= 0) return null;
  return (body.substring(0, c), body.substring(c + 1).trim());
}

/// `__NET__<目标>:<HTTP码>|<详情>` → (目标, HTTP码, 详情)
(String, String, String)? parseNetMarker(String line) {
  final i = line.indexOf('__NET__');
  if (i < 0) return null;
  final body = line.substring(i + '__NET__'.length);
  final c = body.indexOf(':');
  if (c <= 0) return null;
  final name = body.substring(0, c);
  final rest = body.substring(c + 1).trim();
  return (name, rest.split('|').first.trim(), rest);
}

/// 步骤状态(state) + 就绪后的版本号/安装体积
class StageState {
  String state = 'PENDING'; // DONE / PENDING / RUNNING / FAILED / BLOCKED
  String? version;
  String? size;
}

/// App-owned installation task; navigation never changes its process lifetime.
class EnvironmentController extends ChangeNotifier {
  EnvironmentController({
    required ProcessLauncher launcher,
    bool Function()? projectBusy,
    Future<void> Function()? onFlutterChanged,
  }) : _launcher = launcher,
       _projectBusy = projectBusy ?? (() => false),
       _onFlutterChanged = onFlutterChanged {
    AndroidBuildWrapper.installationBusy.addListener(notifyListeners);
  }

  @override
  void dispose() {
    AndroidBuildWrapper.installationBusy.removeListener(notifyListeners);
    super.dispose();
  }

  final ProcessLauncher _launcher;
  final bool Function() _projectBusy;
  final Future<void> Function()? _onFlutterChanged;

  bool _canMutate() {
    if (!_projectBusy()) return true;
    _term(strings.projectTasksAreUsingTheDevelopmentEnvironment, color: _cWarn);
    return false;
  }

  /// 当前任务的控制台: 安装=run(能停能删), 检测/探测=temp(只能删)。
  /// 没任务或被 ✕ 关掉后为 null, 面板回落到默认 bash——会话只在任务跑起来时才有。
  ConsoleSession? console;
  Future<void>? _initializing;
  bool checking = false;

  /// 版本目录的安装进行中(临时会话流式输出)
  bool installing = false;
  bool get busy =>
      pipelineRunning ||
      checking ||
      installing ||
      AndroidBuildWrapper.installing;
  List<InstalledToolchain> installed = [];
  bool installedLoaded = false;
  String? installedError;
  // 状态按子任务维护(bootstrap + 7 个脚本), 展示层按 stageParts 聚合成 3 行
  final Map<String, StageState> stages = {
    for (final parts in stageParts.values)
      for (final part in parts) part: StageState(),
  };
  bool pipelineRunning = false;
  bool allDone = false;
  bool _checkFailed = false;

  String? home;
  String? prefix;
  SetupRunner? _runner;

  final StringBuffer _lineBuf = StringBuffer();

  /// 网络通路探测结果(最近一次): 目标 -> (通, "HTTP码|耗时秒")
  final Map<String, ({bool ok, String detail})> netPaths = {};

  /// 版本目录: 下载并安装指定产物(临时会话流式输出)。
  /// ndk 安装到 ndk/`<Pkg.Revision>`(AGP 按 ndkVersion 检索); sdk 合并进
  /// 单棵树; flutter 按版本并存，通过 current 切换。
  Future<void> installFromCatalog(CatalogEntry entry) async {
    if (busy || _runner == null) {
      _term(strings.aTaskIsRunningWaitBeforeInstalling, color: _cWarn);
      return;
    }
    if (!_canMutate()) return;
    if (stages['bootstrap']!.state != 'DONE') {
      _term(strings.installTheBaseEnvironmentBeforeAddingOther, color: _cWarn);
      return;
    }
    installing = true;
    AndroidBuildWrapper.installing = true;
    notifyListeners();
    final c = _openConsole(strings.installP(entry.name), SessionKind.temp);
    try {
      _line(c, strings.fetchingDownloadInformationForP(entry.tag));
      final current = await _runner!.catalog.resolve(
        entry.component,
        tag: entry.tag,
      );
      if (c.disposed || c.stopRequested) return;
      final code = await _runInTerminal(
        c,
        buildInstallCommand(current),
        timeout: const Duration(minutes: 45),
      );
      if (code == 0) {
        _line(c, strings.pInstalled(entry.name), _cOk);
        if (entry.component == 'flutter-sdk') await _onFlutterChanged?.call();
      } else {
        _line(c, strings.installationFailedExitCodePSeeOutput(code), _cErr);
      }
      await _refreshStatus(c);
    } catch (error) {
      _line(c, strings.installationFailedP(error), _cErr);
    } finally {
      installing = false;
      AndroidBuildWrapper.installing = false;
      notifyListeners();
    }
  }

  @visibleForTesting
  static String buildInstallCommand(CatalogEntry entry) =>
      SetupRunner.installCommand(entry);

  Future<void> changeInstalled(
    InstalledToolchain tool, {
    bool delete = false,
  }) async {
    if (busy || _runner == null || !_canMutate()) return;
    installing = true;
    AndroidBuildWrapper.installing = true;
    notifyListeners();
    final c = _openConsole(
      '${delete ? strings.delete : strings.switchVersion} ${tool.title}',
      SessionKind.temp,
    );
    try {
      final command =
          'bash "\$HOME/.flit/scripts/toolchain_manager.sh" '
          '${delete ? '--delete ${shQuote(tool.path)}' : '--select ${shQuote(tool.version)}'}';
      final code = await _runInTerminal(c, command);
      if (code != 0) {
        _line(c, strings.operationFailedExitCodePSeeOutput(code), _cErr);
      }
      if (code == 0 && !delete && tool.isFlutter) {
        await _onFlutterChanged?.call();
      }
      await _refreshStatus(c);
    } finally {
      installing = false;
      AndroidBuildWrapper.installing = false;
      notifyListeners();
    }
  }

  Future<void> probeNetwork() async {
    if (busy || _runner == null) return;
    if (stages['bootstrap']!.state != 'DONE') {
      _term(strings.installTheBaseEnvironmentBeforeCheckingThe, color: _cWarn);
      return;
    }
    checking = true;
    netPaths.clear();
    notifyListeners();
    try {
      await _runInTerminal(
        _openConsole(strings.networkCheck, SessionKind.temp),
        'bash ${shQuote('${_runner!.scriptsDir}/net_probe.sh')}',
        timeout: const Duration(minutes: 2),
      );
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  Future<void> init() => _initializing ??= _init();

  /// 项目构建也可能补装组件。每次打开环境页重新读取本地状态，初始化本身
  /// 仍只执行一次；这与远程版本目录刷新无关，滚动不会触发。
  Future<void> refreshOnOpen() async {
    if (_initializing == null) {
      await init();
    } else {
      await _initializing;
      await refreshStatus();
    }
  }

  Future<void> _init() async {
    try {
      final st = await Shell.instance.bootstrapStatus();
      home = st['home'] as String?;
      prefix = st['prefix'] as String?;
      if (home != null && prefix != null) {
        final runner = SetupRunner(home: home!, prefix: prefix!);
        await runner.installScripts();
        _runner = runner;
      }
    } catch (e) {
      _term(strings.environmentCheckFailedP(e), color: _cErr);
    }
    await refreshStatus();
  }

  static const _cOk = '\x1b[1;32m'; // 成功绿
  static const _cErr = '\x1b[1;31m'; // 失败红
  static const _cWarn = '\x1b[1;33m'; // 警示黄

  /// 新任务开一个新控制台(环境页只有一个终端位, 替换上一个);
  /// 被 ✕ 关掉后自动置空, 面板回落默认 bash。
  ConsoleSession _openConsole(String title, SessionKind kind) {
    final previous = console;
    final session = ConsoleSession(
      title: title,
      kind: kind,
      launcher: _launcher,
    );
    session.textStream.listen((chunk) {
      // 已被替换的控制台可能还在排空输出，不能再覆盖新一轮检测的状态。
      if (identical(console, session)) _onPtyText(chunk);
    });
    session.addListener(() {
      if (session.disposed && identical(console, session)) {
        console = null;
        notifyListeners();
      }
    });
    console = session;
    notifyListeners();
    unawaited(previous?.close());
    return session;
  }

  /// 不隶属某个任务的消息(初始化失败/前置条件提示): 写到当前控制台,
  /// 没有就开一个「环境检测」
  void _term(String msg, {String color = ''}) => _line(
    console ?? _openConsole(strings.environmentCheck, SessionKind.temp),
    msg,
    color,
  );

  /// 任务内消息: 写到任务自己的控制台; 用户已 ✕ 关掉就不再弹新的
  void _line(ConsoleSession c, String msg, [String color = '']) {
    if (c.disposed) return;
    c.log.line(color.isEmpty ? msg : '$color$msg\x1b[0m');
    notifyListeners();
  }

  /// PTY 文本流: 行缓冲 → ANSI 清洗 → 标记解析(阶段状态/检查完成)。
  void _onPtyText(String chunk) {
    _lineBuf.write(chunk);
    final text = _lineBuf.toString();
    final lines = text.split(RegExp(r'[\r\n]'));
    _lineBuf
      ..clear()
      ..write(lines.removeLast()); // 末段可能是不完整行, 留给下一块
    for (final rawLine in lines) {
      final line = stripAnsi(rawLine).trim();
      // 网络通路标记: __NET__<目标>:<HTTP码>|<耗时秒>(000 = 不通)
      final net = parseNetMarker(line);
      if (net != null) {
        netPaths[net.$1] = (
          ok: net.$3.isNotEmpty && net.$3 != '000',
          detail: net.$3,
        );
        notifyListeners();
        continue;
      }
      final m = parseStageMarker(line);
      if (m == null) {
        // 终端已原样显示输出；这里只解析版本标记
        final v = parseVersionMarker(line);
        if (v != null && stages.containsKey(v.$1)) {
          stages[v.$1]!.version = v.$2;
          notifyListeners();
        }
        continue;
      }
      final id = m.$1;
      final state = m.$2;
      if (stages.containsKey(id)) {
        stages[id]!.state = state;
        if (state != 'DONE') stages[id]!.version = null;
        _updateAllDone();
        notifyListeners();
      }
    }
  }

  void _updateAllDone() {
    allDone = !_checkFailed && stages.values.every((s) => s.state == 'DONE');
  }

  /// 已装状态重算: 在终端内可见地跑 check.sh(幂等, 供重启后续装)。
  Future<void> refreshStatus() async {
    if (busy) return;
    checking = true;
    notifyListeners();
    try {
      await _refreshStatus();
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  Future<void> _refreshStatus([ConsoleSession? existing]) async {
    _checkFailed = true; // 完整检测成功前，不能被提前到达的 DONE 标记解锁。
    _updateAllDone();
    final bootstrapped =
        (await Shell.instance.bootstrapStatus())['bootstrapped'] == true;
    stages['bootstrap']!.state = bootstrapped ? 'DONE' : 'PENDING';
    for (final id in stages.keys.where((k) => k != 'bootstrap')) {
      stages[id]!.state = 'PENDING';
      stages[id]!.version = null;
    }
    if (isDesktopPlatform && bootstrapped) {
      await _desktopCheck();
      await _loadSizes();
      await _loadInstalled();
      _updateAllDone();
      notifyListeners();
      return;
    }
    if (bootstrapped && _runner != null) {
      final c =
          existing ?? _openConsole(strings.environmentCheck, SessionKind.temp);
      final code = await _runInTerminal(
        c,
        'bash ${shQuote('${_runner!.scriptsDir}/check.sh')}',
        timeout: const Duration(minutes: 2),
      );
      _checkFailed = code != 0;
      if (code != 0) {
        _line(c, strings.environmentCheckIncompleteExitCodeP(code), _cErr);
      }
      await _loadSizes();
      await _loadInstalled();
    } else {
      installed = [];
      installedLoaded = !bootstrapped;
      installedError = bootstrapped
          ? strings.componentsAreNotReadyCheckAgain
          : null;
    }
    _updateAllDone();
    notifyListeners();
  }

  Future<void> _loadInstalled() async {
    if (isDesktopPlatform) {
      // 桌面端暂不管理多版本：单份工具链，版本页留空但不报错。
      installed = const [];
      installedLoaded = true;
      installedError = null;
      return;
    }
    try {
      final result = await Shell.instance.exec(
        'bash "\$HOME/.flit/scripts/toolchain_manager.sh" --list',
        timeoutMs: 60000,
      );
      if (result['exitCode'] != 0) {
        throw StateError(strings.componentDirectoryCheckFailed);
      }
      installed =
          (result['output'] as String? ?? '')
              .split('\n')
              .map(InstalledToolchain.parse)
              .whereType<InstalledToolchain>()
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      installedLoaded = true;
      installedError = null;
    } catch (error) {
      // 检测失败不能冒充“未安装”，保留最近一次成功结果并禁止基于旧状态操作。
      installedError = strings.unableToReadInstalledComponentsCheckAgain(error);
    }
  }

  Future<int> _runInTerminal(
    ConsoleSession c,
    String command, {
    Duration timeout = const Duration(minutes: 45),
  }) async {
    if (c.disposed) return -1;
    _lineBuf.clear();
    final code = await c.run(command, timeout: timeout);
    if (_lineBuf.isNotEmpty) _onPtyText('\n');
    return code;
  }

  /// 桌面端无需 build 的具体组件：Gradle 由 Wrapper 下载、NDK/CMake 按需、
  /// git/gh 走系统 git。直接判为 DONE，避免卡住「环境就绪」。
  static const _desktopNotRequired = <String>[
    'android_ndk',
    'android_cmake',
    'android_gradle',
    'flutter_tools',
    'flutter_warmup',
  ];

  /// 桌面端环境检测：把私有工具链的真实状态翻译成 __STAGE__ 标记。
  Future<void> _desktopCheck() async {
    final st = await DesktopToolchain().status();
    final marks = <String>[
      '__STAGE__android_jdk:${st.jdk ? 'DONE' : 'MISSING'}',
      '__STAGE__android_sdk:${st.androidSdk && st.aapt2 && st.platform ? 'DONE' : 'MISSING'}',
      '__STAGE__flutter_sdk:${st.flutter ? 'DONE' : 'MISSING'}',
      for (final id in _desktopNotRequired) '__STAGE__$id:DONE',
    ];
    _onPtyText('${marks.join('\n')}\n');
    _checkFailed = !(st.jdk && st.androidSdk && st.flutter);
  }

  /// 桌面端按阶段安装：直接调 DesktopToolchain，输出进同一个控制台。
  Future<void> _runStageDesktop(ConsoleSession c, String id) async {
    final tc = DesktopToolchain();
    c.beginTask();
    try {
      _line(c, strings.preparingP(partNames[id] ?? id));
      final st0 = await tc.status();
      if (id == 'android_jdk' && st0.jdk) {
        _line(c, 'JDK 已就绪', _cOk);
        stages[id]!.state = 'DONE';
        notifyListeners();
      } else if (id == 'android_sdk' &&
          st0.androidSdk &&
          st0.aapt2 &&
          st0.platform) {
        _line(c, 'Android SDK 已就绪', _cOk);
        stages[id]!.state = 'DONE';
        notifyListeners();
      } else if (id == 'flutter_sdk' && st0.flutter) {
        _line(c, 'Flutter 已就绪', _cOk);
        stages[id]!.state = 'DONE';
        notifyListeners();
      } else if (_desktopNotRequired.contains(id)) {
        _line(c, '桌面端无需安装，跳过', _cOk);
        stages[id]!.state = 'DONE';
        notifyListeners();
      } else {
        final Stream<String> stream;
        switch (id) {
          case 'android_jdk':
            stream = tc.install(flutter: false, androidSdk: false);
          case 'android_sdk':
            stream = tc.install(flutter: false);
          case 'flutter_sdk':
            stream = tc.install(androidSdk: false);
          default:
            stream = const Stream<String>.empty();
        }
        await for (final line in stream) {
          if (c.disposed || c.stopRequested) break;
          _line(c, line);
        }
        final st = await tc.status();
        final ok = switch (id) {
          'android_jdk' => st.jdk,
          'android_sdk' => st.androidSdk && st.aapt2 && st.platform,
          'flutter_sdk' => st.flutter,
          _ => true,
        };
        if (ok) {
          stages[id]!.state = 'DONE';
          _line(c, strings.pInstalled(partNames[id] ?? id), _cOk);
        } else {
          stages[id]!.state = 'FAILED';
          _line(c, '安装未完成，请看上面的输出', _cErr);
        }
        notifyListeners();
      }
    } catch (e) {
      stages[id]!.state = 'FAILED';
      _line(c, '安装失败: $e', _cErr);
    } finally {
      if (!c.disposed) {
        c.endTask(code: stages[id]!.state == 'DONE' ? 0 : 1);
      }
    }
  }

  /// 就绪组件的安装体积 + 展开子项(du), 失败静默——纯展示信息。
  Future<void> _loadSizes() async {
    if (isDesktopPlatform) {
      try {
        final tc = DesktopToolchain();
        final fs = LocalFs.instance;
        void setSize(String id, int bytes) {
          if (!stages.containsKey(id) || bytes <= 0) return;
          stages[id]!.size = _humanSize(bytes ~/ 1024);
        }

        setSize('android_jdk', fs.dirSize(tc.jdkDir));
        setSize('android_sdk', fs.dirSize(tc.sdkDir));
        setSize(
          'flutter_sdk',
          fs.dirSize(tc.flutterDir) + fs.dirSize(tc.pubCache),
        );
        setSize('android_gradle', fs.dirSize(tc.gradleHome));
        notifyListeners();
      } catch (_) {}
      return;
    }
    try {
      final res = await Shell.instance.exec(_sizeProbeCmd, timeoutMs: 60000);
      for (final line in (res['output'] as String? ?? '').split('\n')) {
        final i = line.indexOf(':');
        if (i <= 0) continue;
        final id = line.substring(0, i);
        final kb = int.tryParse(line.substring(i + 1).trim());
        if (stages.containsKey(id) && kb != null && kb > 0) {
          stages[id]!.size = _humanSize(kb);
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  static String _humanSize(int kb) {
    if (kb >= 1024 * 1024) return '${(kb / 1024 / 1024).toStringAsFixed(1)} GB';
    if (kb >= 1024) return '${(kb / 1024).toStringAsFixed(0)} MB';
    return '$kb KB';
  }

  // ---------- 流水线 ----------

  /// 一键安装: bootstrap(Dart 下载/解压, 进度进终端) → 其余阶段脚本
  /// 顺序在真终端里执行(失败即停, 后续 BLOCKED)。
  /// 停止旗标只有会话这一份(终端头部的停止按钮直接 stop 会话), 每步做完看一眼。
  Future<void> startPipeline() async {
    if (busy || _runner == null || !_canMutate()) return;
    pipelineRunning = true;
    AndroidBuildWrapper.installing = true;
    // 整个安装共用一个 run 控制台: 能停(⏹, 输出留着,「继续安装」重跑)能删(✕)
    final c = _openConsole(strings.environmentSetup, SessionKind.run);
    try {
      // 界面状态只是上次快照。继续安装前复查，已被删除/损坏的阶段不能直接跳过。
      await _refreshStatus(c);
      if (_stopped(c)) return;
      // ① bootstrap: 下载自建产物(校验) → 原生全量解压(bash/软链/权限)
      if (stages['bootstrap']!.state != 'DONE') {
        stages['bootstrap']!.state = 'RUNNING';
        notifyListeners();
        // 这一步在 Dart 侧原生完成、没有 PTY 进程; 登记为会话任务, 终端头部
        // 才有"运行中"和停止按钮。下载打不断, 停止 = 本步结束后不再继续
        c.beginTask();
        try {
          final spec = await _runner!.bootstrapSpec();
          if (c.disposed || c.stopRequested) {
            stages['bootstrap']!.state = 'PENDING';
            return;
          }
          await BootstrapInstaller.install(
            url: spec.url,
            sha256: spec.sha256,
            workDir: File(prefix!).parent.path, // files/(勿放 $PREFIX, 解压会先清空它)
            log: (message) => _line(c, message, '\x1b[36m'),
            progress: (message) => _progress(c, message),
          );
          // 装完就是装完: 用户停止只决定"不再继续下一阶段", 不丢弃成果
          stages['bootstrap']!.state = 'DONE';
          notifyListeners();
          if (_stopped(c)) return;
        } catch (e) {
          _line(c, strings.baseEnvironmentInstallationFailedP(e), _cErr);
          stages['bootstrap']!.state = 'FAILED';
          _blockAfter('bootstrap');
          return;
        } finally {
          if (!c.disposed) {
            c.endTask(code: stages['bootstrap']!.state == 'DONE' ? 0 : 1);
          }
        }
      }

      // ②~③ 可见阶段在真终端里顺序执行; 阶段内逐组件跑, 已完成自动跳过
      for (final s in stageDefs.skip(1)) {
        final id = s['id'] as String;
        final title = s['title'] as String;
        for (final part in stageScripts[id]!) {
          if (stages[part]!.state == 'DONE') continue;
          stages[part]!.state = 'RUNNING';
          notifyListeners();
          await _runStageInTerminal(c, part);
          if (_stopped(c)) return;
          if (stages[part]!.state != 'DONE') {
            _line(
              c,
              strings.pInstallationFailedRemainingStepsSkipped(title),
              _cErr,
            );
            _blockAfter(part);
            return;
          }
        }
        _line(c, strings.pComplete(title), _cOk);
      }

      await _refreshStatus(c);
      if (_stopped(c)) return;
      _line(
        c,
        allDone
            ? strings.installationCompleteDevelopmentEnvironmentReady
            : strings.environmentVerificationFailedCheckMissingOrFailed,
        allDone ? _cOk : _cErr,
      );
    } finally {
      await _loadSizes();
      await _loadInstalled();
      pipelineRunning = false;
      AndroidBuildWrapper.installing = false;
      for (final stage in stages.values) {
        if (stage.state == 'RUNNING') {
          stage.state = c.stopRequested ? 'PENDING' : 'FAILED';
        }
      }
      _updateAllDone();
      notifyListeners();
    }
  }

  /// 用户停止: 不判失败、已完成的阶段保留, 点「继续安装」从断点续装
  bool _stopped(ConsoleSession c) {
    if (!c.stopRequested && !c.disposed) return false;
    _line(c, strings.stoppedYouCanResumeInstallationLater, _cWarn);
    return true;
  }

  /// 进度: \r 原地刷新单行(wget 风格), 不产生满屏行
  void _progress(ConsoleSession c, String msg) {
    if (c.disposed) return;
    c.log.progress(msg);
    notifyListeners();
  }

  Future<void> _runStageInTerminal(ConsoleSession c, String id) async {
    if (isDesktopPlatform) return _runStageDesktop(c, id);
    String command;
    c.beginTask();
    try {
      _line(c, strings.preparingP(partNames[id] ?? id));
      command = await _runner!.stageCommand(id);
      command += ' && bash ${shQuote('${_runner!.scriptsDir}/$id.sh')} --check';
    } catch (error) {
      _line(c, strings.failedToFetchInstallationInformationP(error), _cErr);
      stages[id]!.state = 'FAILED';
      return;
    } finally {
      if (!c.disposed) c.endTask(code: stages[id]!.state == 'FAILED' ? 1 : 0);
    }
    if (c.disposed || c.stopRequested) {
      stages[id]!.state = 'PENDING';
      return;
    }
    final code = await _runInTerminal(c, command);
    if (c.stopRequested) {
      stages[id]!.state = 'PENDING';
    } else if (code == 0 && stages[id]!.state == 'DONE') {
      // 安装和紧随其后的只读检测都通过，才能推进流水线。
      stages[id]!.state = 'DONE';
    } else {
      stages[id]!.state = 'FAILED';
    }
    _updateAllDone();
    notifyListeners();
  }

  void _blockAfter(String id) {
    var blocked = false;
    for (final part in stageParts.values.expand((parts) => parts)) {
      if (part == id) {
        blocked = true;
        continue;
      }
      if (blocked && stages[part]!.state != 'DONE') {
        stages[part]!.state = 'BLOCKED';
      }
    }
    notifyListeners();
  }
}
