import 'package:flutter/widgets.dart';

import '../terminal/run_sessions.dart';

/// 工作台的界面布局态: 终端坞展开与否、代码/预览哪个在前。
/// 项目数据都在 ProjectSession; 这里只放"现在看哪块"这类 UI 事实, 让运行
/// 控件、版本控制面板、预览这些深层控件直接调用, 不再层层回传回调。
class WorkbenchLayout extends ChangeNotifier {
  WorkbenchLayout(this.executions);

  final RunSessions executions;
  bool terminalExpanded = true;
  bool showPreview = false;

  /// 宽屏永久侧栏: 显隐(工具条按钮 / Ctrl+B)与宽度(拖拽, 夹在 220–420)。
  bool sidebarVisible = true;
  double sidebarWidth = defaultSidebarWidth;

  static const double defaultSidebarWidth = 280;
  static const double sidebarMinWidth = 220;
  static const double sidebarMaxWidth = 420;

  /// Ctrl+B / 工具条按钮: 收起或展开侧栏(宽度保留, 展开即恢复)。
  void toggleSidebar() {
    sidebarVisible = !sidebarVisible;
    notifyListeners();
  }

  /// 拖拽右缘: 增量加到当前宽度并夹限; 无变化不通知。
  void resizeSidebar(double delta) {
    final next = (sidebarWidth + delta).clamp(
      sidebarMinWidth,
      sidebarMaxWidth,
    );
    if (next == sidebarWidth) return;
    sidebarWidth = next;
    notifyListeners();
  }

  /// 展开终端看输出; 指定会话时先切到它(如 Web 运行的会话)
  void showOutput({String? sessionId}) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (sessionId != null) executions.select(sessionId);
    terminalExpanded = true;
    notifyListeners();
  }

  /// 坞按钮: 正在编辑时先收键盘并保证终端展开, 否则切换展开/收起
  void toggleTerminal({required bool editing}) {
    if (editing || !terminalExpanded) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    terminalExpanded = editing || !terminalExpanded;
    notifyListeners();
  }

  /// 代码 ↔ 预览; 切进预览时终端收起(全屏看页面)
  void selectView({required bool preview}) {
    FocusManager.instance.primaryFocus?.unfocus();
    showPreview = preview;
    terminalExpanded = false;
    notifyListeners();
  }

  /// 返回键从预览退回代码(路由的 LocalHistoryEntry 撤销时由页面调用)
  void previewDismissed() {
    if (!showPreview) return;
    showPreview = false;
    notifyListeners();
  }
}
