import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/desktop/desktop_presentation.dart';
import '../../../core/theme.dart';
import '../../../l10n/strings.dart';
import '../../workspace/project_session.dart';
import '../controller/code_controller.dart';
import '../lsp/lsp_client.dart';
import '../lsp/protocol.dart';

/// Analysis belongs to the active file, not to the resizable terminal dock.
class EditorAnalysisStatus extends StatelessWidget {
  const EditorAnalysisStatus({
    super.key,
    required this.controller,
    required this.focusNode,
  });

  final CodeController controller;
  final FocusNode focusNode;

  String _label(BuildContext context, LanguageServiceState state) =>
      controller.language != 'dart'
      ? context.strings.syntaxHighlighting
      : switch (state) {
          LanguageServiceState.starting => context.strings.startingDartAnalyzer,
          LanguageServiceState.ready => context.strings.dartAnalysisReady,
          _ => context.strings.dartBasicCompletion,
        };

  @override
  Widget build(BuildContext context) {
    final language = context.read<LspClient>();
    return ListenableBuilder(
      listenable: Listenable.merge([language.state, controller]),
      builder: (context, _) {
        final state = language.state.value;
        final diagnostics = controller.diagnostics;
        final errors = diagnostics.any((d) => d.severity == 1);
        final warnings = diagnostics.any((d) => d.severity == 2);
        final starting =
            controller.language == 'dart' &&
            state == LanguageServiceState.starting;
        final color = errors
            ? AppColors.danger
            : warnings
            ? AppColors.warn
            : AppColors.textSecondary;
        return ExcludeFocus(
          child: TextButton(
            onPressed: () => _showDetails(context, language),
            style: TextButton.styleFrom(
              foregroundColor: color,
              minimumSize: const Size(36, 36),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Tooltip(
              message:
                  '${_label(context, state)} · '
                  '${context.strings.problemsP(diagnostics.length)}',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (starting)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    )
                  else
                    Icon(
                      errors
                          ? Icons.error_outline
                          : warnings
                          ? Icons.warning_amber_rounded
                          : diagnostics.isNotEmpty
                          ? Icons.info_outline
                          : controller.language == 'dart' &&
                                state == LanguageServiceState.ready
                          ? Icons.check_circle_outline
                          : Icons.code,
                      size: 16,
                    ),
                  if (diagnostics.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Text(
                      diagnostics.length > 99 ? '99+' : '${diagnostics.length}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 桌面: 居中面板对话框（宽 560、可滚动列表）；Android: 仍从底部弹层。
  /// 两边的标题与关闭/手柄都由 showAdaptiveSheet 提供，这里只画内容。
  Future<void> _showDetails(BuildContext context, LspClient language) {
    final project = context.read<ProjectSession>();
    final snapshot = controller.text;
    final screen = MediaQuery.sizeOf(context);
    final height = (screen.height * (desktopPresentation ? .62 : .5)).clamp(
      240.0,
      560.0,
    );
    return showAdaptiveSheet<void>(
      context: context,
      title: context.strings.problemsCurrentFile,
      width: 560,
      scrollable: false,
      builder: (sheetContext) => SizedBox(
        height: height,
        child: ListenableBuilder(
          listenable: Listenable.merge([language.state, controller]),
          builder: (context, _) {
            final state = language.state.value;
            final diagnostics = controller.diagnostics;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _label(context, state),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                      if (controller.language == 'dart' &&
                          state != LanguageServiceState.ready &&
                          state != LanguageServiceState.starting)
                        TextButton(
                          onPressed: () => unawaited(project.activate()),
                          child: Text(context.strings.retry),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: diagnostics.isEmpty
                      ? Center(child: Text(context.strings.noProblems))
                      : ListView.builder(
                          itemCount: diagnostics.length,
                          itemBuilder: (_, i) {
                            final diagnostic = diagnostics[i];
                            return ListTile(
                              dense: true,
                              leading: Icon(
                                diagnostic.severity == 1
                                    ? Icons.error_outline
                                    : diagnostic.severity == 2
                                    ? Icons.warning_amber
                                    : Icons.info_outline,
                                size: 18,
                                color: diagnostic.severity == 1
                                    ? AppColors.danger
                                    : diagnostic.severity == 2
                                    ? AppColors.warn
                                    : AppColors.textSecondary,
                              ),
                              title: Text(
                                diagnostic.message,
                                style: const TextStyle(fontSize: 13),
                              ),
                              subtitle: Text(
                                context.strings.linePColumnP(
                                  diagnostic.line + 1,
                                  diagnostic.character + 1,
                                ),
                                style: const TextStyle(fontSize: 11),
                              ),
                              onTap: () {
                                Navigator.pop(sheetContext);
                                if (project.closed ||
                                    !identical(
                                      project.documents.current?.controller,
                                      controller,
                                    ) ||
                                    controller.text != snapshot) {
                                  return;
                                }
                                try {
                                  final offset = LspProtocol.positionToOffset(
                                    snapshot,
                                    diagnostic.line,
                                    diagnostic.character,
                                  );
                                  controller.selection = TextSelection.collapsed(
                                    offset: offset,
                                  );
                                  focusNode.requestFocus();
                                  WidgetsBinding.instance.addPostFrameCallback((
                                    _,
                                  ) {
                                    if (!focusNode.hasFocus) return;
                                    final editable = focusNode.context
                                        ?.findAncestorStateOfType<
                                          EditableTextState
                                        >();
                                    editable?.bringIntoView(
                                      TextPosition(offset: offset),
                                    );
                                  });
                                } on FormatException {
                                  // Wait for fresh diagnostics after an edit.
                                }
                              },
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}