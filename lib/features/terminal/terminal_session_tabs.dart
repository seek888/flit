import 'package:flit/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme.dart';
import '../../services/shell.dart';
import 'console_session.dart';
import 'run_sessions.dart';

class TerminalSessionTabs extends StatelessWidget {
  const TerminalSessionTabs({super.key});

  @override
  Widget build(BuildContext context) {
    final executions = context.read<RunSessions>();
    return ListenableBuilder(
      listenable: executions,
      builder: (context, _) => _tabs(executions),
    );
  }

  Widget _tabs(RunSessions executions) {
    Widget tab(String? id, String title, {bool closable = false}) {
      final selected = executions.selectedId == id;
      final color = selected ? AppColors.accent : AppColors.textSecondary;
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Material(
          color: selected
              ? AppColors.accent.withValues(alpha: .12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 64),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  canRequestFocus: false,
                  borderRadius: BorderRadius.circular(6),
                  hoverColor: AppColors.hover,
                  onTap: () => executions.select(id),
                  // 桌面 25 高更紧凑；手机保持 30 的触达高度
                  child: Container(
                    height: isDesktopPlatform ? 25 : 30,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.center,
                    child: Text(
                      terminalDisplayTitle(title),
                      style: TextStyle(fontSize: 11, color: color),
                    ),
                  ),
                ),
                if (closable)
                  Tooltip(
                    message: strings.closePSession(title),
                    child: InkWell(
                      canRequestFocus: false,
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => executions.close(id!),
                      child: SizedBox(
                        width: 22,
                        height: 30,
                        child: Icon(Icons.close, size: 13, color: color),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return ExcludeFocus(
      child: SizedBox(
        // 撑满宽度: 外层面板 Column 默认按 center 摆放收缩宽度的子级,
        // 不撑满时会话条会整体浮在中间而不是从 start 对齐
        width: double.infinity,
        height: 36,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              // 桌面显示 cmd、手机显示 bash（见 defaultShellTitle）
              tab(null, defaultShellTitle),
              for (final run in executions.all)
                tab(run.id, run.title, closable: true),
            ],
          ),
        ),
      ),
    );
  }
}
