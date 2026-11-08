import 'package:flit/l10n/strings.dart';
import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../../../core/workbench_controls.dart';
import '../controller/code_controller.dart';

/// Single compact row sharing one surface with the terminal above.
/// Run/build actions live in the app bar (EditorRunControls).
/// [dense] 是桌面形态: 32 高、更紧的按钮, 与 Windows 状态栏/标签行同一密度。
class EditorDockToolbar extends StatelessWidget {
  const EditorDockToolbar({
    super.key,
    required this.controller,
    required this.previewAvailable,
    required this.showPreview,
    required this.terminalExpanded,
    required this.canEdit,
    required this.onCode,
    required this.onPreview,
    required this.onTerminal,
    this.docPreviewAvailable = false,
    this.docPreviewOn = false,
    this.docPreviewLabel = 'MD',
    this.onDocPreview,
    this.dense = false,
  });

  final CodeController controller;
  final bool previewAvailable, showPreview, terminalExpanded, canEdit;
  final VoidCallback onCode, onPreview, onTerminal;

  /// 当前缓冲是 markdown 时出现, 切编辑缓冲 ↔ 渲染预览
  final bool docPreviewAvailable, docPreviewOn;
  final String docPreviewLabel;
  final VoidCallback? onDocPreview;

  /// 桌面紧凑形态（32 高）
  final bool dense;

  Widget _tab(String label, bool selected, VoidCallback action) => TextButton(
    onPressed: action,
    style: TextButton.styleFrom(
      foregroundColor: selected ? AppColors.accent : AppColors.textSecondary,
      backgroundColor: selected
          ? AppColors.accent.withValues(alpha: .12)
          : Colors.transparent,
      minimumSize: dense ? const Size(40, 26) : const Size(46, 36),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    child: Text(label, style: const TextStyle(fontSize: 12)),
  );

  @override
  Widget build(BuildContext context) => TextFieldTapRegion(
    child: ExcludeFocus(
      child: Material(
        color: AppColors.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: SizedBox(
            height: dense ? 32 : 44,
            child: Row(
              children: [
                _tab(
                  context.strings.code,
                  !showPreview && !docPreviewOn,
                  onCode,
                ),
                if (docPreviewAvailable)
                  _tab(docPreviewLabel, docPreviewOn, onDocPreview ?? () {}),
                if (previewAvailable)
                  _tab(context.strings.preview, showPreview, onPreview),
                const SizedBox(width: 4),
                WorkbenchButton(
                  icon: Icons.terminal,
                  tooltip: terminalExpanded
                      ? context.strings.collapseTerminal
                      : context.strings.expandTerminal,
                  active: terminalExpanded,
                  onPressed: onTerminal,
                ),
                const Spacer(),
                ListenableBuilder(
                  listenable: controller,
                  builder: (_, __) => Row(
                    children: [
                      WorkbenchButton(
                        icon: Icons.undo,
                        tooltip: context.strings.undo,
                        onPressed: canEdit && controller.canUndo
                            ? controller.undo
                            : null,
                      ),
                      WorkbenchButton(
                        icon: Icons.redo,
                        tooltip: context.strings.redo,
                        onPressed: canEdit && controller.canRedo
                            ? controller.redo
                            : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
