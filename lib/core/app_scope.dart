import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/environment/environment_controller.dart';
import '../features/environment/toolchain_catalog.dart';
import '../features/git/github_account.dart';
import '../features/settings/appearance_preferences.dart';
import '../features/terminal/console_session.dart';
import '../features/terminal/pty_session.dart';
import '../features/workspace/project_session.dart';
import '../services/auto_proxy.dart';
import 'desktop/app_commands.dart';

/// Everything that lives as long as the app. main() builds the production set
/// once; tests build their own (with fakes where needed) and mount the same
/// [AppScope], so widgets never reach for a static to find app state.
class AppServices {
  AppServices({
    required this.launcher,
    required this.proxy,
    required this.preferences,
    required this.environment,
    required this.github,
    required this.catalog,
    required this.workbenchShell,
    required this.workspace,
    required this.routeObserver,
    required this.commands,
  });

  /// 所有控制台的进程来源; 生产是 PtyLauncher, 测试是假进程
  final ProcessLauncher launcher;
  final AutoProxy proxy;
  final AppearancePreferences preferences;
  final EnvironmentController environment;
  final GithubAccount github;
  final ToolchainCatalog catalog;

  /// 工作台默认 bash; 每个工程另有一个带自己 cwd/历史的 shell
  final PtySession workbenchShell;
  final ProjectWorkspace workspace;

  /// Only the visible page may resize the shared terminal / PTY.
  final RouteObserver<PageRoute<dynamic>> routeObserver;

  /// 桌面菜单栏/全局快捷键共用的命令注册表；Android 也会创建（页面可注册，
  /// 只是没有菜单消费）。
  final AppCommands commands;
}

/// Exposes [AppServices] to the widget tree. Sits above MaterialApp so routes
/// and dialogs can read it too. Nothing here is disposed: these objects live
/// exactly as long as the process.
class AppScope extends StatelessWidget {
  const AppScope({super.key, required this.services, required this.child});

  final AppServices services;
  final Widget child;

  @override
  Widget build(BuildContext context) => MultiProvider(
    providers: [
      Provider<ProcessLauncher>.value(value: services.launcher),
      ChangeNotifierProvider<AutoProxy>.value(value: services.proxy),
      ChangeNotifierProvider<AppearancePreferences>.value(
        value: services.preferences,
      ),
      ChangeNotifierProvider<EnvironmentController>.value(
        value: services.environment,
      ),
      ChangeNotifierProvider<GithubAccount>.value(value: services.github),
      Provider<ToolchainCatalog>.value(value: services.catalog),
      ChangeNotifierProvider<PtySession>.value(value: services.workbenchShell),
      ChangeNotifierProvider<ProjectWorkspace>.value(value: services.workspace),
      ChangeNotifierProvider<AppCommands>.value(value: services.commands),
      Provider<RouteObserver<PageRoute<dynamic>>>.value(
        value: services.routeObserver,
      ),
    ],
    child: child,
  );
}