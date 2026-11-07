# Windows 移植分析 03：CI 基线 / 打包与发布 / 桌面外壳与 UX / 测试阻断 / 文档

> 状态：粗稿落盘（先保证成果不丢），随后追加校验细节。
> 范围：`.github/workflows/`、缺失的 `windows/`、`web/`、`lib/features/{run,editor,workspace,environment}`、`lib/core/`、`lib/services/{app_releases,desktop_shell,desktop_toolchain,shell}.dart`、`test/`、README/docs。
> 方法：本机无 flutter/dart，全部为**静态精读 + grep + GitHub Actions 实跑日志**（只读，未改源码/工作流，未 push）。
> 相关报告：环境层见 `01-environment.md`（task-1），编辑器/终端/Git/设备见 `02-features.md`（task-2）。本报告只在构建链、发布、外壳、UX、测试与 CI 层面展开，环境安装细节不重复。

---

## 0. 一句话结论

Windows 版**已经能编译、能启动、能出 zip 包**（CI 稳定成功），但距离交付目标还差三层：
**(a) 「在 Windows 版 Flit 里打 APK/Web」被 Android 专属前置检查与 POSIX 命令硬卡住（P0）；(b) 没有真正的「安装包」与版本化发布，只有每次跑号命名的 preview zip；(c) 桌面外壳/UX 基本没做（无窗口最小尺寸与记忆、无菜单与快捷键、文件树仍是手机抽屉、无原生文件对话框）。**

---

## 1. CI 基线数据（实测，非推断）

### 1.1 最近一次成功的 Windows Build

- Run：**#19 / id `42348982433`**，event=push，branch=`main`，head_sha=`b02a4ccca8dd57117ae53d34ee95a864ab21723d`（= 当前工作区 HEAD `b02a4cc`，即这份代码就是跑通的那份）。
- 时间：2026-11-07T06:54:01Z → 06:58:25Z，**约 4 分 21 秒**；conclusion=success。
- 环境：`windows-latest`，Flutter **3.47.9 stable**（Dart 3.13.7，Engine hash 9e02526…，Framework revision c197ca5199）；仓库 `android-release.yml` 里锁的是 3.47.8，**两条工作流的 Flutter 版本不一致**。
- 步骤耗时：Setup Flutter 72s / Generate runner 2s / pub get 1s / local_fs_test 9s / 全量测试 68s / analyze 13s / build windows 74s / 打包+上传+发 Release ~8s。

### 1.2 三个必答问题的实测答案

| 问题 | 实测结果 |
|---|---|
| `flutter analyze` 有多少 issue | **0 个**。`analyze.log` 全文只有两行：`Analyzing flit...` / `No issues found! (ran in 11.1s)`。Windows 上 analyzer 完全干净。 |
| `flutter test` 通过/失败 | **231 passed / 96 failed**（`test.log` 末尾 `::error::231 tests passed, 96 failed.`）。该 step 是 `continue-on-error: true`，所以 job 仍是绿的。**唯一阻断的测试是 `test/local_fs_test.dart`（10/10 通过）**。 |
| release 包多大、含什么 | Release 资产 `flit-windows-x64.zip` = **14,510,498 B（≈13.8 MiB）**；上传到 artifact 的 zip = 14,493,451 B（artifact 会再压一层）。解压后目录（CI step 输出的 `Get-ChildItem`）：`data/`（目录，flutter_assets 等）、`flit.exe` 91,136、`flutter_windows.dll` 21,289,472、`flutter_pty.dll` 18,944、`permission_handler_windows_plugin.dll` 115,200、`msvcp140.dll` 643,512、`vcruntime140.dll` 178,616、`vcruntime140_1.dll` 50,112、`concrt140.dll` 374,200（4 个 MSVC 运行库由 workflow 从 `C:\Windows\System32` 复制进去）。 |

### 1.3 windows/ 生成物：CI 到底写了哪些文件

`flutter create --platforms=windows --project-name flit --org cc.lycstar .` 输出 **`Wrote 21 files.`**，实际清单：

- `windows/.gitignore`
- `windows/CMakeLists.txt`
- `windows/flutter/CMakeLists.txt`
- `windows/runner/CMakeLists.txt`
- `windows/runner/flutter_window.cpp` / `.h`
- `windows/runner/main.cpp`
- `windows/runner/resource.h`
- `windows/runner/resources/app_icon.ico`
- `windows/runner/runner.exe.manifest`
- `windows/runner/Runner.rc`
- `windows/runner/utils.cpp` / `.h`
- `windows/runner/win32_window.cpp` / `.h`
- 另有 `.idea/{libraries/Dart_SDK.xml,libraries/KotlinJavaRuntime.xml,modules.xml,runConfigurations/main_dart.xml,workspace.xml}` 和 `flit.iml` —— 这 6 个是 IDE 文件，`.gitignore` 已经忽略了 `.idea/` 与 `*.iml`，**不该进仓库**（CI 每次都会重新生成，属于噪音）。

→ 结论：**windows/ 平台目录需要的 14 个文件全部是 Flutter 模板产物，零手写逻辑**。也就是说「提交进仓库」不涉及任何风险，只是把模板固化。

### 1.4 历史失败点（判断 CI 稳定性与阻断边界）

| run | 失败 step | 说明 |
|---|---|---|
| #2 `42255409597` | `Publish preview release` | 发布失败（sw 侧临时问题），**构建本身是好的** |
| #4 `42259957882` | `Build Windows (release)` | 编译失败（当时桌面代码未完成） |
| #10 `42315785130` | `Build Windows (release)` | 编译失败 |

→ 近 9 次 Windows Build 全部成功；失败都出现在代码/发布环节，不是环境抖动。**Windows 构建已有足够稳定性作为「阻断」基线。**

### 1.5 Android 侧基线（避免破坏的前提）

- `Android Release`：run #1、#2 失败，#3 成功 → tag `v1.0.0-fork.1`，资产 `flit-v1.0.0-fork.1-fa3ad94.apk`（**10,027,063 B**）。
- 该工作流里 `flutter analyze`、`flutter test`、`python3 -m unittest` 都是**真阻断**（ubuntu runner，全绿）。
- 本 fork 的版本：`pubspec.yaml` `version: 1.0.0-preview.2+2`；发布 tag 与 pubspec 版本**没有自动关联**（tag 是手工/推送触发）。

### 1.6 失败测试的文件级分布（96 个，供第 5 节分类）

