import 'package:flit/l10n/strings.dart';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../../services/shell.dart' show shQuote;
import '../../services/github_mirror.dart';
import 'toolchain_catalog.dart';

/// 脚本驱动的一键初始化编排。
/// bootstrap 由原生全量解压(MainActivity.deployBootstrap); 其后各阶段脚本
/// 由环境页写入环境专用终端执行, 输出实时可见、可 Ctrl+C。
class SetupRunner {
  SetupRunner({
    required this.home,
    required this.prefix,
    ToolchainCatalog? catalog,
  }) : catalog = catalog ?? ToolchainCatalog();

  final ToolchainCatalog catalog;

  final String home;
  final String prefix;

  /// 与 flutter.ndkVersion 对齐(AGP 按目录名匹配); 同见 lib.sh 默认值
  static const ndkVersion = ToolchainCatalog.ndkVersion;

  /// AGP 对 externalNativeBuild 的默认请求版本(flutter_pty 等原生插件依赖);
  /// 与默认 CMake release 一致
  static const cmakeVersion = ToolchainCatalog.cmakeVersion;

  static const _scriptNames = [
    'lib.sh',
    'component_checks.sh',
    'toolchain_manager.sh',
    'check.sh',
    'android_jdk.sh',
    'android_sdk.sh',
    'android_ndk.sh',
    'android_cmake.sh',
    'android_gradle.sh',
    'android_build.sh',
    'android_components.sh',
    'android_platform.sh',
    'flutter_sdk.sh',
    'flutter_tools.sh',
    'flutter_warmup.sh',
    'net_probe.sh',
  ];

  String get scriptsDir => '$home/.flit/scripts';
  String get tmpDir => '$prefix/tmp';

