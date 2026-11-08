import 'package:flit/l10n/strings.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/desktop/desktop_zoom.dart';
import '../../../core/host_platform.dart';
import '../../../core/theme.dart';
import '../../../core/pinch_zoom.dart';
import '../../settings/appearance_preferences.dart';
import '../completion/completion_engine.dart';
import '../controller/code_controller.dart';
import '../controller/editor_intelligence.dart';
import '../lsp/lsp_client.dart';
import '../lsp/protocol.dart' show SignatureHelp;
import 'code_field.dart';
import 'completion_popup.dart';

/// Owns editing UI only; documents and the language server belong to the project.
class EditorSurface extends StatefulWidget {
  const EditorSurface({
    super.key,
    required this.controller,
    required this.path,
    required this.focusNode,
  });
  final CodeController controller;
  final String path;
  final FocusNode focusNode;

  @override
  State<EditorSurface> createState() => _EditorSurfaceState();
}

class _EditorSurfaceState extends State<EditorSurface> {
  /// 语言服务属于工程(ProjectScope), 页面生命周期内不换对象
  late final LspClient _language = context.read<LspClient>();
  late final EditorIntelligence _intelligence;
  final _codeFieldKey = GlobalKey<CodeFieldState>();
  // 缩放锚定需要读取/跳转滚动偏移, 控制器由本组件持有并注入 CodeField。
  final _codeScroll = ScrollController();
  final _codeHScroll = ScrollController();
  Rect? _caretRect;
  double? _zoomSize;
  double _zoomStartSize = 14;
  int _zoomGeneration = 0;
  bool _focused = false;

  /// Ctrl+滚轮: 每次 ±1px, 直接写回偏好, 编辑器字号/行高/补全弹窗一起跟随。
  void _wheelZoom(double delta) {
    final preferences = context.read<AppearancePreferences>();
    final next = stepZoom(
      _zoomSize ?? preferences.editorSize,
      delta,
      min: AppearancePreferences.editorMinSize,
      max: AppearancePreferences.editorMaxSize,
    );
    if (next == null) return;
    _dismissSuggestions();
    setState(() => _zoomSize = null);
    unawaited(preferences.update(editor: next));
  }

  void _zoomStart(Offset focal) {
    _zoomGeneration++;
    _zoomStartSize =
        _zoomSize ?? context.read<AppearancePreferences>().editorSize;
    _dismissSuggestions();
  }

  void _zoom(double scale, Offset focal) {
    final size = (_zoomStartSize * scale).clamp(
      AppearancePreferences.editorMinSize,
      AppearancePreferences.editorMaxSize,
    );
    if (!size.isFinite) return;
    setState(() => _zoomSize = size);
    // 焦点锚定: 重排布局后跳回滚动偏移, 两指中心下的内容保持不动。
    _codeFieldKey.currentState?.zoomAnchor(
      from: _zoomStartSize,
      to: size,
      focal: focal,
    );
  }