| 文件 | 失败数 | 文件 | 失败数 |
|---|---|---|---|
| run_controls_test.dart | 16 | project_storage_test.dart | 4 |
| editor_page_test.dart | 15 | android_build_wrapper_test.dart | 3 |
| device_connection_test.dart | 11 | web_preview_test.dart | 3 |
| device_connect_page_test.dart | 11 | catalog_install_test.dart | 2 |
| project_files_test.dart | 9 | git_repo_test.dart | 2 |
| settings_pages_test.dart | 6 | project_actions_test.dart | 2 |
| environment_controller_test.dart | 5 | appearance_preferences / auto_connect / github_mirror / git_panel / project_git / setup_runner / terminal_log | 各 1 |

异常类型分布：`TestFailure` 28、`assert` 14、`StateError` 12、`_TypeError` 3。

---

## 2. windows/ 与 web/ 平台目录：缺口与取舍

### 2.1 windows/ 缺口（当前完全没有）

| 需要的东西 | 现状 | 缺 / 该改什么 | 级别 |
|---|---|---|---|
| CMake / runner 骨架 | 无 `windows/`，CI 每次 `flutter create` 生成 | 直接提交模板产物（见 1.3 清单） | P0（发布可复现性） |
| 窗口标题 | 模板 `main.cpp` 里 `window.Create(L"flit", ...)` → 任务栏/标题栏显示小写 `flit` | 改 `windows/runner/main.cpp` 为 `L"Flit"` | P1 |
| 默认窗口尺寸 | 模板固定 `Size(1280, 720)` | 改成 1280×800 或按 DPI 缩放；配合 window_manager 记忆 | P1 |
| 最小窗口尺寸 | 无（`win32_window.cpp` 未处理 `WM_GETMINMAXINFO`） | 在 `windows/runner/win32_window.cpp` 处理 `WM_GETMINMAXINFO`，最小 960×640；或引入 `window_manager` 的 `setMinimumSize` | P0（当前可拖到 200px 宽，整个 UI 崩） |
| 图标 | 模板是 Flutter 蓝白 logo `windows/runner/resources/app_icon.ico` | 用 `assets/branding/icon.svg` 生成多尺寸 `.ico` 覆盖（README 已有品牌资产） | P1 |
| 产品名/公司名/版本资源 | 模板 `Runner.rc`：CompanyName=组织名、ProductName/FileDescription=`flit`、FileVersion 硬编码 | 改 `windows/runner/Runner.rc`：`CompanyName "seek888"`、`ProductName "Flit"`、`FileDescription "Flit"`、`FileVersion` 与 `pubspec version` 对齐（可用 CI 传 `-D` 或脚本改写） | P1 |
| DPI | 模板 `runner.exe.manifest` 已含 `PerMonitorV2` + `dpiAware true/pm`，Flutter 引擎自带 DPI 处理 | 保持；补充回归验证（125%/150% 缩放下截图） | P2 |
| MSIX 配置 | 无（未用 `msix` 包） | 见 §3.3：**不推荐**默认走 MSIX | P2 |
| `windows/.gitignore` | CI 生成 | 模板内容（忽略 `/flutter/ephemeral/`、`build/`）；提交它可避免运行时产物入库 | P1 |

### 2.2 提交进仓库 vs CI 生成：取舍与推荐

| 维度 | 提交 windows/（推荐） | CI 每次生成（现状） |
|---|---|---|
| 可复现性 | 高：runner 即代码，改动可 review、可回滚 | 低：Flutter 升级会静默换模板（当前 stable 每次 CI 都可能不同） |
| 可定制 | 标题/图标/版本资源/最小尺寸/DPI 都能改 | 改不了（每次被模板覆盖） |
| CI 时间 | 省掉 2s（小事） | 多一步、多 21 个文件噪音（含 `.idea/`） |
| 用户本地构建 | `flutter build windows` 直接可用 | 用户得先 `flutter create`，文档难写 |
| 风险 | 模板升级需人工同步（可接受，一年几次） | `flutter create` 在已有仓库上跑有覆盖/漂移风险，无 diff 检查 |

**推荐：提交 `windows/`（14 个文件）+ 更新 `.metadata` 加 `windows` 平台条目；CI 删除 `Generate Windows runner` step，改为（可选）一次 `flutter create --platforms=windows .` 后 `git status --porcelain` 必须为空的一致性校验 job。**

### 2.2.1 模板占位符（已从 flutter/flutter 3.47.8 源码实证）

`packages/flutter_tools/templates/app/windows.tmpl/` 的实际文件与变量：

| 模板文件 | 关键内容（占位符） |
|---|---|
| `CMakeLists.txt.tmpl` | `project({{projectName}} LANGUAGES CXX)`、`set(BINARY_NAME "{{projectName}}")` |
| `runner/main.cpp.tmpl` | `window.Create(L"{{projectName}}", origin, size)` —— **窗口标题就是 projectName**，所以现在是 `flit` |
| `runner/Runner.rc.tmpl` | `CompanyName "{{organization}}"`、`FileDescription/InternalName/ProductName "{{projectName}}"`、`OriginalFilename "{{projectName}}.exe"`、`FileVersion/ProductVersion VERSION_AS_STRING`、`LegalCopyright "Copyright (C) {{year}} {{organization}}..."` |
| `runner/{CMakeLists.txt,flutter_window.cpp/h,resource.h,utils.cpp/h,win32_window.cpp/h,runner.exe.manifest,resources/, .gitignore}` | 其余文件无占位符（`resources/` 里是 `app_icon.ico`） |

→ 生成时占位替换为：`{{projectName}}→flit`、`{{organization}}→cc.lycstar`、`{{year}}→2026`；**注意 `projectName` 同时决定窗口标题、exe 名、内部名**，所以「让窗口显示 Flit」必须**额外改 `main.cpp`**（把 `L"flit"` 改成 `L"Flit"`），只改 projectName 会把 exe 名也改掉。

### 2.3 web/ 目录：**对 Flit 本身而言「缺失是对的」**

关键事实：**Flit 不可能编译成 Web 应用**，因为：
- `lib/services/shell.dart`、`desktop_shell.dart`、`app_releases.dart` 直接用 `dart:io`（`Platform`、`Process`、`HttpClient`、`File`）；
- `pubspec.yaml` 依赖 `flutter_pty`（原生）、`webview_flutter`（无 web 实现需求：web 构建会因 `dart:io` 直接失败）、`permission_handler`；
- 平台插件 `flit_env`/`flit_device`/`flit_files` 是 Android 原生。

→ **不要给 Flit 加 `web/`**，也不要加「构建 Flit 自身为 Web」的 CI step（会永远红）。任务里「web 产物」指的是**用户在 Flit 里构建自己的 Flutter 工程**，链路见 §3。

