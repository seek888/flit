import 'package:flit/l10n/strings.dart';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../../../core/desktop/desktop_presentation.dart';
import 'package:flutter/services.dart';
import '../../../core/theme.dart';
import '../controller/code_controller.dart';
import '../lsp/lsp_client.dart';
import '../lsp/protocol.dart';

/// Native text editing, with line numbers taken from the actual wrapped layout.
class CodeField extends StatefulWidget {
  const CodeField({
    super.key,
    required this.controller,
    this.scrollController,
    this.horizontalScrollController,
    this.focusNode,
    this.onChanged,
    this.onSelectionChanged,
    this.onCaretChanged,
    this.fontSize = 13,
    this.filePath,
    this.language,
    this.wrap = true,
  });

  /// 换行策略: true = 软换行(默认); false = 长行横向滚动(每逻辑行单行)
  final bool wrap;

  /// true = keyboardType.none: 输入连接保持(外接键盘可用)但软键盘不弹,
  /// 配合应用内代码虚拟键盘
  final CodeController controller;
  final ScrollController? scrollController;
  final ScrollController? horizontalScrollController;
  final FocusNode? focusNode;
  final VoidCallback? onChanged, onSelectionChanged;

  /// 光标的全局屏幕坐标变化(输入/移动/滚动/字号变化都会触发; null = 无法定位)
  final ValueChanged<Rect?>? onCaretChanged;
  final double fontSize;

  /// 当前文件绝对路径(非 null 且是 .dart 时, 诊断详情里提供 LSP 快速修复)
  final String? filePath;
  final LspClient? language;
  @override
  CodeFieldState createState() => CodeFieldState();
}

class CodeFieldState extends State<CodeField> {
  late ScrollController _scroll;
  late ScrollController _hScroll;
  late TextEditingValue _lastValue;
  final _fieldKey = GlobalKey();
  final _gutterKey = GlobalKey();
  List<int> _starts = [0];
  int _maxCols = 0;
  double? _charW;

  /// 等宽字符宽(用于横向滚动模式的内容宽度估算)
  double _charWidth(TextStyle style) {
    return _charW ??= (TextPainter(
      text: TextSpan(text: '0', style: style),
      textDirection: TextDirection.ltr,
    )..layout()).width;
  }

