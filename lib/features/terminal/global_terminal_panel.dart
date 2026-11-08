import 'package:flit/l10n/strings.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import '../../core/desktop/desktop_presentation.dart';
import '../../core/desktop/desktop_zoom.dart';
import '../../core/theme.dart';
import '../../core/workbench_controls.dart';

import 'pty_session.dart';
import 'console_session.dart';
import 'terminal_theme.dart';
import '../../core/pinch_zoom.dart';
import 'terminal_settings.dart';
import '../settings/appearance_preferences.dart';

/// Terminal chrome and input surface. Parent supplies bounded space; selection
/// actions occupy the existing header and never cover selection handles.
class GlobalTerminalPanel extends StatefulWidget {
  const GlobalTerminalPanel({
    super.key,
    required this.expanded,
    required this.onToggle,
    this.running = false,
    this.height = 280,
    this.minHeight = 180,
    this.onFullscreen,
    this.fullscreen = false,
    this.onResize,
    this.focusNode,
    this.session,
    this.sessionsBar,
    this.consumeSafeArea = true,
  });

  final bool expanded;
  final VoidCallback onToggle;
  final bool running;
  final double height;
  final double minHeight;
  final VoidCallback? onFullscreen;
  final bool fullscreen;
  final ValueChanged<double>? onResize;
  final FocusNode? focusNode;
  final ConsoleSession? session;
  final Widget? sessionsBar; // 会话切换/控制条(面板头部下方一行)
  final bool consumeSafeArea;

  @override
  State<GlobalTerminalPanel> createState() => _GlobalTerminalPanelState();
}

class _GlobalTerminalPanelState extends State<GlobalTerminalPanel> {
  final _viewKey = GlobalKey<TerminalViewState>();
  PtySession? _workbench;
  double? _zoomSize;
  double _zoomStartSize = 13;
  int _zoomGeneration = 0;

  double get _fontSize =>
      _zoomSize ?? context.read<AppearancePreferences?>()?.terminalSize ?? 13;

  void _zoomStart() {
    _zoomGeneration++;
    _zoomStartSize = _fontSize;
    _session.controller.clearSelection();
  }

  void _zoom(double scale) {
    final size = (_zoomStartSize * scale).clamp(
      AppearancePreferences.terminalMinSize,
      AppearancePreferences.terminalMaxSize,
    );
    if (size.isFinite) setState(() => _zoomSize = size);
  }

