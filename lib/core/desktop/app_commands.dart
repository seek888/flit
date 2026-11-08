import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 桌面端的应用级命令。
///
/// 菜单栏、全局快捷键和页面按钮都只认这个枚举：具体动作由当前活跃页面通过
/// [AppCommands.register] 注册。没有注册的命令在菜单里自动置灰，快捷键按下
/// 也不会做事——这样「打开编辑器才有保存」不需要额外的状态判断。
enum AppCommand {
  save,
  saveAll,
  closeTab,
  closeOtherTabs,
  closeAllTabs,
  openProject,
  importProject,
  newProject,
  openSettings,
  openEnvironment,
  closeProject,
  run,
  stop,
  rebuild,
  toggleTerminal,
  toggleSidebar,
  nextTab,
  previousTab,
  zoomIn,
  zoomOut,
  resetZoom,
  refresh,
  fullscreen,
  commandPalette,
  showShortcuts,
  about,
  quit,
}

/// 一条「命令 ↔ 快捷键」绑定。
class ShortcutBinding {
  const ShortcutBinding(this.command, this.activator);

  final AppCommand command;
  final SingleActivator activator;
}

/// Windows 语义的全局快捷键表（Ctrl 而非 Cmd）。
///
/// 顺序即快捷键说明对话框里的展示顺序；分组在 UI 层决定，这里只按功能排列。
const List<ShortcutBinding> appShortcutBindings = <ShortcutBinding>[
  ShortcutBinding(
    AppCommand.save,
    SingleActivator(LogicalKeyboardKey.keyS, control: true),
  ),
  ShortcutBinding(
    AppCommand.saveAll,
    SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true),
  ),
  ShortcutBinding(
    AppCommand.closeTab,
    SingleActivator(LogicalKeyboardKey.keyW, control: true),
  ),
  // closeOtherTabs / closeAllTabs 没有默认快捷键：Ctrl+Shift+W 留给「关闭工程」。
  ShortcutBinding(
    AppCommand.openProject,
    SingleActivator(LogicalKeyboardKey.keyO, control: true),
  ),
  ShortcutBinding(
    AppCommand.importProject,
    SingleActivator(LogicalKeyboardKey.keyO, control: true, shift: true),
  ),
  ShortcutBinding(
    AppCommand.newProject,
    SingleActivator(LogicalKeyboardKey.keyN, control: true),
  ),
  ShortcutBinding(
    AppCommand.openSettings,
    SingleActivator(LogicalKeyboardKey.comma, control: true),
  ),
  ShortcutBinding(AppCommand.run, SingleActivator(LogicalKeyboardKey.f5)),
  ShortcutBinding(
    AppCommand.stop,
    SingleActivator(LogicalKeyboardKey.f5, shift: true),
  ),
  ShortcutBinding(
    AppCommand.rebuild,
    SingleActivator(LogicalKeyboardKey.keyB, control: true, shift: true),
  ),
  ShortcutBinding(
    AppCommand.toggleTerminal,
    SingleActivator(LogicalKeyboardKey.backquote, control: true),
  ),
  ShortcutBinding(
    AppCommand.toggleSidebar,
    SingleActivator(LogicalKeyboardKey.keyB, control: true),
  ),
  ShortcutBinding(
    AppCommand.nextTab,
    SingleActivator(LogicalKeyboardKey.tab, control: true),
  ),
  ShortcutBinding(
    AppCommand.previousTab,
    SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true),
  ),
  ShortcutBinding(
    AppCommand.zoomIn,
    SingleActivator(LogicalKeyboardKey.equal, control: true),
  ),
  ShortcutBinding(
    AppCommand.zoomOut,
    SingleActivator(LogicalKeyboardKey.minus, control: true),
  ),
  ShortcutBinding(
    AppCommand.resetZoom,
    SingleActivator(LogicalKeyboardKey.digit0, control: true),
  ),
  ShortcutBinding(
    AppCommand.commandPalette,
    SingleActivator(LogicalKeyboardKey.keyP, control: true, shift: true),
  ),
  ShortcutBinding(AppCommand.showShortcuts, SingleActivator(LogicalKeyboardKey.f1)),
  ShortcutBinding(AppCommand.fullscreen, SingleActivator(LogicalKeyboardKey.f11)),
  ShortcutBinding(
    AppCommand.quit,
    SingleActivator(LogicalKeyboardKey.f4, alt: true),
  ),
];

