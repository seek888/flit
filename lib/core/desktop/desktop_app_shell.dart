import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/desktop_strings.dart';
import '../host_platform.dart';
import '../theme.dart';
import 'app_commands.dart';
import 'desktop_presentation.dart';
import 'window_frame.dart';

/// 应用版本（与 pubspec 的 `version: 1.0.0-preview.2` 对齐）。
///
/// 这里用编译期常量，避免为了一个字符串引入 package_info_plus。
const String flitAppVersion = '1.0.0-preview.2';

/// 桌面外壳：顶部菜单栏 + 全局快捷键/命令动作；Android 原样返回 [child]。
///
/// 该组件放在 `MaterialApp.builder` 里，位于所有路由之上，所以菜单栏在打开
/// 工程/设置等页面时始终可见，快捷键也不会被页面覆盖。
class DesktopAppShell extends StatefulWidget {
  const DesktopAppShell({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopAppShell> createState() => _DesktopAppShellState();
}

class _DesktopAppShellState extends State<DesktopAppShell> {
  /// 菜单栏位于 Navigator 之上，而 Material 的弹出菜单需要 Overlay 祖先：
  /// 给整个外壳套一层根 Overlay，菜单面板就会叠在页面内容之上。
  late final OverlayEntry _rootEntry = OverlayEntry(builder: _buildShell);

  @override
  Widget build(BuildContext context) {
    if (!isDesktopPlatform) return widget.child;
    return Overlay(initialEntries: <OverlayEntry>[_rootEntry]);
  }

  Widget _buildShell(BuildContext context) {
    final commands = appCommandsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppMenuBar(),
        Expanded(
          child: Shortcuts(
            shortcuts: appShortcutIntents(),
            child: Actions(
              actions: <Type, Action<Intent>>{
                AppCommandIntent: CallbackAction<AppCommandIntent>(
                  onInvoke: (intent) {
                    commands.invoke(intent.command);
                    return null;
                  },
                ),
              },
              child: widget.child,
            ),
          ),
        ),
      ],
    );
  }
}

/// 取当前 AppCommands；没有 AppScope（例如组件单测直接挂 MaterialApp）时
/// 回落到一个空的全局实例，菜单全部置灰而不是崩溃。
AppCommands appCommandsOf(BuildContext context) {
  try {
    return context.read<AppCommands>();
  } catch (_) {
    return _fallbackCommands;
  }
}

final AppCommands _fallbackCommands = AppCommands();

/// 桌面菜单栏：高 30、surface 底、1px 底边，菜单项右侧显示快捷键。
class AppMenuBar extends StatefulWidget {
  const AppMenuBar({super.key});

  @override
  State<AppMenuBar> createState() => _AppMenuBarState();
}

class _AppMenuBarState extends State<AppMenuBar> {
  /// 菜单打开前编辑器持有的焦点上下文。菜单一打开焦点就转移到菜单项上，
  /// 此时再用 primaryFocus 找 TextIntent 的 Action 就找不到目标了。
  BuildContext? _textFocusContext;

  void _captureTextFocus() {
    _textFocusContext = FocusManager.instance.primaryFocus?.context;
  }