**用户工程要 `flutter build web` 需要什么**：工程根必须有 `web/index.html`（必需，缺了直接报 "This application is not configured to build on the web"），`web/manifest.json`、`web/favicon.png`、`web/icons/Icon-{192,512}.png`、`Icon-maskable-{192,512}.png` 为模板附带（缺失不阻断，但 manifest/icons 缺了 PWA 不完整）。生成方式：`flutter create --platforms=web .`（在工程目录内）。
Flutter 3.47.8 的 web 模板文件（已实证）：`packages/flutter_tools/templates/app/web/{index.html.tmpl, manifest.json.tmpl, favicon.png.copy.tmpl, icons/Icon-192.png.copy.tmpl, icons/Icon-512.png.copy.tmpl, icons/Icon-maskable-192.png.img.tmpl, icons/Icon-maskable-512.png.img.tmpl}` → 产出 `web/index.html`、`web/manifest.json`、`web/favicon.png`、`web/icons/*.png` 共 6 个文件。
**Flit 现状**：`lib/features/run/web_runner.dart:87` 已经在「运行预览」时补这一步，但用的是 **POSIX shell 语法**（`if [ ! -d web ]; then ...`）→ 在 Windows 的 cmd.exe 下必然失败（见 §4.1 P0-2）。而**构建**那条（`ProjectBuild.web`）完全没有补 `web/` 的逻辑（见 §3.2）。

---

## 3. 「打包出 Android / Web」现状与方案

### 3.1 APK 构建链：现状（Windows 上必挂）

入口与命令全部在 `lib/features/workspace/project_actions.dart`：

| 构建项 | 行号 | 命令 | 产物路径 |
|---|---|---|---|
| Debug APK | `project_actions.dart:14-22`（命令 :19，产物 :20） | `bash "$HOME/.flit/scripts/android_build.sh" flutter build apk --debug --target-platform android-arm64 2>&1` | `build/app/outputs/flutter-apk/app-debug.apk` |
| Release APK | `project_actions.dart:23-31`（命令 :28，产物 :29） | `... flutter build apk --release --target-platform android-arm64 2>&1` | `build/app/outputs/flutter-apk/app-release.apk` |
| Web Release | `project_actions.dart:32-38`（命令 :36） | `flutter build web --release 2>&1` | **无 artifactPath**（= `build/web`，见 §3.2） |

**Windows 上为什么必挂（三条独立的墙）**：

1. **`AndroidBuildWrapper` 在桌面也被无条件创建**：`lib/features/workspace/project_session.dart:53-55` → `android: _androidWrapper?.call(executions) ?? AndroidBuildWrapper(executions: executions)`。`ProjectActions.build()` 在 `android != null && confirmRepair != null` 时走 `android.start(...)`（`project_actions.dart:305-327`），而编辑器**总是**传 `_confirmRepair`（`editor_run_controls.dart:55`、`:365`、`:376`）。
2. `AndroidBuildWrapper.start()` 第一步就做基线检查：`android_build_wrapper.dart:93-94` → `_check(...)`（`:174-220`）→ `_probe('bash "$HOME/.flit/scripts/android_components.sh" --baseline ...')`（**`:185`**）。`_probe` 默认是 `Shell.instance.exec`（`:56`）→ 桌面走 `DesktopShell.exec` → Windows 执行 `cmd.exe /c bash "$HOME/.flit/scripts/android_components.sh" ...`。机器上没有 bash（有 WSL 也没有这些脚本），退出码非 0 → **`_check` 直接 `throw StateError(...)`（`:186-193`）**，构建在启动前就被拦掉。修复入口（`_installCommand`/`SetupRunner.installCommand`，`:320-336`）同样是 bash 脚本。
3. 即使绕过 1/2，命令里的 `bash "...android_build.sh"` 与 `$HOME` 在 Windows 也不存在。**唯一的缓冲层**是 `lib/features/terminal/console_session.dart:115-152` 的 `_normalizeForDesktop`：它会剥掉 `bash ".../android_build.sh" ` 前缀（`:128`）并把 POSIX 单引号换成 cmd 双引号（`:117-122`）；也就是说 **Flutter 真正的 `flutter build apk` 命令本身在 Windows 上是可以跑的**（`flutter.bat` 在 `DesktopToolchain.childEnvironment` 的 PATH 里，`desktop_toolchain.dart:63-81`），只是被 1/2 提前拦住了。

→ **P0 修法（最小改动，两条）**：
- a) 桌面平台不创建/不启用 `AndroidBuildWrapper`：`project_session.dart:53-55` 改为 `isDesktopPlatform ? null : AndroidBuildWrapper(...)`；`project_actions.dart:309` 已有 `android == null` 短路分支，构建会直接 `start(configuration)`，命令经 `_normalizeForDesktop` 剥壳后在 cmd 里执行；`editor_run_controls` 的 `confirmRepair` 在桌面传 `null`。
- b) 保留「缺组件」体验：桌面用 `DesktopToolchain.status()`（`desktop_toolchain.dart:85-104`）做前置判断，缺 SDK/JDK 时导向环境页，而不是跑 bash 脚本。
- 或者 c) 在 `AndroidBuildWrapper` 内部加 `isDesktopPlatform` 分支，`_check` 改调 `DesktopToolchain.status()`。

### 3.2 Web 构建链：现状与缺口

- 命令存在（`project_actions.dart:36`），UI 入口也存在（§3.3），**但没有产物识别、没有 web/ 引导、没有导出**：
  - `ProjectBuild.web` 的 `RunConfiguration` **没有 `artifactPath`**（`:32-38` 对比 APK 的 `:20`/`:29`）。`ProjectActions._artifacts` 只在 `artifact != null` 时才推产物（`:199-208`），所以 **Web 构建成功 = 用户什么都没看到**，只能自己翻终端日志。
  - 用户工程若没有 `web/`，`flutter build web --release` 直接失败（Flutter 要求 `web/index.html` 存在）；而 run 路径里的补建逻辑（`web_runner.dart:87`）是 POSIX shell，Windows 上用不了、构建路径也没接。
- **P0/P1 修法**：
  1. `ProjectBuild.web` 增加 `artifactPath: 'build/web'`（目录型产物），并让产物卡片支持「目录」→ 显示文件数/总大小 + 「打开文件夹」。
  2. 构建前在 Dart 侧判断 `Directory('$projectPath/web').exists()`，不存在则先执行 `flutter create --platforms=web .`（用 Dart 判断 + 命令，不依赖 shell 语法）；更稳的做法是给 `ProjectBuild.web` 的配置加 `prelude`/`bootstrap` 字段，由 `ProjectActions._start` 在启动前同步做（不要塞进 cmd 命令串）。
  3. `web_runner.dart:87` 的 `if [ ! -d web ]` 改为 Dart 判断（跨平台），否则 Windows 的 Web 预览也起不来。

