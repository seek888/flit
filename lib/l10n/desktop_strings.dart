import 'package:flutter/widgets.dart';

import 'app_localizations.dart';
import 'strings.dart';

/// 桌面外壳的文案：菜单、对话框按钮、页面动作、状态栏与提示。
///
/// 现有的 `strings`（AppLocalizations）是按 Android 页面组织的，桌面新增的
/// 菜单/状态栏没有对应 key；这里用 [_t] 做最小双语文案表，按
/// [localeName] 判断 zh/en，不引入新的 arb/生成流程。
class DesktopStrings {
  const DesktopStrings(this.localeName);

  final String localeName;

  bool get _zh => localeName.toLowerCase().startsWith('zh');

  String _t(String zh, String en) => _zh ? zh : en;

  // ---------- 菜单 ----------
  String get file => _t('文件', 'File');
  String get edit => _t('编辑', 'Edit');
  String get view => _t('视图', 'View');
  String get run => _t('运行', 'Run');
  String get help => _t('帮助', 'Help');

  String get newProject => _t('新建工程', 'New Project');
  String get openProject => _t('打开工程', 'Open Project');
  String get importProject => _t('导入文件夹', 'Import Folder');
  String get save => _t('保存', 'Save');
  String get saveAll => _t('全部保存', 'Save All');
  String get closeTab => _t('关闭标签', 'Close Tab');
  String get closeOtherTabs => _t('关闭其他标签', 'Close Other Tabs');
  String get closeAllTabs => _t('关闭全部标签', 'Close All Tabs');
  String get closeProject => _t('关闭工程', 'Close Project');
  String get quit => _t('退出', 'Exit');

  String get undo => _t('撤销', 'Undo');
  String get redo => _t('重做', 'Redo');
  String get cut => _t('剪切', 'Cut');
  String get copy => _t('复制', 'Copy');
  String get paste => _t('粘贴', 'Paste');
  String get selectAll => _t('全选', 'Select All');

  String get fileTree => _t('文件树', 'File Tree');
  String get terminal => _t('终端', 'Terminal');
  String get zoomIn => _t('放大', 'Zoom In');
  String get zoomOut => _t('缩小', 'Zoom Out');
  String get actualSize => _t('实际大小', 'Actual Size');
  String get refresh => _t('刷新', 'Refresh');
  String get fullScreen => _t('全屏', 'Full Screen');
  String get commandPalette => _t('命令面板', 'Command Palette');
  String get settings => _t('设置', 'Settings');

  String get runProject => _t('运行工程', 'Run Project');
  String get stop => _t('停止', 'Stop');
  String get rebuild => _t('重新构建', 'Rebuild');

  String get shortcuts => _t('快捷键说明', 'Keyboard Shortcuts');
  String get about => _t('关于', 'About');

  // ---------- 标签页 ----------
  String get nextTab => _t('下一个标签', 'Next Tab');
  String get previousTab => _t('上一个标签', 'Previous Tab');

  // ---------- 对话框按钮 ----------
  String get ok => _t('确定', 'OK');
  String get cancel => _t('取消', 'Cancel');
  String get discard => _t('放弃', 'Discard');
  String get close => _t('关闭', 'Close');
  String get browse => _t('浏览…', 'Browse…');
  String get chooseFolder => _t('选择文件夹', 'Choose Folder');
  String get saveAs => _t('另存为', 'Save As');

  // ---------- 页面动作 ----------
  String get openContainingFolder =>
      _t('打开所在文件夹', 'Open Containing Folder');
  String get revealInExplorer =>
      _t('在资源管理器中显示', 'Show in Explorer');
  String get openFolder => _t('打开文件夹', 'Open Folder');
  String get copyPath => _t('复制路径', 'Copy Path');
  String get rename => _t('重命名', 'Rename');
  String get delete => _t('删除', 'Delete');
  String get newFile => _t('新建文件', 'New File');
  String get newFolder => _t('新建文件夹', 'New Folder');
  String get searchFiles => _t('搜索文件', 'Search Files');
  String get recentProjects => _t('最近工程', 'Recent Projects');
  String get noProjects => _t('没有工程', 'No Projects');
  String get importExistingProject => _t('导入已有工程', 'Import Existing Project');
  String get chooseProjectDirectory =>
      _t('选择工程目录', 'Choose Project Directory');
  String get projectLocation => _t('工程位置', 'Project Location');

  // ---------- 状态栏 ----------
  String get ready => _t('就绪', 'Ready');
  String get unsaved => _t('未保存', 'Unsaved');
  String get saving => _t('保存中', 'Saving');
  String get saved => _t('已保存', 'Saved');
  String get saveFailed => _t('保存失败', 'Save failed');
  String get utf8 => 'UTF-8';
  String get encoding => _t('编码', 'Encoding');
  String get languageMode => _t('语言', 'Language');
  String get branch => _t('分支', 'Branch');
  String get environment => _t('环境', 'Environment');
  String get buildSucceeded => _t('构建成功', 'Build succeeded');
  String get buildFailed => _t('构建失败', 'Build failed');

  /// 光标位置，如 `行 3, 列 12` / `Ln 3, Col 12`。
  String lineColumn(int line, int column) =>
      _t('行 $line, 列 $column', 'Ln $line, Col $column');

  /// 诊断数，如 `3 个问题` / `3 problems`。
  String diagnostics(int count) =>
      _t('$count 个问题', count == 1 ? '1 problem' : '$count problems');

  // ---------- 提示 ----------
  String get ctrlWheelZoomHint => _t('Ctrl+滚轮缩放', 'Ctrl+wheel to zoom');
  String get dragDividerHint =>
      _t('拖动分隔条调整面板', 'Drag the divider to resize panels');
  String get shortcutsTitle => _t('快捷键说明', 'Keyboard Shortcuts');

  // ---------- 关于 ----------
  String get aboutFlit => 'Flit';
  String get windowsEdition => _t('Windows 桌面版', 'Windows desktop edition');
  String get aboutDescription => _t(
    'Flutter 开发工作台：菜单栏、全局快捷键、宽屏侧栏与原生文件选择器，'
        '按 Windows 桌面习惯重新布局。',
    'A Flutter development workbench rebuilt for Windows: menu bar, '
        'global shortcuts, widescreen sidebar and native file pickers.',
  );
  String get versionLabel => _t('版本', 'Version');

  // ---------- 快捷键分组（快捷键说明对话框） ----------
  String get shortcutsFileGroup => _t('文件', 'File');
  String get shortcutsEditGroup => _t('编辑', 'Edit');
  String get shortcutsViewGroup => _t('视图', 'View');
  String get shortcutsRunGroup => _t('运行', 'Run');
  String get shortcutsHelpGroup => _t('其他', 'Other');
}

/// 从当前 BuildContext 取桌面文案（无本地化时回落到全局 strings）。
DesktopStrings desktopStrings(BuildContext context) => DesktopStrings(
  AppLocalizations.of(context)?.localeName ?? strings.localeName,
);

/// 无 BuildContext 的服务层使用的静态回落（跟随全局 strings 语言）。
DesktopStrings get desktopStringsFallback => DesktopStrings(strings.localeName);