  void _invokeTextIntent(Intent intent) {
    final target = _textFocusContext;
    if (target == null) return;
    try {
      Actions.maybeInvoke(target, intent);
    } catch (error) {
      debugPrint('编辑命令无法执行: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = desktopStrings(context);
    final commands = appCommandsOf(context);
    return Material(
      color: AppColors.surface,
      child: Container(
        height: 30,
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.divider)),
        ),
        child: ListenableBuilder(
          listenable: commands,
          builder: (context, _) => MenuBar(
            style: const MenuStyle(
              backgroundColor: WidgetStatePropertyAll(Colors.transparent),
              elevation: WidgetStatePropertyAll(0),
              padding: WidgetStatePropertyAll(EdgeInsets.zero),
              minimumSize: WidgetStatePropertyAll(Size(0, 30)),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(borderRadius: BorderRadius.zero),
              ),
            ),
            children: [
              _submenu(
                t.file,
                _fileMenu(t, commands),
              ),
              _submenu(
                t.edit,
                _editMenu(t),
                onOpen: _captureTextFocus,
              ),
              _submenu(t.view, _viewMenu(t, commands)),
              _submenu(t.run, _runMenu(t, commands)),
              _submenu(t.help, _helpMenu(t, commands)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _submenu(
    String label,
    List<Widget> children, {
    VoidCallback? onOpen,
  }) => SubmenuButton(
    onOpen: onOpen,
    style: SubmenuButton.styleFrom(
      minimumSize: const Size(0, 30),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      textStyle: const TextStyle(fontSize: 13),
    ),
    menuStyle: const MenuStyle(
      backgroundColor: WidgetStatePropertyAll(AppColors.surface),
      elevation: WidgetStatePropertyAll(8),
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(6)),
          side: BorderSide(color: AppColors.border),
        ),
      ),
    ),
    menuChildren: children,
    child: Text(label),
  );

  Widget _commandItem(
    AppCommands commands,
    AppCommand command,
    String label,
  ) => _AppMenuItem(
    label: label,
    shortcut: shortcutLabel(command),
    onPressed: commands.canInvoke(command)
        ? () => commands.invoke(command)
        : null,
  );

  List<Widget> _fileMenu(DesktopStrings t, AppCommands commands) => <Widget>[
    _commandItem(commands, AppCommand.newProject, t.newProject),
    _commandItem(commands, AppCommand.openProject, t.openProject),
    _commandItem(commands, AppCommand.importProject, t.importProject),
    const _AppMenuDivider(),
    _commandItem(commands, AppCommand.save, t.save),
    _commandItem(commands, AppCommand.saveAll, t.saveAll),
    const _AppMenuDivider(),
    _commandItem(commands, AppCommand.closeTab, t.closeTab),
    _commandItem(commands, AppCommand.closeOtherTabs, t.closeOtherTabs),
    _commandItem(commands, AppCommand.closeAllTabs, t.closeAllTabs),
    const _AppMenuDivider(),
    _commandItem(commands, AppCommand.closeProject, t.closeProject),
    const _AppMenuDivider(),
    _commandItem(commands, AppCommand.quit, t.quit),
  ];

  List<Widget> _editMenu(DesktopStrings t) => <Widget>[
    _textItem(t.undo, UndoTextIntent(SelectionChangedCause.keyboard), 'Ctrl+Z'),
    _textItem(t.redo, RedoTextIntent(SelectionChangedCause.keyboard), 'Ctrl+Y'),
    const _AppMenuDivider(),
    _textItem(
      t.cut,
      CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
      'Ctrl+X',
    ),
    _textItem(t.copy, CopySelectionTextIntent.copy, 'Ctrl+C'),
    _textItem(t.paste, PasteTextIntent(SelectionChangedCause.keyboard), 'Ctrl+V'),
    const _AppMenuDivider(),
    _textItem(
      t.selectAll,
      SelectAllTextIntent(SelectionChangedCause.keyboard),
      'Ctrl+A',
    ),
  ];

  Widget _textItem(
    String label,
    Intent intent,
    String shortcut,
  ) => _AppMenuItem(
    label: label,
    shortcut: shortcut,
    onPressed: () => _invokeTextIntent(intent),
  );

  List<Widget> _viewMenu(DesktopStrings t, AppCommands commands) => <Widget>[
    _commandItem(commands, AppCommand.toggleSidebar, t.fileTree),
    _commandItem(commands, AppCommand.toggleTerminal, t.terminal),
    const _AppMenuDivider(),
    _commandItem(commands, AppCommand.zoomIn, t.zoomIn),
    _commandItem(commands, AppCommand.zoomOut, t.zoomOut),
    _commandItem(commands, AppCommand.resetZoom, t.actualSize),
    const _AppMenuDivider(),
    _commandItem(commands, AppCommand.refresh, t.refresh),
    _commandItem(commands, AppCommand.fullscreen, t.fullScreen),
    const _AppMenuDivider(),
    _commandItem(commands, AppCommand.commandPalette, t.commandPalette),
    _commandItem(commands, AppCommand.openSettings, t.settings),
  ];

  List<Widget> _runMenu(DesktopStrings t, AppCommands commands) => <Widget>[
    _commandItem(commands, AppCommand.run, t.runProject),
    _commandItem(commands, AppCommand.stop, t.stop),
    _commandItem(commands, AppCommand.rebuild, t.rebuild),
  ];

  List<Widget> _helpMenu(DesktopStrings t, AppCommands commands) => <Widget>[
    _commandItem(commands, AppCommand.showShortcuts, t.shortcuts),
    const _AppMenuDivider(),
    _commandItem(commands, AppCommand.about, t.about),
  ];
}

/// 统一菜单项外观：固定内容宽度，左侧名称、右侧快捷键，高 28。
class _AppMenuItem extends StatelessWidget {
  const _AppMenuItem({
    required this.label,
    this.shortcut,
    this.onPressed,
  });

  final String label;
  final String? shortcut;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => MenuItemButton(
    onPressed: onPressed,
    style: MenuItemButton.styleFrom(
      minimumSize: const Size(0, 28),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      textStyle: const TextStyle(fontSize: 13),
    ),
    child: SizedBox(
      width: 216,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (shortcut != null && shortcut!.isNotEmpty) ...[
            const SizedBox(width: 24),
            Text(
              shortcut!,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class _AppMenuDivider extends StatelessWidget {
  const _AppMenuDivider();

  @override
  Widget build(BuildContext context) => const Divider(
    height: 7,
    thickness: 1,
    color: AppColors.divider,
    indent: 6,
    endIndent: 6,
  );
}

/// 快捷键说明对话框：按分组列出全部快捷键。
Future<void> showDesktopShortcutsDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (dialogContext) => DesktopPanelDialog(
    title: desktopStrings(dialogContext).shortcutsTitle,
    width: 640,
    child: const _ShortcutHelp(),
  ),
);

class _ShortcutHelp extends StatelessWidget {
  const _ShortcutHelp();

  static const List<(String Function(DesktopStrings), List<AppCommand>)> _groups =
      <(String Function(DesktopStrings), List<AppCommand>)>[
        (_groupFile, <AppCommand>[
          AppCommand.save,
          AppCommand.saveAll,
          AppCommand.closeTab,
          AppCommand.closeOtherTabs,
          AppCommand.closeAllTabs,
          AppCommand.openProject,
          AppCommand.importProject,
          AppCommand.newProject,
          AppCommand.closeProject,
          AppCommand.quit,
        ]),
        (_groupView, <AppCommand>[
          AppCommand.toggleSidebar,
          AppCommand.toggleTerminal,
          AppCommand.zoomIn,
          AppCommand.zoomOut,
          AppCommand.resetZoom,
          AppCommand.refresh,
          AppCommand.fullscreen,
          AppCommand.commandPalette,
          AppCommand.openSettings,
        ]),
        (_groupRun, <AppCommand>[
          AppCommand.run,
          AppCommand.stop,
          AppCommand.rebuild,
        ]),
        (_groupOther, <AppCommand>[
          AppCommand.nextTab,
          AppCommand.previousTab,
          AppCommand.showShortcuts,
        ]),
      ];

  static String _groupFile(DesktopStrings t) => t.shortcutsFileGroup;
  static String _groupView(DesktopStrings t) => t.shortcutsViewGroup;
  static String _groupRun(DesktopStrings t) => t.shortcutsRunGroup;
  static String _groupOther(DesktopStrings t) => t.shortcutsHelpGroup;

  static const List<(String, String)> _editRows = <(String, String)>[
    ('撤销 / Undo', 'Ctrl+Z'),
    ('重做 / Redo', 'Ctrl+Y'),
    ('剪切 / Cut', 'Ctrl+X'),
    ('复制 / Copy', 'Ctrl+C'),
    ('粘贴 / Paste', 'Ctrl+V'),
    ('全选 / Select All', 'Ctrl+A'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = desktopStrings(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (titleOf, commands) in _groups) ...[
          _GroupTitle(titleOf(t)),
          for (final command in commands)
            _ShortcutRow(
              label: commandLabel(t, command),
              keys: shortcutLabel(command),
            ),
        ],
        _GroupTitle(t.shortcutsEditGroup),
        for (final (label, keys) in _editRows) _ShortcutRow(label: label, keys: keys),
      ],
    );
  }
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 4),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: AppColors.textSecondary,
      ),
    ),
  );
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.label, required this.keys});

  final String label;
  final String keys;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 13),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.bg,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: AppColors.border),
          ),
          child: Text(
            keys,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    ),
  );
}