### 3.3 构建 UI 入口（现有页面/按钮 + 需要加什么）

**现状（已有入口，别重复造）**：
- 入口在**编辑器页顶栏的「运行控制」按钮 → 弹出的「任务」底部面板**：`lib/features/editor/widgets/editor_run_controls.dart`，`_tasksSheet()`（`:268-...`）里的「构建」分区 `:351-400`：
  - `:355-367` 构建 APK（调试版）→ `ProjectBuild.debugApk` + `_confirmRepair`
  - `:368-378` 构建 APK（发布版）→ `ProjectBuild.releaseApk` + `_confirmRepair`
  - `:379-386` 构建 Web（发布版）→ `ProjectBuild.web`（副标题 `strings.outputDirectoryBuildWeb` = 「产物目录 build/web」）
- 平台限定：只有 Flutter 工程显示这三项（`:353`），Dart 工程显示 `dart compile exe`。
- 因为它是 `showModalBottomSheet`（手机s 的底部抽屉），**桌面上的形态不合适**（P1，见 §4）。

**需要的改动**：
1. **保留现有三个按钮**，但桌面把 `_tasksSheet` 从底部弹出改为**右侧面板/弹出菜单**（桌面 UX），或至少 `constraints: BoxConstraints(maxWidth: 480)` 居中。
2. **加「产物」体验**（P0，缺了用户等于没拿到产物）：
   - APK 构建成功后已有的产物卡片链路：`ProjectActions._artifacts`（`:136-137`、`:199-208`）→ 订阅方把产物开成 `FileCard` tab。但 `FileCard` 的按钮是 Android 专属：安装到本机 `FlitFiles.installApk`、分享 `FlitFiles.share`、外部打开 `FlitFiles.open`（`lib/features/editor/widgets/file_card.dart:161-193`）→ Windows 上 `flit_files` 没有插件实现，三键全挂。**需要加桌面分支：`打开文件夹`（`Shell.revealDirectory`，已实现但全仓库无人调用，`lib/services/shell.dart:93`、`desktop_shell.dart:176`）+ `另存为…`（原生对话框）。**
   - Web 产物同样进产物卡片（目录型），按钮：`打开文件夹` / `在浏览器中打开 index.html` / `另存为 zip`。