  Future<void> _saveZoom() async {
    if (_zoomSize == null) return;
    final generation = _zoomGeneration;
    final size = (_zoomSize! * 2).round() / 2;
    try {
      await context.read<AppearancePreferences>().update(editor: size);
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

  CodeController get _codeCtrl => widget.controller;
  FocusNode get _editorFocus => widget.focusNode;

  @override
  void initState() {
    super.initState();
    _intelligence = EditorIntelligence(
      path: widget.path,
      code: _codeCtrl,
      language: _language,
    );
    _editorFocus.addListener(_onFocusChanged);
    _onFocusChanged();
  }

  @override
  void dispose() {
    _editorFocus.removeListener(_onFocusChanged);
    _intelligence.dispose();
    _codeScroll.dispose();
    _codeHScroll.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    final focused = _editorFocus.hasFocus;
    _intelligence.setFocused(focused);
    if (focused != _focused && mounted) setState(() => _focused = focused);
  }

  void _dismissSuggestions() => _intelligence.dismiss();

  Future<void> _applyCompletion(CompletionItem item) async {
    try {
      if (await _intelligence.apply(item) && mounted) {
        _editorFocus.requestFocus();
      }
    } on FormatException {
      if (!mounted) return;
      _intelligence.dismiss();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.strings.completionItemExpiredTypeAgain)),
      );
    }
  }

  /// 桌面式补全浮层的定位: 锚定光标, 优先显示在光标上方, 放不下落到下方。
  /// [fontSize] 跟随编辑器字号, 行高与宽度同步放大, 缩放后候选面板不脱节。
  Positioned? _buildCompletionPopup(
    BuildContext context,
    BoxConstraints constraints,
    double fontSize,
  ) {
    final caret = _caretRect;
    if (caret == null || _intelligence.suggestions.isEmpty) return null;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return null;
    final rowHeight = CompletionPopup.rowHeightFor(fontSize);
    final width = math.max(300.0, fontSize * 23.0);
    final h = _intelligence.suggestions.length.clamp(1, 5) * rowHeight;
    final topLeft = box.globalToLocal(caret.topLeft);
    final left = (topLeft.dx - 12).clamp(
      8.0,
      (constraints.maxWidth - width - 8).clamp(8.0, double.infinity),
    );
    final caretBottom = box.globalToLocal(caret.bottomLeft).dy;
    var top = topLeft.dy - h - 6;
    if (top < 4) top = caretBottom + 6;
    top = top.clamp(
      4.0,
      (constraints.maxHeight - h - 4).clamp(4.0, double.infinity),
    );
    return Positioned(
      left: left,
      top: top,
      child: CompletionPopup(
        items: _intelligence.suggestions,
        selectedIndex: _intelligence.selected,
        onSelected: _applyCompletion,
        onDismiss: _dismissSuggestions,
        fontSize: fontSize,
        width: width,
      ),
    );
  }

  KeyEventResult _onEditorKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_intelligence.canSuggest || _intelligence.suggestions.isEmpty) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _dismissSuggestions();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      _applyCompletion(_intelligence.suggestions[_intelligence.selected]);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final delta = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1;
      _intelligence.moveSelection(delta);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _signatureView(SignatureHelp signature) {
    final start = signature.parameterStart;
    final end = signature.parameterEnd;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 40),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: AppColors.surface,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text.rich(
          TextSpan(
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
            children: start == null || end == null
                ? [TextSpan(text: signature.label)]
                : [
                    TextSpan(text: signature.label.substring(0, start)),
                    TextSpan(
                      text: signature.label.substring(start, end),
                      style: const TextStyle(
                        color: AppColors.accent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    TextSpan(text: signature.label.substring(end)),
                  ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preferences = context.watch<AppearancePreferences>();
    // 补全弹窗跟随编辑器字号, 但夹在可读区间, 避免 48px 时候选面板占满半屏。
    final popupFontSize = preferences.editorSize.clamp(12.0, 18.0);
    final focusBorder = _focused && isDesktopPlatform
        ? Border.all(color: AppColors.accent, width: 1)
        : null;
    return ListenableBuilder(
      listenable: _intelligence,
      builder: (context, _) => Focus(
        onKeyEvent: _onEditorKey,
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            children: [
              Expanded(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(border: focusBorder),
                        child: PinchZoom(
                          onStart: _zoomStart,
                          onScale: _zoom,
                          onEnd: () => unawaited(_saveZoom()),
                          child: CtrlWheelZoom(
                            onZoom: _wheelZoom,
                            child: CodeField(
                              key: _codeFieldKey,
                              controller: _codeCtrl,
                              focusNode: _editorFocus,
                              language: _language,
                              filePath: widget.path,
                              scrollController: _codeScroll,
                              horizontalScrollController: _codeHScroll,
                              onCaretChanged: (rect) {
                                if (mounted && rect != _caretRect) {
                                  setState(() => _caretRect = rect);
                                }
                              },
                              fontSize: _zoomSize ?? preferences.editorSize,
                              wrap: preferences.editorWrap,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_buildCompletionPopup(
                          context,
                          constraints,
                          popupFontSize,
                        )
                        case final popup?)
                      popup,
                  ],
                ),
              ),
              if (_intelligence.signature != null &&
                  constraints.maxHeight > 180)
                _signatureView(_intelligence.signature!),
            ],
          ),
        ),
      ),
    );
  }
}