  /// 阶段脚本 + env.sh 写入 $HOME/.flit(每次覆盖, 随 app 更新)。
  Future<void> installScripts() async {
    final dir = Directory(scriptsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // 原子替换单个文件，避免首页检测与正在运行的脚本相遇时截断脚本内容。
    final staging = dir.createTempSync('.deploy-');
    try {
      for (final name in _scriptNames) {
        final text = await rootBundle.loadString('assets/scripts/$name');
        File('${staging.path}/$name').writeAsStringSync(text);
      }
      File('${staging.path}/env.sh').writeAsStringSync(await _renderEnvSh());
      for (final name in _scriptNames) {
        File('${staging.path}/$name').renameSync('$scriptsDir/$name');
      }
      // env.sh 在 .flit/ 根目录；脚本通过 lib.sh 加载它。
      File('${staging.path}/env.sh').renameSync('$home/.flit/env.sh');
    } finally {
      staging.deleteSync(recursive: true);
    }
  }

  // Offline environment generation: only installation resolves release assets.
  Future<String> _renderEnvSh() async {
    return '''
# 由 Flit 生成的运行环境；下载资产仅在安装时通过 GitHub API 解析
export FLIT_TOOLCHAINS="\$HOME/toolchains"
export ANDROID_HOME="\$HOME/toolchains/android-sdk"
export JAVA_HOME="\$PREFIX/lib/jvm/java-17-openjdk"
# termux 版 JDK 把 java.io.tmpdir 烧死成 com.termux 前缀, 必须覆盖
export JDK_JAVA_OPTIONS="-Djava.io.tmpdir=\$PREFIX/tmp"
# libjvm.so 依赖同包 lib/ 下的 libandroid-shmem.so, dlopen 按 LD_LIBRARY_PATH 搜索
# 保持工具优先级；重复加载时去掉旧条目，避免 PATH/动态库路径越积越长。
_flit_prepend() {
  local name=\$1 entry=\$2 part rest=\${!1} result=\$2
  while [ -n "\$rest" ]; do
    part=\${rest%%:*}
    case "\$rest" in *:*) rest=\${rest#*:} ;; *) rest= ;; esac
    [ -z "\$part" ] || [ "\$part" = "\$entry" ] || result="\$result:\$part"
  done
  export "\$name=\$result"
}
export LD_LIBRARY_PATH="\${LD_LIBRARY_PATH:-}"
_flit_prepend LD_LIBRARY_PATH "\$JAVA_HOME/lib"
export GRADLE_USER_HOME="\$HOME/.gradle"
# 手机的 adbd 使用 5555；禁止 ADB 把它自动扫描成 emulator-5554。
# 显式 adb connect 不受影响。
export ADB_EMU=0
# PATH 必须在 JAVA_HOME 之后(flutter 需要它); platform-tools 提供 SDK 内 adb
_flit_prepend PATH "\$ANDROID_HOME/platform-tools"
_flit_prepend PATH "\$JAVA_HOME/bin"
export FLUTTER_ROOT="\$HOME/toolchains/flutter/current"
_flit_prepend PATH "\$FLUTTER_ROOT/bin"
unset -f _flit_prepend
export TMPDIR="\$PREFIX/tmp"
# flutter/dart 首次需要联网拉取工件与依赖, 走国内镜像(官方源直连不可达)
export PUB_HOSTED_URL="https://pub.flutter-io.cn"
export FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
# termux-exec: #!/usr/bin/env 类解释器重写到本前缀(官方 Termux 同款)
for __f in "\$PREFIX/lib/libtermux-exec-ld-preload.so" "\$PREFIX/lib/libtermux-exec.so"; do
  [ -f "\$__f" ] && export LD_PRELOAD="\$__f" && break
done
unset __f
export NDK_VERSION="$ndkVersion"
export CMAKE_VERSION="$cmakeVersion"
export SDK_VERSION="${ToolchainCatalog.sdkVersion}"
export SDK_PLATFORM_VERSION="${ToolchainCatalog.platformVersion}"
export FLUTTER_VERSION="${ToolchainCatalog.flutterVersion}"
export FLIT_APT_SOURCE=${shQuote('${GithubMirror.wrap('https://github.com/${ToolchainCatalog.packagesRepo}/releases/download/pool')} ./')}
# GitHub 镜像前缀(空 = 直连); 供脚本与网络检测使用, 与 Dart 侧 GithubMirror 一致
export FLIT_GH_PROXY=${shQuote(GithubMirror.prefix)}
''';
  }

  Future<({String url, String sha256})> bootstrapSpec() async {
    final entry = await catalog.resolve('bootstrap');
    return (url: entry.url, sha256: entry.sha256!);
  }

  Future<String> stageCommand(String stage) async {
    final component = const {
      'android_sdk': 'android-sdk',
      'android_ndk': 'ndk',
      'android_cmake': 'cmake',
      'flutter_sdk': 'flutter-sdk',
    }[stage];
    if (component == null) return 'bash ${shQuote('$scriptsDir/$stage.sh')}';
    return installCommand(await catalog.resolve(component), initialize: true);
  }

  static String installCommand(CatalogEntry entry, {bool initialize = false}) {
    if (ToolchainCatalog.parseSha256('sha256:${entry.sha256}') == null) {
      throw StateError(strings.thisAssetHasNoShaDigest);
    }
    final sdkPart = const {
      'android-sdk',
      'build-tools',
      'platforms',
      'platform-tools',
      'cmdline-tools',
    }.contains(entry.component);
    final script = sdkPart
        ? 'android_sdk.sh'
        : switch (entry.component) {
            'ndk' => 'android_ndk.sh',
            'cmake' => 'android_cmake.sh',
            'flutter-sdk' => 'flutter_sdk.sh',
            _ => throw StateError(
              strings.unsupportedComponentP(entry.component),
            ),
          };
    final version = entry.tag.replaceFirst(
      RegExp(r'^(sdk|platform|flutter|cmake)-'),
      '',
    );
    final arguments = [
      entry.url,
      entry.sha256!,
      if (sdkPart) ...[
        entry.component,
        version,
      ] else if (entry.component == 'cmake' || entry.component == 'flutter-sdk')
        version,
    ];
    final refreshGradle =
        !initialize &&
        (entry.component == 'android-sdk' || entry.component == 'build-tools');
    return 'bash "\$HOME/.flit/scripts/$script" ${initialize ? '--install' : '--release'} '
        '${arguments.map(shQuote).join(' ')}'
        '${refreshGradle ? ' && bash "\$HOME/.flit/scripts/android_gradle.sh"' : ''}';
  }
}
