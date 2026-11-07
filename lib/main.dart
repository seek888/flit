import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/app_scope.dart';
import 'features/environment/environment_controller.dart';
import 'features/environment/toolchain_catalog.dart';
import 'features/git/github_account.dart';
import 'features/settings/appearance_preferences.dart';
import 'features/terminal/pty_launcher.dart';
import 'features/terminal/pty_session.dart';
import 'features/workspace/project_session.dart';
import 'services/auto_proxy.dart';
import 'services/shell.dart';
import 'l10n/strings.dart';
import 'l10n/app_localizations.dart';

/// 组合根: 应用级对象只在这里创建一次, 其余代码通过 AppScope 取用。
/// 代理先于启动器: PTY 环境在进程启动那一刻注入代理, 启动器必须拿到它。
Future<AppServices> composeApp() async {
  final proxy = AutoProxy();
  // 读开关+探测系统代理, Dart 侧 HttpClient 全局接管(终端走环境变量)
  await proxy.load();
  proxy.applyToDart();
  final launcher = PtyLauncher(proxy: proxy).call;
  final preferences = AppearancePreferences();
  await preferences.load();
  strings = lookupAppLocalizations(
    resolveAppLocale(
      preferences.language,
      WidgetsBinding.instance.platformDispatcher.locales,
    ),
  );
  final workspace = ProjectWorkspace(launcher: launcher);
  return AppServices(
    launcher: launcher,
    proxy: proxy,
    preferences: preferences,
    environment: EnvironmentController(
      launcher: launcher,
      projectBusy: () {
        final project = workspace.active;
        return project != null &&
            (project.executions.active != null ||
                project.executions.starting ||
                project.actions.starting.value != null ||
                project.git.busy);
      },
      onFlutterChanged: () async {
        final project = workspace.active;
        if (project == null || project.closed) return;
        await project.language.stop();
        if (!project.closed) await project.language.ensureStarted(project.path);
      },
    ),
    github: GithubAccount(launcher: launcher),
    catalog: ToolchainCatalog(),
    workbenchShell: PtySession(launcher: launcher),
    workspace: workspace,
    routeObserver: RouteObserver<PageRoute<dynamic>>(),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await composeApp();
  // 沉浸式: 状态栏/导航栏透明融入页面(深色应用配浅色图标)。
  // 桌面端没有系统状态栏/导航栏，这两个调用在 Windows/macOS/Linux 上是无意义的
  // 平台通道调用，跳过以免产生噪声日志。
  if (!isDesktopPlatform) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  }
  runApp(AppScope(services: services, child: const FlitApp()));
}