/// 关于对话框：Flit + Windows 桌面版说明 + 版本号。
Future<void> showDesktopAboutDialog(BuildContext context) {
  final t = desktopStrings(context);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text('${t.aboutFlit} ${t.versionLabel} $flitAppVersion'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.windowsEdition,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            t.aboutDescription,
            style: const TextStyle(
              fontSize: 13,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(t.close),
        ),
      ],
    ),
  );
}

/// 命令在菜单/快捷键说明里的本地化名称。
String commandLabel(DesktopStrings t, AppCommand command) => switch (command) {
  AppCommand.save => t.save,
  AppCommand.saveAll => t.saveAll,
  AppCommand.closeTab => t.closeTab,
  AppCommand.closeOtherTabs => t.closeOtherTabs,
  AppCommand.closeAllTabs => t.closeAllTabs,
  AppCommand.openProject => t.openProject,
  AppCommand.importProject => t.importProject,
  AppCommand.newProject => t.newProject,
  AppCommand.openSettings => t.settings,
  AppCommand.openEnvironment => t.environment,
  AppCommand.closeProject => t.closeProject,
  AppCommand.run => t.runProject,
  AppCommand.stop => t.stop,
  AppCommand.rebuild => t.rebuild,
  AppCommand.toggleTerminal => t.terminal,
  AppCommand.toggleSidebar => t.fileTree,
  AppCommand.nextTab => t.nextTab,
  AppCommand.previousTab => t.previousTab,
  AppCommand.zoomIn => t.zoomIn,
  AppCommand.zoomOut => t.zoomOut,
  AppCommand.resetZoom => t.actualSize,
  AppCommand.refresh => t.refresh,
  AppCommand.fullscreen => t.fullScreen,
  AppCommand.commandPalette => t.commandPalette,
  AppCommand.showShortcuts => t.shortcuts,
  AppCommand.about => t.about,
  AppCommand.quit => t.quit,
};

/// 应用退出：桌面走 windowManager.close 触发几何保存；Android 交还系统。
Future<void> requestDesktopQuit() => closeDesktopApp();

/// 应用根 Navigator 的 key：MaterialApp 挂上它之后，菜单/快捷键这类
/// 「没有页面 context」的入口也能弹对话框。
final GlobalKey<NavigatorState> desktopNavigatorKey =
    GlobalKey<NavigatorState>();

/// 供 main 注册的默认命令：退出与关于/快捷键说明在所有页面都可用。
void registerDesktopShellCommands(AppCommands commands) {
  commands.register(AppCommand.quit, () {
    requestDesktopQuit();
  });
  commands.register(AppCommand.showShortcuts, () {
    final context = _shellDialogContext();
    if (context != null) showDesktopShortcutsDialog(context);
  });
  commands.register(AppCommand.about, () {
    final context = _shellDialogContext();
    if (context != null) showDesktopAboutDialog(context);
  });
}

BuildContext? _shellDialogContext() =>
    desktopNavigatorKey.currentContext ??
    FocusManager.instance.primaryFocus?.context;