import 'package:flutter/material.dart';

import '../../../core/desktop/app_commands.dart';
import '../../../core/desktop/hover.dart';
import '../../../core/theme.dart';
import '../../../l10n/desktop_strings.dart';

/// Windows IDE 式底部状态栏（22px，单行细字）。
///
/// 左侧是光标/缩进/编码/语言/保存状态，右侧是分支、诊断数与终端开关；
/// 可点项悬停高亮并带 Tooltip，不挤压编辑区（用 Spacer 撑开）。
class DesktopStatusBar extends StatelessWidget {
  const DesktopStatusBar({
    super.key,
    required this.line,
    required this.column,
    required this.language,
    required this.saveLabel,
    required this.diagnostics,
    required this.terminalExpanded,
    required this.onToggleTerminal,
    this.branch,
    this.saveFailed = false,
    this.onShowProblems,
  });

  final int line;
  final int column;
  final String language;
  final String saveLabel;
  final int diagnostics;
  final bool terminalExpanded;
  final VoidCallback onToggleTerminal;
  final String? branch;
  final bool saveFailed;
  final VoidCallback? onShowProblems;

  @override
  Widget build(BuildContext context) {
    final t = desktopStrings(context);
    final zh = t.localeName.toLowerCase().startsWith('zh');
    final indentation = zh ? '空格: 2' : 'Spaces: 2';
    final branchName = branch?.trim() ?? '';
    return Container(
      height: 22,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          _TextItem(t.lineColumn(line, column)),
          const _Divider(),
          _TextItem(indentation),
          const _Divider(),
          _TextItem(t.utf8),
          const _Divider(),
          _TextItem(language),
          if (saveLabel.isNotEmpty) ...[
            const _Divider(),
            _TextItem(
              saveLabel,
              color: saveFailed ? AppColors.danger : AppColors.textSecondary,
            ),
          ],
          const Spacer(),
          if (branchName.isNotEmpty) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 190),
              child: _ActionItem(
                icon: Icons.account_tree_outlined,
                label: branchName,
                tooltip: '${t.branch}: $branchName',
              ),
            ),
            const _Divider(),
          ],
          _ActionItem(
            icon: diagnostics > 0
                ? Icons.error_outline
                : Icons.check_circle_outline,
            label: t.diagnostics(diagnostics),
            tooltip: t.diagnostics(diagnostics),
            color: diagnostics > 0 ? AppColors.warn : AppColors.textSecondary,
            onTap: onShowProblems,
          ),
          const _Divider(),
          _ActionItem(
            icon: Icons.terminal,
            label: t.terminal,
            tooltip:
                '${t.terminal} · ${shortcutLabel(AppCommand.toggleTerminal)}',
            active: terminalExpanded,
            onTap: onToggleTerminal,
          ),
        ],
      ),
    );
  }
}

/// 状态栏纯文字段（无交互）。
class _TextItem extends StatelessWidget {
  const _TextItem(this.text, {this.color = AppColors.textSecondary});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11, color: color),
    ),
  );
}

/// 状态栏可点段：悬停底色 + hand 光标；[active] 时用强调色。
class _ActionItem extends StatelessWidget {
  const _ActionItem({
    required this.icon,
    required this.label,
    this.tooltip,
    this.onTap,
    this.color,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback? onTap;
  final Color? color;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final textColor = color ?? AppColors.textSecondary;
    return Tooltip(
      message: tooltip ?? label,
      waitDuration: const Duration(milliseconds: 400),
      child: HoverBuilder(
        enabled: onTap != null,
        cursor: onTap == null ? null : SystemMouseCursors.click,
        builder: (context, hovering) => InkWell(
          onTap: onTap,
          child: Container(
            color: hovering ? AppColors.hover : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 12,
                  color: active ? AppColors.accent : textColor,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: active ? AppColors.accent : textColor,
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

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 12,
    margin: const EdgeInsets.symmetric(horizontal: 2),
    color: AppColors.divider,
  );
}