  Future<void> _saveZoom() async {
    if (_zoomSize == null) return;
    final generation = _zoomGeneration;
    final size = (_zoomSize! * 2).round() / 2;
    try {
      // 只在手势结束时写一次偏好，拖动期间不触发磁盘写入。
      await context.read<AppearancePreferences>().update(terminal: size);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.strings.fontSizeAppliedButSavingFailedP(error),
            ),
          ),
        );
      }
    } finally {
      if (mounted && generation == _zoomGeneration) {
        setState(() => _zoomSize = null);
      }
    }
  }

  /// Ctrl+滚轮：按 0.5px 步进改字号并立即落盘（与双指缩放共用同一份偏好）。
  Future<void> _wheelZoom(double delta) async {
    final preferences = context.read<AppearancePreferences?>();
    if (preferences == null) return;
    final next = (preferences.terminalSize + delta * 0.5).clamp(
      AppearancePreferences.terminalMinSize,
      AppearancePreferences.terminalMaxSize,
    );
    if (next == preferences.terminalSize) return;
    await preferences.update(terminal: next);
  }

  void _appearance() {
    FocusManager.instance.primaryFocus?.unfocus();
    // 桌面端：居中的外观对话框；手机端仍是底部抽屉（由 showAdaptiveSheet 分流）。
    showAdaptiveSheet<void>(
      context: context,
      title: context.strings.terminalAppearance,
      width: 420,
      builder: (_) => const TerminalAppearanceSettings(),
    );
  }

  /// 没指定会话时回落到工作台默认 bash(应用级, 来自 AppScope)
  ConsoleSession get _session =>
      widget.session ?? (_workbench ??= context.read<PtySession>());

  @override
  void initState() {
    super.initState();
    _ensureShell();
  }

  void _ensureShell() {
    final session = _session;
    if (session is PtySession) session.ensure();
  }

  @override
  void didUpdateWidget(covariant GlobalTerminalPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session ||
        (widget.expanded && !oldWidget.expanded)) {
      _ensureShell();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // 会话换了自动改订阅; 重建由它负责, 这里不再手工 addListener
    listenable: _session,
    builder: (context, _) =>
        _session.disposed ? const SizedBox.shrink() : _panel(),
  );

  Widget _panel() {
    context.watch<AppearancePreferences?>();
    return Material(
      color: AppColors.surface,
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        bottom: widget.consumeSafeArea,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final bounded = constraints.maxHeight.isFinite;
            return Column(
              mainAxisSize: bounded ? MainAxisSize.max : MainAxisSize.min,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: widget.onResize == null
                      ? null
                      : (details) => widget.onResize!(details.delta.dy),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (bounded && constraints.maxHeight < 44)
                        SizedBox(
                          height: constraints.maxHeight,
                          child: ClipRect(
                            child: OverflowBox(
                              minHeight: 44,
                              maxHeight: 44,
                              child: _header(),
                            ),
                          ),
                        )
                      else
                        SizedBox(
                          height: 44,
                          child: AnimatedBuilder(
                            animation: _session.controller,
                            builder: (_, __) =>
                                !widget.expanded ||
                                    _session.controller.selection == null
                                ? _header()
                                : ExcludeFocus(
                                    child: _SelectionToolbar(session: _session),
                                  ),
                          ),
                        ),
                      if (widget.expanded &&
                          widget.sessionsBar != null &&
                          (!bounded || constraints.maxHeight > 140))
                        widget.sessionsBar!,
                    ],
                  ),
                ),
                if (widget.expanded) ...[
                  if (bounded)
                    Expanded(child: _surface())
                  else
                    SizedBox(height: widget.height, child: _surface()),
                  // 按键条(ESC/CTRL/方向键)只对可输入的默认 shell 有意义
                  if (_session.interactive &&
                      (!bounded || constraints.maxHeight > 140))
                    _ExtraKeysBar(session: _session),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header() {
    Widget button(IconData icon, String tooltip, VoidCallback action) =>
        IconButton(
          tooltip: tooltip,
          onPressed: action,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          padding: EdgeInsets.zero,
          icon: Icon(icon, size: 18, color: AppColors.textSecondary),
        );
    return ExcludeFocus(
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            if (widget.consumeSafeArea)
              button(
                widget.expanded ? Icons.expand_more : Icons.expand_less,
                widget.expanded
                    ? context.strings.collapseTerminal
                    : context.strings.expandTerminal,
                widget.onToggle,
              )
            else
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Icon(
                  Icons.drag_handle,
                  size: 18,
                  color: AppColors.textFaint,
                ),
              ),
            Icon(
              Icons.circle,
              size: 8,
              color: widget.running
                  ? AppColors.accent
                  : _session.alive
                  ? AppColors.success
                  : AppColors.warn,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${terminalDisplayTitle(_session.title)} · ${_session.alive
                    ? context.strings.running
                    : _session.exitCode == null
                    ? context.strings.ready
                    : context.strings.exited}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            if (widget.expanded) ...[
              // 默认 shell 永远在; run 能停(⏹, 输出留着)能删; 临时只能删。
              // ✕ 在跑则终止再移除, 之后面板回落默认 shell
              if (_session.stoppable)
                button(
                  Icons.stop_circle_outlined,
                  _session.stopRequested
                      ? context.strings.stopping
                      : context.strings.stopCurrentTask,
                  _session.stopRequested ? () {} : () => _session.stop(),
                ),
              if (_session.kind != SessionKind.shell)
                button(
                  Icons.close,
                  _session.alive
                      ? context.strings.terminateAndClose
                      : context.strings.close,
                  () => _session.close(),
                ),
              if (context.read<AppearancePreferences?>() != null)
                button(
                  Icons.text_fields,
                  context.strings.terminalFontAndZoom,
                  _appearance,
                ),
              button(
                Icons.delete_sweep_outlined,
                context.strings.clearTerminal,
                _session.clearScreen,
              ),
            ],
            if (widget.onFullscreen != null)
              button(
                widget.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                widget.fullscreen
                    ? context.strings.exitFullScreen
                    : context.strings.fullScreenTerminal,
                widget.onFullscreen!,
              ),
          ],
        ),
      ),
    );
  }

  Widget _surface() {
    return Stack(
      children: [
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final preferences = context.watch<AppearancePreferences?>();
              final style = flitTerminalStyle.copyWith(
                fontSize: _fontSize,
                fontFamily: preferences?.terminalFont,
                height: preferences?.terminalLineHeight,
              );
              final view = TerminalView(
                _session.terminal,
                key: _viewKey,
                controller: _session.controller,
                focusNode: widget.focusNode,
                scrollController: _session.scrollController,
                textStyle: style,
                theme: flitTerminalTheme,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                deleteDetection: true,
                // run/temp 只读: 输出面板, 输入由按钮程序性写入(热重载 r/R)
                readOnly: !_session.interactive,
                // Keep the input client alive even in a very short landscape
                // viewport, without sending a zero-row size to the PTY.
                autoResize:
                    constraints.maxHeight >
                    MediaQuery.textScalerOf(context).scale(style.fontSize) *
                        style.height *
                        2,
              );
              if (preferences == null) return view;
              return CtrlWheelZoom(
                // 桌面快捷路径：Ctrl+滚轮直接改字号并落盘；双指路径保留给手机。
                onZoom: (delta) => unawaited(_wheelZoom(delta)),
                child: PinchZoom(
                  // 终端按行排版, 焦点锚定交给终端视图的滚动; 这里只取比例。
                  onStart: (_) => _zoomStart(),
                  onScale: (scale, _) => _zoom(scale),
                  onEnd: () => unawaited(_saveZoom()),
                  child: view,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 终端按键条: ESC / CTRL(锁存) / TAB / 方向键。软键盘没有的终端必需键。
class _ExtraKeysBar extends StatefulWidget {
  const _ExtraKeysBar({required this.session});
  final ConsoleSession session;

  @override
  State<_ExtraKeysBar> createState() => _ExtraKeysBarState();
}

class _ExtraKeysBarState extends State<_ExtraKeysBar> {
  void _send(String s) {
    widget.session.input(s);
  }

  void _toggleCtrl() {
    widget.session.toggleCtrl();
  }

  @override
  Widget build(BuildContext context) {
    Widget key(
      String label,
      VoidCallback action, {
      bool active = false,
      bool wide = false,
    }) => SizedBox(
      width: wide
          ? 74
          : label.length > 2
          ? 58
          : 44,
      child: WorkbenchKey(label: label, onPressed: action, active: active),
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            key('ESC', () => _send('\x1b')),
            key('CTRL', _toggleCtrl, active: widget.session.ctrlArmed),
            key('TAB', () => _send('\t')),
            key('↑', () => _send('\x1b[A')),
            key('↓', () => _send('\x1b[B')),
            key('←', () => _send('\x1b[D')),
            key('→', () => _send('\x1b[C')),
            key('-', () => _send('-')),
            key('|', () => _send('|')),
            key('~', () => _send('~')),
            key('/', () => _send('/')),
            // IME 的回车会被 xterm 按 action 吞掉(newline action 不映射 Enter),
            // 按键条直接发 \r, 保证任何输入法下都能执行命令
            key('ENTER', () => _send('\r'), wide: true),
            // 长按选择后用工具条复制; 粘贴独立常驻(多数时候无选区也要粘贴)
            key(
              context.strings.paste,
              () => widget.session.pasteClipboard(),
              wide: true,
            ),
          ],
        ),
      ),
    );
  }
}

/// 选中后浮现的操作条: 复制 / 全选 / 粘贴 / 取消选择。
/// 长按选词、按住拖动扩展选区；操作条不抢占终端焦点。
class _SelectionToolbar extends StatelessWidget {
  const _SelectionToolbar({required this.session});
  final ConsoleSession session;

  @override
  Widget build(BuildContext context) {
    Widget action(String label, IconData icon, VoidCallback onTap) {
      return Expanded(
        child: InkWell(
          canRequestFocus: false,
          onTap: onTap,
          child: Container(
            height: 38,
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: AppColors.accent),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    Widget divider() => const SizedBox(
      width: 1,
      height: 22,
      child: ColoredBox(color: AppColors.border),
    );

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: BorderSide(color: AppColors.border),
          bottom: BorderSide(color: AppColors.border),
        ),
      ),
      child: Row(
        children: [
          action(context.strings.copy, Icons.copy_outlined, () {
            final text = session.copySelection();
            if (text == null || text.isEmpty) return;
            Clipboard.setData(ClipboardData(text: text));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(context.strings.copied),
                duration: Duration(seconds: 1),
              ),
            );
          }),
          divider(),
          action(context.strings.selectAll, Icons.select_all, () {
            session.selectAll();
          }),
          // 只读会话不接受输入: 粘贴只对默认 shell 有意义
          if (session.interactive) ...[
            divider(),
            action(context.strings.paste, Icons.paste, () {
              session.pasteClipboard();
            }),
          ],
          divider(),
          action(context.strings.cancel, Icons.close, () {
            session.controller.clearSelection();
          }),
        ],
      ),
    );
  }
}