/// 命令对应的快捷键（未绑定返回 null）。
ShortcutActivator? shortcutOf(AppCommand command) {
  for (final binding in appShortcutBindings) {
    if (binding.command == command) return binding.activator;
  }
  return null;
}

/// 命令的显示串（`Ctrl+S` 这类），供菜单右侧与提示使用；未绑定返回空串。
String shortcutLabel(AppCommand command) {
  final activator = shortcutOf(command);
  if (activator is! SingleActivator) return '';
  final parts = <String>[
    if (activator.control) 'Ctrl',
    if (activator.shift) 'Shift',
    if (activator.alt) 'Alt',
    if (activator.meta) 'Win',
    _keyLabelOf(activator.trigger),
  ];
  return parts.join('+');
}

String _keyLabelOf(LogicalKeyboardKey key) {
  final label = key.keyLabel;
  if (label.isEmpty) return key.debugName ?? '';
  // 字母键的 keyLabel 是小写，Windows 菜单统一大写；符号与 F 键保持原样。
  if (label.length == 1) return label.toUpperCase();
  return label;
}

/// Shortcuts 需要的「快捷键 → Intent」映射。
Map<ShortcutActivator, Intent> appShortcutIntents() =>
    <ShortcutActivator, Intent>{
      for (final binding in appShortcutBindings)
        binding.activator: AppCommandIntent(binding.command),
    };

/// Shortcuts 需要的「快捷键 → 回调」映射（回调统一走 [AppCommands.invoke]）。
Map<ShortcutActivator, VoidCallback> appShortcutHandlers(AppCommands commands) =>
    <ShortcutActivator, VoidCallback>{
      for (final binding in appShortcutBindings)
        binding.activator: () => commands.invoke(binding.command),
    };

/// 菜单/快捷键触发的命令意图。
class AppCommandIntent extends Intent {
  const AppCommandIntent(this.command);

  final AppCommand command;
}

Future<void> Function()? _beforeCloseHandler;

/// 注册「关窗之前」的回调（桌面窗口生命周期在 window_frame 里调用）。
///
/// 编辑器用它保存全部缓冲区；回调超时或抛异常都不会阻止关窗。
void setAppBeforeCloseHandler(Future<void> Function()? handler) {
  _beforeCloseHandler = handler;
}

/// 执行关窗回调；3 秒超时，异常只打印不阻断关窗。
Future<void> runAppBeforeCloseHandler() async {
  final handler = _beforeCloseHandler;
  if (handler == null) return;
  try {
    await handler().timeout(const Duration(seconds: 3));
  } catch (error, stack) {
    debugPrint('关闭前回调失败: $error');
    debugPrintStack(stackTrace: stack);
  }
}

/// 命令注册表：页面把当前能做的事注册进来，菜单与快捷键只负责转发。
class AppCommands extends ChangeNotifier {
  final Map<AppCommand, VoidCallback> _handlers = <AppCommand, VoidCallback>{};

  /// 注册命令；重复注册以后者为准（离开页面前请 [unregister] 或 [unregisterAll]）。
  void register(AppCommand command, VoidCallback handler) {
    _handlers[command] = handler;
    notifyListeners();
  }

  /// 注销单个命令。
  void unregister(AppCommand command) {
    if (_handlers.remove(command) != null) notifyListeners();
  }

  /// 注销全部命令（页面销毁时兜底）。
  void unregisterAll() {
    if (_handlers.isEmpty) return;
    _handlers.clear();
    notifyListeners();
  }

  bool canInvoke(AppCommand command) => _handlers.containsKey(command);

  /// 命令是否注册了快捷键（菜单里用来决定是否画快捷键列）。
  bool hasShortcut(AppCommand command) => shortcutOf(command) != null;

  /// 执行命令；未注册时静默 no-op。
  void invoke(AppCommand command) {
    final handler = _handlers[command];
    if (handler == null) return;
    try {
      handler();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'flit',
          context: ErrorDescription('AppCommands.invoke(${command.name})'),
        ),
      );
    }
  }

  /// 编辑器/终端注册「关窗之前保存」回调（全局唯一，后注册者覆盖）。
  void setBeforeClose(Future<void> Function()? callback) =>
      setAppBeforeCloseHandler(callback);

  /// 供 window_frame 的关窗流程调用；也可在测试里直接验证超时行为。
  Future<void> runBeforeClose() => runAppBeforeCloseHandler();
}