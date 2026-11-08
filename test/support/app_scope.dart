import 'package:flit/core/app_scope.dart';
import 'package:flit/core/desktop/app_commands.dart';
import 'package:flit/features/environment/environment_controller.dart';
import 'package:flit/features/environment/toolchain_catalog.dart';
import 'package:flit/features/git/github_account.dart';
import 'package:flit/features/settings/appearance_preferences.dart';
import 'package:flit/features/terminal/console_session.dart';
import 'package:flit/features/terminal/pty_launcher.dart';
import 'package:flit/features/terminal/pty_session.dart';
import 'package:flit/features/workspace/project_session.dart';
import 'package:flit/services/auto_proxy.dart';
import 'package:flutter/material.dart';

/// 测试用的应用级对象集: 与生产同一个 [AppServices]/[AppScope], 只是对象可以
/// 由测试自建替换。默认启动器就是生产的 PtyLauncher——在通道桩下它找不到
/// bash 而抛"开发环境未就绪", 与过去默认启动器的行为完全一致; 要观察进程
/// 交互的测试传自己的假启动器。
AppServices testServices({
  ProcessLauncher? launcher,
  AutoProxy? proxy,
  AppearancePreferences? preferences,
  EnvironmentController? environment,
  GithubAccount? github,
  ToolchainCatalog? catalog,
  PtySession? workbenchShell,
  ProjectWorkspace? workspace,
  AppCommands? commands,
}) {
  final proxies = proxy ?? AutoProxy();
  final launch = launcher ?? PtyLauncher(proxy: proxies).call;
  return AppServices(
    launcher: launch,
    proxy: proxies,
    preferences: preferences ?? AppearancePreferences(),
    environment: environment ?? EnvironmentController(launcher: launch),
    github: github ?? GithubAccount(launcher: launch),
    catalog: catalog ?? ToolchainCatalog(),
    workbenchShell: workbenchShell ?? PtySession(launcher: launch),
    workspace: workspace ?? ProjectWorkspace(launcher: launch),
    routeObserver: RouteObserver<PageRoute<dynamic>>(),
    commands: commands ?? AppCommands(),
  );
}

/// 把页面挂进应用作用域 + MaterialApp(带路由观察者, 终端宿主需要它)。
Widget testApp({required Widget home, AppServices? services}) {
  final s = services ?? testServices();
  return AppScope(
    services: s,
    child: MaterialApp(home: home, navigatorObservers: [s.routeObserver]),
  );
}
