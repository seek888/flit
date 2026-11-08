import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../host_platform.dart';
import '../theme.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/desktop_strings.dart';
import '../../l10n/strings.dart';

/// 桌面呈现方式开关：桌面用对话框/面板，Android 保持底部弹层。
bool get desktopPresentation => isDesktopPlatform;

/// 自适应「面板」：桌面是居中对话框，Android 是底部弹层。
///
/// 调用方只关心 title + builder，按钮与关闭由面板自己处理；[width] 是桌面
/// 目标宽度（同时受 90% 屏宽与 85% 屏高约束），[scrollable] 决定内容是否包
/// 滚动视图（短表单可关掉，避免无谓的 Scribe 滚动层）。
Future<T?> showAdaptiveSheet<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  double width = 560,
  bool scrollable = true,
}) {
  if (!desktopPresentation || _narrowAdaptive(context)) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bg,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('adaptive-sheet-close'),
                    tooltip: desktopStrings(context).close,
                    onPressed: () => Navigator.of(sheetContext).maybePop(),
                    icon: const Icon(Icons.close, size: 16),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(28, 28),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(sheetContext).height * .8,
                ),
                child: scrollable
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: Builder(builder: builder),
                      )
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: Builder(builder: builder),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  return showDialog<T>(
    context: context,
    builder: (dialogContext) => DesktopPanelDialog(
      title: title,
      width: width,
      scrollable: scrollable,
      child: Builder(builder: builder),
    ),
  );
}

/// 桌面面板对话框：标题行 + 可滚动内容，圆角 10，Esc/关闭按钮退出。
/// 窗口很窄时（桌面被缩到手机宽度）底部抽屉比居中对话框更好用，也让手机
/// 布局的既有交互与测试保持一致。
bool _narrowAdaptive(BuildContext context) {
  final size = MediaQuery.maybeSizeOf(context);
  return size != null && size.width < 600;
}

class DesktopPanelDialog extends StatelessWidget {
  const DesktopPanelDialog({
    super.key,
    required this.title,
    required this.child,
    this.width = 560,
    this.scrollable = true,
  });

  final String title;
  final Widget child;
  final double width;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final maxWidth = math.min(width, screen.width * .9);
    final maxHeight = screen.height * .85;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          insetPadding: const EdgeInsets.all(24),
          constraints: BoxConstraints(
            minWidth: math.min(360, maxWidth),
            maxWidth: maxWidth,
            maxHeight: maxHeight,
          ),
          backgroundColor: AppColors.surface,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppColors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: math.min(360, maxWidth),
              maxWidth: maxWidth,
              maxHeight: maxHeight,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: AppColors.divider),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('adaptive-sheet-close'),
                        tooltip: desktopStrings(context).close,
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.close, size: 16),
                        style: IconButton.styleFrom(
                          minimumSize: const Size(28, 28),
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: scrollable
                      ? SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: child,
                        )
                      : Padding(
                          padding: const EdgeInsets.all(16),
                          child: child,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 确认对话框：桌面按钮最小 88×32、默认焦点在「取消」、Esc 取消。
Future<bool> showConfirmDialog({
  required BuildContext context,
  required String title,
  String? message,
  String? confirmLabel,
  String? cancelLabel,
  bool destructive = false,
}) async {
  final t = desktopStrings(context);
  final cancelFocus = FocusNode();
  final future = showDialog<bool>(
    context: context,
    builder: (dialogContext) => CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(dialogContext).pop(false),
      },
      child: AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: message == null
            ? null
            : Text(
                message,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: AppColors.textSecondary,
                ),
              ),
        actions: [
          TextButton(
            focusNode: cancelFocus,
            style: _dialogButtonStyle(),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(cancelLabel ?? t.cancel),
          ),
          TextButton(
            style: _dialogButtonStyle(destructive: destructive),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel ?? t.ok),
          ),
        ],
      ),
    ),
  );
  if (desktopPresentation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (cancelFocus.context != null) cancelFocus.requestFocus();
    });
  }
  try {
    return await future ?? false;
  } finally {
    cancelFocus.dispose();
  }
}

/// 单行输入对话框：Enter 提交、Esc 取消，打开即全选。
///
/// 返回 null 表示取消；[validator] 返回非空字符串时显示错误并阻止提交。
Future<String?> showPromptDialog({
  required BuildContext context,
  required String title,
  String? initialValue,
  String? hintText,
  String? helperText,
  String? Function(String?)? validator,
  bool obscure = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => _PromptDialog(
      title: title,
      initialValue: initialValue,
      hintText: hintText,
      helperText: helperText,
      validator: validator,
      obscure: obscure,
    ),
  );
}

ButtonStyle _dialogButtonStyle({bool destructive = false}) =>
    TextButton.styleFrom(
      minimumSize: desktopPresentation ? const Size(88, 32) : null,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      visualDensity: desktopPresentation ? VisualDensity.compact : null,
      foregroundColor: destructive ? AppColors.danger : null,
    );

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    this.initialValue,
    this.hintText,
    this.helperText,
    this.validator,
    this.obscure = false,
  });

  final String title;
  final String? initialValue;
  final String? hintText;
  final String? helperText;
  final String? Function(String?)? validator;
  final bool obscure;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue ?? '',
  );
  final FocusNode _focus = FocusNode();
  String? _error;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      final text = _controller.text;
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: text.length,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    if (_closed) return;
    final value = _controller.text;
    final error = widget.validator?.call(value);
    if (error != null && error.isNotEmpty) {
      setState(() => _error = error);
      return;
    }
    _closed = true;
    Navigator.of(context).pop(value);
  }

  void _cancel() {
    if (_closed) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = desktopStrings(context);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
        const SingleActivator(LogicalKeyboardKey.enter): _submit,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _submit,
      },
      child: AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(widget.title, style: const TextStyle(fontSize: 16)),
        content: SizedBox(
          width: desktopPresentation ? 480 : null,
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            autofocus: true,
            obscureText: widget.obscure,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: widget.hintText,
              helperText: widget.helperText,
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ),
        actions: [
          TextButton(
            style: _dialogButtonStyle(),
            onPressed: _cancel,
            child: Text(t.cancel),
          ),
          TextButton(
            style: _dialogButtonStyle(),
            onPressed: _submit,
            child: Text(t.ok),
          ),
        ],
      ),
    );
  }
}

/// 供依赖方读取当前语言标识（测试/服务层无 BuildContext 时用）。
String desktopLocaleNameOf(BuildContext context) =>
    AppLocalizations.of(context)?.localeName ?? strings.localeName;