  @override
  void initState() {
    super.initState();
    _scroll = widget.scrollController ?? ScrollController();
    _hScroll = widget.horizontalScrollController ?? ScrollController();
    _scroll.addListener(_reportCaret);
    _bind();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportCaret());
  }

  void _bind() {
    _lastValue = widget.controller.value;
    _updateLines();
    widget.controller.addListener(_onValue);
  }

  void _updateLines() {
    _starts = [0];
    _maxCols = 0;
    final text = widget.controller.text;
    var cols = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 10) {
        if (cols > _maxCols) _maxCols = cols;
        _starts.add(i + 1);
        cols = 0;
      } else {
        cols++;
      }
    }
    if (cols > _maxCols) _maxCols = cols;
  }

  @override
  void didUpdateWidget(CodeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onValue);
      _bind();
    }
    if (oldWidget.scrollController != widget.scrollController) {
      _scroll.removeListener(_reportCaret);
      if (oldWidget.scrollController == null) _scroll.dispose();
      _scroll = widget.scrollController ?? ScrollController();
      _scroll.addListener(_reportCaret);
    }
    if (oldWidget.horizontalScrollController !=
        widget.horizontalScrollController) {
      if (oldWidget.horizontalScrollController == null) {
        _hScroll.dispose();
      }
      _hScroll = widget.horizontalScrollController ?? ScrollController();
    }
    if (oldWidget.fontSize != widget.fontSize ||
        oldWidget.wrap != widget.wrap) {
      _charW = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _reportCaret());
    }
  }

  void _onValue() {
    final next = widget.controller.value;
    final changed = next.text != _lastValue.text;
    final moved =
        next.selection != _lastValue.selection ||
        next.composing != _lastValue.composing;
    _lastValue = next;
    if (changed) _updateLines();
    if (changed || moved) setState(() {});
    _reportCaret();
    if (changed) {
      widget.onChanged?.call();
    } else if (moved) {
      widget.onSelectionChanged?.call();
    }
  }

  /// 光标的全局矩形(用 RenderEditable 精确定位, 已含内部滚动偏移)
  void _reportCaret() {
    final cb = widget.onCaretChanged;
    if (cb == null) return;
    final editor = _editable();
    final box = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    if (editor == null || box == null || !box.attached || !editor.hasSize) {
      return;
    }
    final sel = widget.controller.selection;
    if (!sel.isValid) return cb(null);
    final offset = sel.baseOffset.clamp(0, widget.controller.text.length);
    try {
      final rect = editor.getLocalRectForCaret(TextPosition(offset: offset));
      if (!rect.isFinite) return cb(null);
      cb(rect.shift(editor.localToGlobal(Offset.zero)));
    } catch (_) {}
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onValue);
    if (widget.scrollController == null) _scroll.dispose();
    if (widget.horizontalScrollController == null) _hScroll.dispose();
    super.dispose();
  }

  /// 焦点锚定缩放: 字号从 from 变为 to 时, 让局部坐标 focal 下的内容在
  /// 重排后仍位于 focal 处。行高随字号线性缩放, 换行点变化带来的偏差
  /// 在动画过程中持续重锚定, 不累积。
  void zoomAnchor({
    required double from,
    required double to,
    required Offset focal,
  }) {
    if (!mounted || from <= 0 || to == from) return;
    final k = to / from;
    final gutter =
        _gutterKey.currentContext?.findRenderObject() as RenderBox?;
    final viewY = focal.dy;
    // 横向视口从行号槽右侧开始; 焦点落在槽上(≤0)时横向不锚定。
    final viewX = focal.dx - (gutter?.size.width ?? 0);
    final contentY = (_scroll.hasClients ? _scroll.offset : 0) + viewY;
    final contentX =
        _hScroll.hasClients && viewX > 0 ? _hScroll.offset + viewX : 0.0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scroll.hasClients) {
        _scroll.jumpTo(
          (contentY * k - viewY).clamp(0.0, _scroll.position.maxScrollExtent),
        );
      }
      if (_hScroll.hasClients && viewX > 0) {
        _hScroll.jumpTo(
          (contentX * k - viewX).clamp(0.0, _hScroll.position.maxScrollExtent),
        );
      }
    });
  }

  RenderEditable? _editable() {
    RenderEditable? found;
    void visit(RenderObject node) {
      if (node is RenderEditable) {
        found = node;
        return;
      }
      node.visitChildren(visit);
    }

    final root = _fieldKey.currentContext?.findRenderObject();
    if (root != null) visit(root);
    return found;
  }

  /// 某行的最高诊断级别(null=无, 1=error, 2=warning); 供行号槽画标记
  int? _diagSeverity(int line) {
    int? sev;
    for (final d in widget.controller.diagnostics) {
      if (d.line != line || d.severity > 2) continue;
      if (sev == null || d.severity < sev) sev = d.severity;
    }
    return sev;
  }

  /// 行号槽点击 → 定位到行 → 弹出该行诊断详情 + LSP 快速修复
  Future<void> _onGutterTap(TapUpDetails details) async {
    final line = _lineAtDy(details.localPosition.dy);
    if (line == null) return;
    final diags = widget.controller.diagnostics
        .where((d) => d.line == line)
        .toList();
    if (diags.isEmpty) return;
    // 快速修复: 诊断区间并集请求 codeAction(仅 dart 文件且语言服务就绪)
    final path = widget.filePath;
    final controller = widget.controller;
    final snapshot = controller.text;
    bool current() =>
        mounted &&
        identical(widget.controller, controller) &&
        controller.text == snapshot &&
        widget.filePath == path;
    var actions = const <LspCodeAction>[];
    if (path != null &&
        path.endsWith('.dart') &&
        widget.language?.ready == true) {
      actions = await widget.language!.codeActions(
        path,
        snapshot,
        diags.first.line,
        diags.first.character,
        diags.last.endLine,
        diags.last.endCharacter,
      );
    }
    if (!mounted || !current()) return;
    showAdaptiveSheet<void>(
      context: context,
      title: context.strings.linePPIssues(line + 1, diags.length),
      width: 520,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
            for (final d in diags)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      d.severity == 1
                          ? Icons.error
                          : Icons.warning_amber_outlined,
                      size: 15,
                      color: d.severity == 1
                          ? AppColors.danger
                          : AppColors.warn,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SelectableText(
                        d.message,
                        style: const TextStyle(fontSize: 12, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            if (actions.isNotEmpty) ...[
              const Divider(height: 1, color: AppColors.border),
              Padding(
                padding: EdgeInsets.fromLTRB(0, 10, 0, 2),
                child: Text(
                  context.strings.quickFix,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              for (final a in actions)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.auto_fix_high,
                    size: 16,
                    color: AppColors.success,
                  ),
                  title: Text(a.title, style: const TextStyle(fontSize: 12)),
                  onTap: () {
                    Navigator.pop(ctx);
                    if (current()) controller.applyLspEdits(a.edits);
                  },
                ),
            ],
        ],
      ),
    );
  }

  /// 纵坐标 → 可见行号(与 _LineNumbers 的定位算法一致)
  int? _lineAtDy(double dy) {
    final editor = _editable();
    final box = _gutterKey.currentContext?.findRenderObject() as RenderBox?;
    if (editor == null || box == null || !editor.hasSize) return null;
    final delta =
        editor.localToGlobal(Offset.zero) - box.localToGlobal(Offset.zero);
    Rect caret(int line) => editor
        .getLocalRectForCaret(TextPosition(offset: _starts[line]))
        .shift(delta);
    var low = 0, high = _starts.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (caret(mid).bottom < dy) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    if (low >= _starts.length) return null;
    final r = caret(low);
    return (dy >= r.top - 2 && dy <= r.bottom + 2) ? low : null;
  }

  /// 光标所在逻辑行(0 基)
  int _caretLine() {
    final off = widget.controller.selection.baseOffset.clamp(
      0,
      widget.controller.text.length,
    );
    var lo = 0, hi = _starts.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_starts[mid] <= off) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo - 1;
  }

  /// Shift+滚轮 = 横向滚动(长行模式)。纵向 Scrollable 已被
  /// [EditorWheelScrollPhysics] 在 Shift 按下时回绝, 这里抢到信号后自己滚。
  void _onHorizontalWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!HardwareKeyboard.instance.isShiftPressed) return;
    final delta = event.scrollDelta.dy;
    if (delta == 0 || !_hScroll.hasClients) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final max = _hScroll.position.maxScrollExtent;
      _hScroll.jumpTo((_hScroll.offset + delta).clamp(0.0, max).toDouble());
    });
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: 'JetBrainsMono',
      fontSize: widget.fontSize,
      height: 1.45,
      color: CodeTheme.current.plain,
    );
    final theme = CodeTheme.current;
    // 给两级滚动都装上「修饰键闸门」: Ctrl/Shift 按住时不接受滚动,
    // 让放大(外层 CtrlWheelZoom)与横向滚动(本组件)拿到 pointer signal。
    final wheelPhysics = EditorWheelScrollPhysics(
      parent: ScrollConfiguration.of(context).getScrollPhysics(context),
    );
    return ColoredBox(
      color: theme.background,
      child: Row(
        children: [
          SizedBox(
            width: 22 + '${_starts.length}'.length * widget.fontSize * .65,
            // 点行号槽 = 查看该行诊断(移动端没有 hover, 这是"指一下"的等价物)
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: _onGutterTap,
              child: CustomPaint(
                key: _gutterKey,
                size: const Size(double.infinity, double.infinity),
                painter: _LineNumbers(
                  starts: _starts,
                  style: style,
                  selection: widget.controller.selection.baseOffset,
                  editable: _editable,
                  gutter: () =>
                      _gutterKey.currentContext?.findRenderObject()
                          as RenderBox?,
                  gutterBg: () => theme.gutterBackground,
                  gutterText: () => theme.gutterText,
                  gutterActive: () => theme.gutterActive,
                  diagSeverity: _diagSeverity,
                  repaint: Listenable.merge([_scroll, widget.controller]),
                ),
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final content = Stack(
                  children: [
                    Positioned.fill(
                      child: TextField(
                        key: _fieldKey,
                        controller: widget.controller,
                        scrollController: _scroll,
                        scrollPhysics: wheelPhysics,
                        focusNode: widget.focusNode,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        // Keep editing, selection and hardware keys enabled.
                        readOnly: widget.controller.editingLocked,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        // 不关 autocorrect/enableSuggestions: 这个组合会被 MIUI 判成
                        // 安全输入场景, 强制弹系统「安全键盘」(第三方输入法失效)
                        smartDashesType: SmartDashesType.disabled,
                        smartQuotesType: SmartQuotesType.disabled,
                        style: style,
                        strutStyle: StrutStyle.fromTextStyle(
                          style,
                          forceStrutHeight: true,
                        ),
                        cursorColor: theme.cursor,
                        inputFormatters: [CodeInputFormatter()],
                        decoration: const InputDecoration(
                          isDense: true,
                          filled: false,
                          contentPadding: EdgeInsets.all(10),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                        ),
                      ),
                    ),
                    // 行内诊断(Zed 式): 错误行正下方渲染消息盒;
                    // 宽屏(平板/外接屏)显示全部, 手机只跟随光标行避免满屏遮挡
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _InlineDiagnostics(
                            starts: _starts,
                            editable: _editable,
                            field: () =>
                                _fieldKey.currentContext?.findRenderObject()
                                    as RenderBox?,
                            diagnostics: () => widget.controller.diagnostics,
                            caretLine: _caretLine,
                            style: style,
                            repaint: Listenable.merge([
                              _scroll,
                              _hScroll,
                              widget.controller,
                            ]),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
                if (widget.wrap) return content;
                // 关闭软换行: 内容宽度按最长行撑开, 横向滚动查看(行号槽固定)
                final width = math.max(
                  constraints.maxWidth,
                  _maxCols * _charWidth(style) + 20,
                );
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  controller: _hScroll,
                  physics: wheelPhysics,
                  child: SizedBox(
                    width: width,
                    child: Listener(
                      onPointerSignal: _onHorizontalWheel,
                      child: content,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _LineNumbers extends CustomPainter {
  _LineNumbers({
    required this.starts,
    required this.style,
    required this.selection,
    required this.editable,
    required this.gutter,
    required this.gutterBg,
    required this.gutterText,
    required this.gutterActive,
    required this.diagSeverity,
    required super.repaint,
  });
  final List<int> starts;
  final TextStyle style;
  final int selection;
  final RenderEditable? Function() editable;
  final RenderBox? Function() gutter;
  final Color Function() gutterBg;
  final Color Function() gutterText;
  final Color Function() gutterActive;

  /// 行 → 最高诊断级别(null=无); 有问题的行在槽内画标记点
  final int? Function(int line) diagSeverity;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = gutterBg());
    final editor = editable();
    final box = gutter();
    if (editor == null || box == null || !editor.hasSize) return;
    final delta =
        editor.localToGlobal(Offset.zero) - box.localToGlobal(Offset.zero);
    Rect caret(int line) => editor
        .getLocalRectForCaret(TextPosition(offset: starts[line]))
        .shift(delta);
    var low = 0, high = starts.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (caret(mid).bottom < 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var i = low; i < starts.length; i++) {
      final rect = caret(i);
      if (rect.top > size.height) break;
      final current =
          selection >= starts[i] &&
          (i + 1 == starts.length || selection < starts[i + 1]);
      final painter = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: style.copyWith(color: current ? gutterActive() : gutterText()),
        ),
        textDirection: TextDirection.ltr,
        textScaler: editor.textScaler,
      )..layout();
      painter.paint(
        canvas,
        Offset(
          size.width - painter.width - 8,
          rect.center.dy - painter.height / 2,
        ),
      );
      painter.dispose();
      final sev = diagSeverity(i);
      if (sev != null) {
        canvas.drawCircle(
          Offset(7, rect.center.dy),
          3,
          Paint()..color = sev == 1 ? AppColors.danger : AppColors.warn,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LineNumbers oldDelegate) => true;
}

/// 行内诊断(Zed 式): 错误行正下方渲染带左边条的消息盒, 随内容滚动。
/// 宽度 >= 600(平板/横屏/外接屏)显示全部可见行的诊断;
/// 手机竖屏只显示光标所在行, 避免消息盒层层遮挡代码。
class _InlineDiagnostics extends CustomPainter {
  _InlineDiagnostics({
    required this.starts,
    required this.editable,
    required this.field,
    required this.diagnostics,
    required this.caretLine,
    required this.style,
    required super.repaint,
  });

  final List<int> starts;
  final RenderEditable? Function() editable;
  final RenderBox? Function() field;
  final List<EditorDiagnostic> Function() diagnostics;
  final int Function() caretLine;
  final TextStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final theme = CodeTheme.current;
    final diags = diagnostics();
    if (diags.isEmpty) return;
    final editor = editable();
    final box = field();
    if (editor == null || box == null || !box.attached || !editor.hasSize) {
      return;
    }
    final delta =
        editor.localToGlobal(Offset.zero) - box.localToGlobal(Offset.zero);
    final contentLeft = delta.dx;
    final contentWidth = editor.size.width;
    Rect caretRect(int line) => editor
        .getLocalRectForCaret(
          TextPosition(offset: starts[line.clamp(0, starts.length - 1)]),
        )
        .shift(delta);
    // 二分定位首个可见行(与行号槽同款, 长文件不全量遍历)
    var low = 0, high = starts.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (caretRect(mid).bottom < 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final wide = size.width >= 600;
    final caret = caretLine();
    final msgStyle = style.copyWith(
      fontSize: style.fontSize! - 1.5,
      height: 1.35,
      color: theme.plain,
    );
    var occupied = 0.0;
    for (var i = low; i < starts.length; i++) {
      final rect = caretRect(i);
      if (rect.top > size.height) break;
      if (!wide && i != caret) continue;
      final lineDiags = diags
          .where((d) => d.line == i && d.severity <= 2)
          .toList();
      if (lineDiags.isEmpty) continue;
      // 逻辑行底边(换行的行取下一行行首的上缘; 末行落到编辑器底)
      final lineBottom = i + 1 < starts.length
          ? caretRect(i + 1).top
          : editor.size.height;
      var top = math.max(lineBottom + 2, occupied);
      for (final d in lineDiags) {
        final color = d.severity == 1 ? AppColors.danger : AppColors.warn;
        final tp = TextPainter(
          text: TextSpan(text: d.message, style: msgStyle),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: math.max(contentWidth - 32, 200.0));
        final box = Rect.fromLTWH(
          contentLeft + 10,
          top,
          contentWidth - 20,
          tp.height + 12,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(box, const Radius.circular(6)),
          Paint()..color = theme.diagBoxBackground,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(box, const Radius.circular(6)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = color.withValues(alpha: 0.55),
        );
        canvas.drawRect(
          Offset(box.left, box.top) & const Size(3, 0),
          Paint()
            ..color = color
            ..strokeWidth = box.height,
        );
        tp.paint(canvas, Offset(box.left + 12, box.top + 6));
        tp.dispose();
        top = box.bottom + 4;
      }
      occupied = top;
    }
  }

  @override
  bool shouldRepaint(_InlineDiagnostics oldDelegate) => true;
}

/// 滚轮修饰键闸门: 按住 Ctrl(缩放)或 Shift(横向滚动)时不接受滚动偏移。
///
/// Scrollable 收到 PointerScrollEvent 会先问 [shouldAcceptUserOffset]；返回
/// false 就不注册 pointer signal resolver，外层 [CtrlWheelZoom] 与本组件的
/// 横向 Listener 才能拿到事件——否则内层 Scrollable 先注册，Ctrl+滚轮会被
/// 「滚一屏」吃掉。
class EditorWheelScrollPhysics extends ScrollPhysics {
  const EditorWheelScrollPhysics({super.parent});

  @override
  EditorWheelScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      EditorWheelScrollPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed || keyboard.isShiftPressed) return false;
    return super.shouldAcceptUserOffset(position);
  }
}
