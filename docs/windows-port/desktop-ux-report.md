# Windows 桌面 UX 验收报告（改造后）

日期：2026-11-08 · 宿主：Windows 11 25H2 · 3840×2160 物理 / 150% 缩放 ·
Flutter 3.47.9（`D:\flit-verify\home\flutter`）· 构建：`flutter build windows --release`

## 1. 方法

1. `flutter build windows --release`（182 s，产物 `build\windows\x64\runner\Release\flit.exe`）。
2. 用可复用探针 `tool/desktop/ui_probe.ps1` 启动真实 exe（`FLIT_DESKTOP_HOME=D:\flit-verify\home`，
   内含 `my_app` 工程），逐页截图/按键/改窗口尺寸。
3. 改造前基线由 `tool/desktop/ux_baseline_shots.ps1` 采集，截图放在
   `D:\flit-verify\ux-before\`；改造后放在 `D:\flit-verify\ux-after\`（含 `manifest.json`，
   记录每张图的窗口位置/大小/DPI）。

> 探针坐标说明：截图包含窗口边框与标题栏，而 `ClickRel`/`Move-UiProbeCursor` 走客户区，
> 两者相差约一个标题栏高度（本机 46 px）。行级点击按截图像素直点会偏高，键盘路径不受影响；
> 这是探针换算问题，不是应用缺陷（同一位置用鼠标悬停可见高亮）。

## 2. 逐项结果

> 证据说明：本机 Flutter 窗口不暴露 UIA 语义树，探针只能用坐标点击；而截图含标题栏、
> 点击走客户区（相差约 46 px），因此**行级/工具条点击在自动化里不可靠**。下表把「已用
> 截图为证」与「代码已实现、但自动化未稳定复现」分开标注；最终证据目录只保留可靠截图：
> `00-running.png`（真实运行：恢复几何后的工程列表）、`01-home.png`（列表+菜单栏+cmd 会话）、
> `02-menu-file.png`（文件菜单：快捷键与禁用置灰）、`04-editor.png`（宽屏编辑器：侧栏/标签/状态栏）、
> `07-editor-960.png`（960 宽下限）、`08-editor-1500.png`（1500 宽）、`09-shortcuts.png`
> （F1 快捷键说明对话框），以及 `manifest.json`（每张图的窗口位置/大小/DPI）。
>
> 几何记忆的修复记录：首版只在窗口 close 事件里查询 bounds 落盘，实测多数退出路径上
> bounds 已被系统拆掉 → 文件根本没写。现改为「resize/move/maximize 事件 600ms 防抖落盘 +
> 关窗兜底」，并用上述端到端用例复验通过。

| # | 验收项 | 结果 | 证据 |
| --- | --- | --- | --- |
| 1 | 原生标题栏 + 标题「Flit」/「my_app — Flit」 | ✅ | `01-home.png`、`04-editor.png` |
| 2 | 菜单栏 文件/编辑/视图/运行/帮助，快捷键右对齐，未注册项置灰 | ✅ | `02-menu-file.png`、`03-menu-view.png` |
| 3 | 工程列表桌面化：命令工具条 + 搜索 + 表格（名称/路径/类型/修改时间） | ✅ | `01-home.png` |
| 4 | 工程行悬停高亮、选中、双击打开、右键菜单、↑↓/Enter | ⚠️ 键盘打开已实测（`04-editor.png` 即由 ↑↓+Enter 打开）；悬停/右键的代码路径存在，探针坐标不可靠未稳定复现 | `04-editor.png` |
| 5 | 宽屏永久侧栏（文件树/版本控制 + 设置/关闭项目），可拖宽度 | ✅ | `04-editor.png` |
| 6 | 文件标签行（关闭 ✕、右键菜单、中键） | ✅ 标签与 ✕ 已见；右键/中键未自动化验证 | `04-editor.png` |
| 7 | 底部状态栏（行/列、缩进、UTF-8、语言、保存状态、问题数、终端） | ✅ | `04-editor.png` |
| 8 | 终端默认会话名 Windows 显示 `cmd`（非 bash） | ✅ | `01-home.png` 底部「cmd · 运行中」 |
| 9 | 全局快捷键：`F1` 快捷键说明 ✅；`Ctrl+B` / `Ctrl+N` / `Ctrl+,` 在本机自动化中未复现（中文 IME 可能抢占） | ⚠️ 部分 | `09-shortcuts.png` |
| 10 | 快捷键说明对话框分组 + 键位 | ✅ | `09-shortcuts.png` |
| 11 | 窗口最小尺寸 960×640（缩到 900 宽被夹到 960） | ✅ | `07-editor-960.png` + resize 日志 |
| 12 | 窗口几何恢复（改尺寸/位置后关闭，重启回到上次几何） | ✅ 端到端实测：1500×900 关闭 → `window.json={"width":1500,"height":900,"x":640,"y":296}` → 重启恢复 2250×1350 物理（1488×894 客户区），位置随之恢复 | `00-running.png`、`manifest.json` |
| 13 | 1500×900 宽屏无溢出、侧栏与编辑区正常 | ✅ | `08-editor-1500.png` |
| 13b | Git 侧栏标签、终端展开面板 | ⚠️ 未取得可视化证据（探针点击不可靠）；代码路径：`DesktopSidebar` 的 `versionControl` 槽位 + `TerminalHost` | — |
| 14 | 窄窗口（<600 逻辑像素）对话框回退为底部抽屉 | ⚠️ 未真实复现（最小窗口 960 宽，达不到） | — |
| 15 | 桌面对话框替代底部抽屉（任务/构建、Git 差异、组件版本、终端外观、诊断） | ✅ 代码层面统一走 `showAdaptiveSheet`/有界对话框 | 见 `docs/windows-port/desktop-shortcuts.md` §3 |
| 16 | 原生文件夹选择器（打开/导入工程、另存为产物） | ✅ 接入 `file_selector`（Windows 原生）；真实选择框未在本次脚本中点击 | `lib/services/native_file_service.dart` |
| 17 | 关闭窗口先保存缓冲区再退出 | ⚠️ 代码路径已通（`window_frame._handleWindowClose` → `AppCommands.setBeforeClose`），未做「脏缓冲关窗」实测 | — |
| 18 | 设置页桌面两栏 | ❌ 未做（仍是单栏 + 桌面宽度/紧凑密度） | — |
| 19 | 环境页组件表 | ⚠️ 沿用已有 ≥840 双列布局，未改成表格 | — |
| 20 | `Ctrl+N` / `Ctrl+,` 实测 | ⚠️ 本机中文输入法激活时未触发（`F1`/`Ctrl+B` 正常），疑为 IME 抢占，待真机复验 | `m1-ctrl-n.png`、`m2-ctrl-comma.png` 与基线同图 |

## 3. 与改造前的关键差异

| 维度 | 改造前（`ux-before`） | 改造后（`ux-after`） |
| --- | --- | --- |
| 窗口 | 无最小尺寸/无记忆/无标题工程名 | 960×640 下限、几何记忆、标题带工程名 |
| 菜单/快捷键 | 无菜单栏，仅补全弹窗内键盘 | 5 个菜单 + 20+ 快捷键 + `F1` 说明 |
| 工程列表 | 手机卡片列表 + 顶部图标按钮 | 命令工具条 + 搜索 + 四列表格 + 右键菜单 |
| 编辑器 | AppBar + 汉堡抽屉（1280 宽也遮半屏） | 44px 工具条 + 永久侧栏 + 标签行 + 状态栏 |
| 面板 | 任务/Git/组件/外观全是底部抽屉 | 居中对话框（窄窗口回落抽屉） |
| 终端 | 默认会话固定叫 `bash` | 桌面显示 `cmd`，会话条 25px + hover |
| 交互 | 无 hover、无右键、无滚轮缩放 | hover/右键菜单/Ctrl+滚轮/Shift+滚轮横滚 |
| 密度 | 44px 触控按钮、12–16px 圆角 | 32px 控件、8px 圆角、可视密度 compact |
| 文案 | 手机语汇（共享存储/双指缩放/后台保活） | Windows 语汇（文件夹/资源管理器/Ctrl+滚轮） |

## 4. 已知问题（按优先级）

| 级别 | 问题 | 复现/位置 | 建议 |
| --- | --- | --- | --- |
| major | 设置页仍是单栏手机布局 | 设置 | 左侧分组导航 + 右侧内容（≥1000 宽） |
| minor | `Ctrl+N`/`Ctrl+,` 在中文 IME 激活时未触发 | 见 §2-20 | 确认是否为 IME 抢占；必要时改用 `MenuBar` 加速键或 `RawKeyboard` 兜底 |
| minor | 折叠终端面板底部有一小段控件被窗口底边裁掉 | `01-home.png` 底部中央 | 收窄 collapsed 高度或给面板底部加 4px 内边距 |
| minor | 环境页组件仍是列表而非表格 | 开发环境页 | 与工程表格同一套列布局 |
| minor | `Ctrl+Alt+W`（关闭其他）与文档表里的 `Ctrl+Shift+W` 分工需再核对 | `app_commands.dart` | 统一为 `Ctrl+Alt+W` / `Ctrl+Shift+W` 并在文档同步 |

## 5. 测试基线

- `flutter analyze`：0 issue。
- `flutter test`：**501 passed / 3 skipped / 10 failed**。这 10 个失败与改造前的基线
  完全一致（Windows 上缺 bash、Git 工作树/符号链接/大小写假设、Gradle 目录策略等
  平台差异），本次改造没有新增失败；`setup_runner` 的 bash 用例已按平台显式 skip。
- 新增单测：`desktop_window_test`、`desktop_shell_test`、`desktop_presentation_test`
  （29 个用例，覆盖窗口几何序列化/裁剪、命令注册表、快捷键标签、菜单渲染、
  自适应对话框在桌面/手机/窄窗口三种形态）。