3. **导出目录/路径约定（建议）**：
   - 构建产物保留在工程内标准位置（`build/app/outputs/flutter-apk/*.apk`、`build/web/`），**只读展示**；
   - 「导出」默认落 `%LOCALAPPDATA%\FlitDesk\exports\<项目名>\`（与 `DesktopToolchain.home` 同根，`desktop_toolchain.dart:22-32` 已有 `home`），文件名带版本+时间戳；用户可通过「另存为」改目录。
   - 不引入新的 `downloads` 目录概念，避免和 Android 的私有大目录混用。
4. **文案（l10n）改动点**：`lib/l10n/app_zh.arb` / `app_en.arb`（模板是 zh，生成到 `lib/l10n/app_localizations*.dart`，`l10n.yaml`）。需新增键（名字建议）：
   - `buildWebReleaseDone`「Web 构建完成：build/web（N 个文件）」
   - `openBuildOutputFolder`「打开产物文件夹」
   - `exportBuildOutput`「导出产物…」/`exportDoneP`
   - `webOutputNotBrowserOpenable`（可选）
   - `desktopBuildUnsupportedNoBash`（迁移期兜底文案）
   - 现有 `outputDirectoryBuildWeb`、`buildApkDebug/Release`、`buildWebRelease` 保留复用。

### 3.4 Android 构建产物安装/导出在 Windows 上的替代

- Android 侧「构建完 → 安装到设备」是 `FlitFiles.installApk`（`file_card.dart:165`）走 SAF/Intent；Windows 上应改为 **`adb install -r <apk>`**（`DesktopToolchain.adbExe` 已存在，`desktop_toolchain.dart:54`，`adb_ops.dart` 已有设备能力，属 task-2 范围）+ 「打开文件夹」。
- 「导出」= 复制到用户选择目录（原生 save dialog）。

---

## 4. 桌面外壳与 UX 适配（P0/P1/P2 + 文件:行号）

### 4.1 P0（不修则不能用 / 会崩）

| # | 问题 | 位置 | 建议改法 |
|---|---|---|---|
| P0-1 | APK 构建被 `AndroidBuildWrapper` 的 bash 前置检查拦住 | `project_session.dart:53-55`、`android_build_wrapper.dart:185-193`、`editor_run_controls.dart:55/365/376` | 桌面跳过 wrapper（见 §3.1 a/b/c） |
| P0-2 | Web 预览/构建用 POSIX shell 语法补 `web/`，Windows cmd 必失败 | `web_runner.dart:87`、`project_actions.dart:36` | 改 Dart 侧判断 + `flutter create --platforms=web .`，构建路径同样补 |
| P0-3 | 窗口可被拖到极小，布局崩（无最小尺寸、无尺寸记忆） | 无 `windows/`；`pubspec.yaml` 无 `window_manager` | 提交 `windows/` 并在 `win32_window.cpp` 处理 `WM_GETMINMAXINFO`（960×640），或用 `window_manager` 包 |
| P0-4 | 构建产物无法拿到（APK 三个按钮是 Android 插件；Web 无产物） | `file_card.dart:161-193`、`project_actions.dart:32-38` | 桌面分支：打开文件夹 + 另存为；Web 补 artifactPath |
| P0-5 | `flutter build windows` 依赖的 `windows/` 不在仓库，用户本地无法构建 | 仓库根 | 提交 `windows/`（§2.2） |

### 4.2 P1（体验明显不对，交付前应做）

| # | 问题 | 位置 | 建议 |
|---|---|---|---|
| P1-1 | 无菜单栏、无全局快捷键（只有补全弹窗的 Esc/Tab/↑↓） | `lib/features/editor/widgets/editor_surface.dart:170-196` 是唯一键盘处理；全仓库无 `Shortcuts`/`Actions`/`MenuBar`（grep 为 0） | 在 `lib/app.dart`（`MaterialApp.builder`）挂 `Shortcuts`+`Actions`：Ctrl+S 保存、Ctrl+W 关 tab、Ctrl+, 设置、F5 运行、Ctrl+Shift+B 构建面板、Ctrl+Shift+P 命令面板（P2）；再加 Windows `MenuBar`（文件/编辑/构建/帮助） |
| P1-2 | 文件树/版本控制仍是手机 `Drawer`（1280 宽屏下点汉堡弹出抽屉，遮住一半） | `editor_page.dart:579-670`（`_drawer()`）、领先菜单按钮 `:394-415` | 宽度 ≥1000 时改为永久左侧栏 `Row(FileTree|GitPanel, editor)`；<1000 才用 Drawer |
| P1-3 | 文件选择全部是 Android 权限/SAF，没有桌面原生 picker | `lib/services/shared_storage_access.dart`（`permission_handler`）；工程固定在 `DesktopToolchain.projectsDir` | 加 `file_selector`（官方，Windows 原生）或 `file_picker`：① 导入已有工程目录 ② 导出产物「另存为」；`SharedStorageAccess` 在桌面直接返回 true |
| P1-4 | 后台权限对话框（前台服务/电池优化）在 Windows 弹出且无意义 | `workbench_page.dart:50` 调 `BackgroundAccess.explain`；`background_access.dart:98-160` | 桌面跳过；文案/按钮不留 Android 语汇 |
| P1-5 | 窗口标题 `flit`（小写） | 模板 `windows/runner/main.cpp` | 改 `L"Flit"`；同时 `app.dart:53` 的 `title:'Flit'` 只影响任务栏提示，不是窗口标题 |
| P1-6 | 截图/产品信息：图标仍 Flutter logo，`Runner.rc` 版本/公司/产品名是模板值 | `windows/runner/resources/app_icon.ico`、`Runner.rc` | 用 `assets/branding/icon.svg` 生成 ico；`Runner.rc` 对齐 `pubspec version` |
| P1-7 | 桌面上「任务」面板是底部抽屉 | `editor_run_controls.dart:268-...`（`showModalBottomSheet`） | 桌面改右侧面板/弹出菜单（放大到 480 宽、居中或用 `showDialog`） |
| P1-8 | 发布/更新链路对 Windows 无效（见 §5） | `app_releases.dart:13-22/63-71/157`、`app_versions_page.dart:87-95` | 资产命名带版本+sha、`FLIT_APP_REPO` 改 fork、非 APK 走「下载+打开文件夹」 |

### 4.3 P2（打磨）

| # | 问题 | 位置 | 建议 |
|---|---|---|---|
| P2-1 | 双指缩放仅支持 touch，桌面鼠标无法缩放编辑器/终端字号 | `lib/core/pinch_zoom.dart:49`（`supportedDevices: {PointerDeviceKind.touch}`）；`editor_surface.dart:245`、`global_terminal_panel.dart:379` 使用 | 桌面加 `Ctrl+滚轮`（`Listener.onPointerSignal` + `PointerScrollEvent`，判断 `HardwareKeyboard` ctrl）映射到 `AppearancePreferences.editorSize/terminalSize`；同步改设置页提示文案 `settings_page.dart:224`（`pinchToZoomFontSizeMonospaceFont`） |
| P2-2 | 无鼠标 hover 反馈（只有一处注释说移动端没有 hover） | `code_field.dart:396`；树行/工具条无 `MouseRegion`/hover 高亮 | 文件树行、dock 工具条、会话 chip 加 hover 底色 + `Tooltip` |
| P2-3 | 无滚动条定制 / 无鼠标拖动滚动 | 全仓库 grep 无 `ScrollBehavior`/`dragDevices` | `ScrollConfiguration` + 桌面 `dragDevices` 含 mouse/trackpad；长行横向滚动（`editorWrap=false`）可用 Shift+滚轮 |
| P2-4 | 断点常量是死代码（`windowSizeOf` 无人调用），各页面用内联阈值 | `core/breakpoints.dart:7-12` vs `workspace_views.dart:22`（≥840）、`environment_page.dart:123`（≥840）、`code_field.dart:639`（≥600） | 统一用 `windowSizeOf`，并新增 `desktop` 档（≥1200）驱动 P1-2 |
| P2-5 | 表单/列表最大宽度 800，宽屏两侧空白大 | `core/page_layout.dart:16` | 桌面提到 1000–1200（`PageContent` 加可选 `maxWidth`） |
| P2-6 | `SystemChrome.setEnabledSystemUIMode/OverlayStyle` 桌面无意义 | `main.dart:66-75` | `if (!isDesktopPlatform)` 包裹 |
| P2-7 | 无窗口位置/大小/最大化记忆 | 无 | `window_manager` + `AppearancePreferences`（`appearance_preferences.dart` 已有 `$home/.flit/appearance.json` 持久化模式，注意 Windows 下 `home` 是 `DesktopToolchain.home`） |
| P2-8 | 返回栈语义：桌面 `Esc` 无「返回」，`PopScope` 只处理保存 | `editor_page.dart:387`、`environment_page.dart:53` | 桌面 Esc = 关闭当前面板/对话框；Android 返回键逻辑保持不动 |
| P2-9 | 字体：代码用 bundled JetBrainsMono（OK），中文界面走系统字体（Windows 默认 Microsoft YaHei，可接受） | `pubspec.yaml` fonts、`theme.dart` | 若强调一致性可内嵌 Noto Sans SC（体积 +8MB，暂不建议） |

### 4.4 桌面外壳关键事实（供实现参考）

- **没有** `window_manager`/`bitsdojo_window`/`window_size` 等桌面窗口依赖（`pubspec.yaml` 全文无）→ 窗口尺寸/最小尺寸/标题/置顶/记忆**全部没有**。
- `material.dart` 默认在桌面给可滚动组件加 `Scrollbar`（框架行为），但本仓库没有覆盖 `ScrollBehavior`，也没有显式 hover 态。
- 没有多窗口概念（单 Activity/单窗口架构），`Navigator` 栈即页面栈；Android 的 `PopScope`/返回键在桌面没有对应输入，需要 Esc。
- 桌面进程能力已有一层不错的抽象：`DesktopShell`（326 行）+ `DesktopToolchain`（485 行）+ `LocalFs`（265 行），且 `shell.dart:19` 的 `isDesktopPlatform => !Platform.isAndroid` 已把大量 Android 分支隔开——**外壳工作应复用这两层，不要再写平台判断散落各页**。

---

## 5. 打包/发布方案

### 5.1 安装包形态取舍

现状：**zip 便携包**（`flit-windows-x64.zip`，14.5MB，解压跑 `flit.exe`），每次 CI 发一个 `windows-preview-<run_number>` 的 prerelease。

| 形态 | 用户拿到后 | 优点 | 缺点 | 结论 |
|---|---|---|---|---|
| **zip 便携包** | 解压 → 双击 `flit.exe` | 零签名、零安装、CI 最简单、体积最小 | 无开始菜单/卸载/文件关联；SmartScreen 对 exe 首次运行仍可能提示；用户不知道放哪 | **保留为「便携版」**（P0 已有） |
| **Inno Setup**（推荐做「安装包」） | 下载 `FlitSetup-<ver>.exe` → 下一步 | 免费、脚本简单（.iss）、**per-user 安装无需管理员**（装 `%LOCALAPPDATA%\Programs\Flit`）、开始菜单+卸载项、可选桌面快捷方式；**不需要代码签名也能装**（只有 SmartScreen 警告） | 需要 CI 装 Inno（`choco install innosetup -y`，约 10s）；未签名会有「未知发布者」提示 | **推荐：P1 产出 Setup.exe**，与 zip 并存 |
| **MSIX** | 下载 `.msix` → 双击 | 现代、可增量更新、可上 Store | **未签名 MSIX 无法安装**；自签名需用户把证书装进「受信任的根证书颁发机构」或开开发者模式（普通用户直接劝退）；需要 `msix` pub 包 + `msix_config`（含 identity/publisher/capabilities）；还要处理 `flutter build windows` 产物打包与 VC++ 运行库 | **P2，仅当要上 Store 或企业分发时做**；签名证书（EV/OV）成本高 |
| **NSIS** | 下载 `.exe` → 下一步 | 成熟、体积小 | 脚本比 Inno 啰嗦（Section/宏），Unicode/中文语言包要额外配 | 备选，不推荐首选 |

**给普通用户的「安装包」结论**：第一阶段 zip（已有）+ 第二阶段 **Inno Setup per-user Setup.exe**；MSIX 只在有代码签名证书后考虑。

**VC++ 运行库的处理要改（P1）**：当前 CI 从 `C:\Windows\System32` 复制 4 个 DLL 进包（`windows-build.yml` 的 "Bundle VC++ runtime DLLs"）。这**不是**推荐的再分发方式（System32 里的版本可能与 redist 许可/版本不匹配）。建议二选一：
- a) Inno Setup 里用官方 `VC_redist.x64.exe` 作为 `[Run]` 预安装（或检测已装则跳过）；
- b) 只在便携 zip 里保留现有 4 个 DLL，并注明「已内置运行库，若报缺少 DLL 请安装 VC++ 2015-2022 Redistributable」。

### 5.2 CI 如何产出（具体步骤建议）

在 `windows-build.yml`（或拆一个 `windows-release.yml`）：

1. 删除 `Generate Windows runner`（`windows/` 已入库）；加一致性 job（可选）：`flutter create --platforms=windows .` 后 `git diff --exit-code -- windows/ || fail`。
2. `flutter build windows --release`（不变），产物 `build/windows/x64/runner/Release/`。
3. **打包 zip**（不变）：`Compress-Archive` → `flit-windows-x64.zip`。
4. **（新增，P1）Inno Setup**：`choco install innosetup -y` → `iscc windows/installer/flit.iss /DAppVersion=$version` → `FlitSetup-<ver>-x64.exe`。
5. **（新增，P1）产物命名带版本+sha**：`flit-windows-x64-<version>-<sha7>.zip`，`FlitSetup-<version>-<sha7>.exe` —— 理由见 §5.3（更新检查靠资产名匹配）。
6. **（新增，P1）APK 冒烟 job**：在 windows-latest 上 `actions/setup-java@v4`（temurin 17）+ `android-actions/setup-android`，然后对**一个最小 sample Flutter 工程**跑 `flutter build apk --debug`，验证「Windows 上能出 APK」这条链路（Flit 自己不能作为被测工程，因为它不是普通 app）。**先非阻断**，跑绿后再阻断。
7. **（新增，P1）Web 冒烟**：同一个 sample 工程 `flutter create --platforms=web .` + `flutter build web --release`，证明 Windows 上的 `flutter build web` 可用（这条与 Flit 内部 Web 构建命令同构）。
8. **（可选）** 用 `actions/upload-artifact` 保留 `analyze.log`/`test.log`（已有）。

### 5.3 Release 命名/版本策略（现状问题 + 建议）

现状问题（都可验证）：
- `app_releases.dart:13-16`：`defaultRepo = String.fromEnvironment('FLIT_APP_REPO', defaultValue: 'lycstar/flit')` → **fork 构建默认查上游仓库**，看不到 `seek888` 的 Release。
- `app_releases.dart:19-22`：`buildSha` 来自 `--dart-define=BUILD_SHA`；`android-release.yml` 传了，**`windows-build.yml` 没传** → Windows 构建永远 `development`。
- `app_releases.dart:63-71`：`matchesBuild` 要求资产名包含 `-<sha7>.`；Windows zip 名 `flit-windows-x64.zip` **永远不匹配** → 「当前构建是否已发布」永远 false。
- `app_releases.dart:157`：`isApk` 决定「可安装」；zip/exe 只能下载，`app_versions_page.dart:87-95` 非 APK 走 `FlitFiles.share`（Android 插件）→ **Windows 上下载完后「分享/安装」必挂**。
- Tag 规则割裂：Android 用 `v1.0.0-fork.1`（语义版本+后缀，`validate` 正则 `^v[0-9]+[A-Za-z0-9.-]*$`），Windows 用 `windows-preview-<run_number>`（run 号，无法排序/无法对应 pubspec 版本）。

建议（渐进）：
- **短期（预览期）**：Windows 保留独立 preview 通道，但 tag 改成可排序的 `v<pubspecVersion>-win.N`（如 `v1.0.0-preview.2-win.19`），资产名 `flit-windows-x64-1.0.0-preview.2-<sha7>.zip`。
- **中期（正式版）**：**一个 tag 同时挂 APK + Windows 资产**（`v1.1.0`：`flit-v1.1.0-<sha7>.apk` + `FlitSetup-1.1.0-<sha7>.exe` + 便携 zip），与 `pubspec.version` 严格对应（CI 校验 `pubspec version` 前缀 == tag）；`windows-build` 与 `android-release` 都传 `--dart-define=BUILD_SHA=${{ github.sha }}` 和 `--dart-define=FLIT_APP_REPO=seek888/flit`。
- `app_releases.dart` 扩 `AppAsset`：加 `isWindows`，按平台选「可安装」分支；Windows「安装」= 下载 Setup.exe → `Shell.openUrl`/直接 `Process.start` 运行，或下载 zip → 解压到 `%LOCALAPPDATA%`。
- 「检查更新」页在 Windows 上至少要做到：下载 + 打开文件夹（`revealDirectory`），不要求自动替换（P2 再做自更新）。

---

## 6. 测试与 CI 阻断策略

### 6.1 Windows 上失败的根因分类（96 个）

| 类别 | 代表文件 | 证据（CI 日志原文/代码） | 性质 |
|---|---|---|---|
| **F. 桌面路由绕过测试替身（最大类，先修这个）** | 17 个测试文件 mock 了 `flit/env` 通道：`appearance_preferences / auto_connect / device_connect_page / device_connection / editor_page / environment_controller / git_panel / localization / project_files / project_storage / run_controls / settings_pages / setup_runner / terminal_appearance / terminal_interaction / terminal_log / widget_test` | Windows 上 `isDesktopPlatform == true`（`lib/services/shell.dart:19`），`Shell.instance.*` 全部改走 `DesktopShell`（`:27-95`），**`flit/env` 的 mock handler 根本不会被调用** → 测试里读到的是真实 `cmd.exe` 输出/真实 `DesktopToolchain.home`。典型表现：`Expected '127.0.0.1:43210' / Actual ''`（run_controls）、`Found 0 widgets with type CodeField`（editor_page）、`PathNotFoundException ... /.flit/appearance.json`（appearance_preferences，因为 home 变成 `%LOCALAPPDATA%\FlitDesk` 且目录不存在） | **测试架构问题**（也顺带暴露真 bug）：进程边界缺测试 seam |
| A. 依赖 POSIX/bash/WSL | `git_repo_test`(2)、`setup_runner_test`(1)、`catalog_install_test`(2)、`android_build_wrapper_test`(3)、`environment_controller_test`(5) | 这些测试直接 `Process.run('bash', ...)`（`git_repo_test.dart:6-7`、`catalog_install_test.dart:31-32/65-66/73-74`、`setup_runner_test.dart:32-33`）；windows-latest 上裸 `bash` 解析到 `C:\Windows\System32\bash.exe`（WSL 启动器）→ 输出 UTF-16 的 `Windows Subsystem for Linux has no installed distributions`；另有 `Expected ... '28.2.13676358'` vs `"..."`（Windows 引号形式） | 测试/应用都假设 bash |
| B. Android 专属插件通道 | `device_connection_test`(11)、`device_connect_page_test`(11)、部分 `run_controls_test` | `Actual: '无法确认连接状态，请先安装 ADB'`、`Found 0 widgets with text "本机 · Phone"`（`hasBinary('adb')` 在 runner 上为 false，`desktop_shell.dart:61-95`） | 测试环境（无 native 插件）+ 桌面本就需要改 ADB 路径 |
| C. 路径分隔符 `/` 硬编码 | `project_files_test`(9)、`project_storage_test`(4)、`editor_page_test`(15) 部分 | `Bad state: 只能在当前项目目录中创建文件或目录`；`Found 0 widgets with type CodeField` | **真实 Windows bug**：`project_files.dart:59`（`'$root/'`）、`:65`（`path.substring(0, path.lastIndexOf('/'))`）、`project_session.dart:34`（`path.split('/').last` 取工程名） |
| D. 文件/目录不存在（未 `create(recursive)`） | `appearance_preferences_test`(1) | `PathNotFoundException ... Temp/flit-preferences-xxx/.flit/appearance.json` | 测试辅助 + 可能真实 bug（`appearance_preferences.dart:42-44` 只拼路径不建目录） |
| E. 异步/时序/渲染差异 | `settings_pages_test`(6)、`web_preview_test`(3)、`run_controls_test`(16) | `pumpAndSettle timed out`、`StateError: No element`（`web_preview_test.dart:104/153/213`） | 测试对平台时序敏感；`web_preview_test` 断言 Android WebView（Windows 走 `_DesktopPreviewFallback`，`web_run_page.dart:78-85`），**这类测试在 Windows 上应跳过或改为断言 fallback** |

### 6.2 建议的阻断层级（不破坏 Android）

| 层级 | Windows Build job | Android Release job |
|---|---|---|
| `flutter analyze` | **改为阻断**（实测 0 issue，安全） | 保持阻断（现状） |
| Windows 安全测试子集 | **改为阻断**（见下表） | 不适用 |
| 全量 `flutter test` | 保持 `continue-on-error: true`，直至 96→0 | 保持阻断（现状） |
| `flutter analyze/test` 之外的构建 | `flutter build windows --release` **保持阻断** | APK 构建保持阻断 |

**Windows 上已经 100% 通过、可立即加入阻断的测试文件**（从 CI 日志统计，失败数 0）：

```
local_fs_test.dart (10)          editor_test.dart (16)            terminal_interaction_test.dart (14)
session_model_test.dart (13)     editor_features_test.dart (11)   toolchain_catalog_test.dart (11)
web_runner_test.dart (8)         lsp_client_test.dart (7)         toolchain_components_test.dart (7)
create_project_test.dart (6)     terminal_reflow_test.dart (6)    adb_ops_test.dart (5)
device_pairing_guide_test.dart (5)  file_kind_test.dart (5)       editor_tabs_test.dart (4)
environment_timeline_test.dart (4)  localization_test.dart (4)    project_list_test.dart (4)
editor_zoom_test.dart (3)        environment_status_test.dart (3) terminal_appearance_test.dart (3)
flutter_log_formatter_test.dart (2) github_mirror_test.dart (2)   installed_toolchains_test.dart (2)
markdown_preview_test.dart (2)   svg_preview_test.dart (2)        tool_mutex_test.dart (1)
widget_test.dart (1)
```

建议写成显式列表跑（和现在 `test/local_fs_test.dart` 一样的形态）：`flutter test <列表>`；**不要**用 `flutter test --exclude-tags` 这种全局开关（改 tag 会动到几百个测试）。

**修复路径（建议顺序）**：
1. **P0：给进程边界加测试 seam**（解决 F 类，约 60%+ 的失败）。`Shell.instance` / `DesktopShell.instance` 目前是硬编码单例（`shell.dart:20`、`desktop_shell.dart:19`）；测试里只能 mock MethodChannel。建议：把 `DesktopShell` 做成可注入（`Shell.instance` 改成可替换的 `Shell.test(...)`，或加 `@visibleForTesting static set instance`），并在 `test/support/` 加一个 `fakeDesktopShell`，让 `exec/bootstrapStatus/hasBinary/which/...` 走 fake。**只改测试注入点，不改生产行为**；Android 侧 `FlitEnv` 路径保持不变 → `android-release.yml` 完全不受影响。
2. 修 C/D 两类（真实 bug，量小收益大）：路径分隔符、工程名、prefs 目录创建 → 可让 `project_files_test`、`project_storage_test`、`editor_page_test` 大部分转绿；同时加 `test/desktop_paths_test.dart`。
3. 修 A 类：测试里的 `Process.run('bash', ...)` 改为「平台分支 + 用 `sh`/`cmd` 或直接 Dart 断言」（这三条测试本质是脚本行为验证，应改为平台无关的 fake）。应用侧把 Git/JDK/SDK 命令改为「Dart 侧拼装 + DesktopShell 执行」（与 task-1/task-2 重叠，需协调）。
4. B 类（设备/ADB 语义测试）：给 Windows 打 `@Tags(['android-only'])`；`flutter test --exclude-tags android-only` 跑 Windows 全量，Android Release 仍跑全量（**当前仓库没有任何 `@Tags`、也没有 `dart_test.yaml`**，这是新机制，需要先加 `dart_test.yaml` 并在 `android-release.yml` 里显式不加 exclude）。
5. E 类（渲染/时序）：`web_preview_test` 应断言「桌面降级面板」（`web_run_page.dart:78-85`）而不是 WebView；`settings_pages_test` 的 `pumpAndSettle` 超时需查真实异步源（多半是 F 类修好后自愈）。
6. 96→0 后，Windows 全量测试改为阻断。

### 6.3 建议新增的 Windows 专用单测

| 新测试 | 断言内容 |
|---|---|
| `test/desktop_paths_test.dart` | `ProjectFiles._relative`/`kindOf` 在 `\` 分隔符下的行为；`ProjectSession.name` 取目录名（当前 `project_session.dart:34` 用 `/` 会返回整条路径）；`ProjectFiles` 拒绝越界路径 |
| `test/build_commands_test.dart` | 桌面平台 `ProjectBuild.*.configuration.command` 不含 `bash`/`$HOME`/`.flit/scripts`；`web` 有 `artifactPath`；APK 产物路径常量正确 |
| `test/build_artifacts_test.dart` | 构建成功（code=0）才推产物；Web 目录产物被识别；失败不推 |
| `test/desktop_shell_test.dart` | `DesktopShell._posixShim` 的 `command -v`/`env -0`/`cat`/`find` 惯用法在 Windows 返回正确；`exec` 走 `cmd.exe /c` |
| `test/windows_runner_test.dart`（静态） | 提交后的 `windows/runner/main.cpp` 含 `L"Flit"`、`Runner.rc` 的 ProductName/版本与 `pubspec.yaml` 一致、`app_icon.ico` 存在（防止后续改动退化） |
| `test/app_assets_test.dart`（可选） | `web/` 相关产物路径常量与 l10n 键齐全 |

### 6.4 不破坏 Android Release 的硬约束

- **不要动** `assets/scripts/*.sh`（Android 环境安装靠它；task-1 会改，需独立 PR + Android 回归）。
- **不要动** `android/`（包名/签名/`build.gradle.kts` 回退逻辑）。
- `android-release.yml` 保持现状；Windows 的新校验全部放 `windows-build.yml`（或新 `windows-apk-smoke` job），**互不共享 step**。
- 两处 Flutter 版本要统一（`android-release.yml` 锁 3.47.8，`windows-build.yml` 用 stable=3.47.9）→ 建议都锁 3.47.8，避免「同一 commit 出两种产物」。

---

## 7. 文档任务（目录与小节标题，不写全文）

| 文件 | 动作 | 建议小节 |
|---|---|---|
| `README.md`（英文） | 改 | 顶部平台行加「Windows (preview)」；`## Features` 加 Windows 条目；`## Start using Flit` 拆 Android / Windows 两条；`## Build from source` 加 Windows 小节（`flutter config`、`flutter build windows --release`、VS Build Tools 前置）；`## Limitations` 加 Windows 限制（无 ADB 设备管理？无内嵌 WebView、需自装 VC++ 运行库） |
| `README.zh-CN.md` | 改（与上对应） | 「功能」「开始使用」「从源码构建」「使用限制」同步加中文 Windows 段落 |
| `docs/windows-port/README.md` | 新增 | 「Windows 移植总览」「当前状态（能做什么/不能做什么）」「文档索引」「测试与 CI 状态」 |
| `docs/windows-port/desktop-environment.md` | 新增（task-1 主写） | 「私有工具链目录（%LOCALAPPDATA%\\FlitDesk）」「JDK/SDK/Flutter/Git 安装顺序」「与 Android 环境页的差异」 |
| `docs/windows-port/build-and-package.md` | 新增 | 「构建 APK（命令/产物路径/ADB 安装）」「构建 Web（web/ 引导/build/web）」「产物导出与打开文件夹」「安装包：便携 zip / Inno Setup」「签名与 SmartScreen」 |
| `docs/windows-port/desktop-ux.md` | 新增 | 「窗口尺寸与最小尺寸」「菜单栏与快捷键」「宽屏布局（≥840/≥1200）」「文件对话框」「双指缩放→Ctrl+滚轮」「抽屉 vs 侧栏」 |
| `docs/windows-port/release.md` | 新增 | 「Tag 与版本策略」「Release 资产命名」「更新检查（app_releases）」「预览通道」 |
| `docs/windows-port/testing.md` | 新增 | 「CI 矩阵（windows-build / android-release）」「Windows 可阻断测试清单」「android-only 标签」「如何在本机复现」 |
| `docs/architecture.md` | 改 | `## 原生边界` 增加桌面映射：`FlitEnv→DesktopShell/DesktopToolchain`、`FlitFiles→系统对话框/explorer`、PTY `flutter_pty`（ConPTY） |
| `docs/runtime-environment.md` | 改 | 新增「Windows 桌面端工具链」一节（私有目录、下载源、与 bootstrap/APT 无关） |
| `CONTRIBUTING.md` | 改 | 新增「Windows 开发环境（Flutter 3.47.8 / VS 2022 Build Tools / JDK 17）」「CI：两个 workflow 的职责」 |
| `lib/l10n/app_zh.arb` + `app_en.arb` | 改 | 见 §3.3 键位；桌面专属文案不要复用 Android 语汇 |

---

## 8. 后续补证清单（写入报告后继续核对）

- [ ] Flutter 3.47.8 模板变量与文件清单（`windows.tmpl` / `web.tmpl`），用于 §2.2 的占位替换与 `.metadata` 建议。
- [ ] `Runner.rc` 模板的版本/公司字段真实占位符。
- [ ] `test/` 中 `@Tags`/`skip` 现状（是否已有平台跳过机制）。
- [ ] `editor_page` 订阅 `builtArtifacts` 的具体位置（确认产物卡片链路完整）。