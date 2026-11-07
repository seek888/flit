# 02 · Windows 功能层缺口分析（项目 / 编辑器 / 终端 / Git / GitHub / 设备 / 文件）

> 范围：`lib/features/projects|workspace|editor|terminal|git|run|device|settings`、`lib/services/*`、`plugins/*` 的 Dart API 与桌面替代。
> 基线：分支 `windows/full-desktop`，HEAD `b02a4cc`（= CI run 42348982433 的 sha）。
> 方法：静态精读 + grep + 读 pub 包源码 + 读 GitHub Actions 日志（`~/git-credentials` 的 token，未打印）。本机无 flutter/dart，**未编译、未运行**；所有"Windows 实际行为"来自源码路径推演 + CI 实测日志，标注了需要真机复核的点。
> 环境层（JDK/SDK/Flutter/Git 安装与就绪判定）见 `01-environment.md`；CI/打包/UX 见 `03-build-ci-ux.md`。本报告只做功能层，但会指出被环境层卡死的功能入口。
>
> 结论先行：**当前 Windows 版「能开窗、能显示项目列表以外的页面」，但「新建项目 → 编辑 → 终端 → Git → 推送」这条主链路有三处断点（环境就绪判定、PTY 默认 shell、Git 命令拼装），另有 6 处会直接把 Android 语义打到 Windows 上。** 已桌面化的部分（LocalFs、FileOps、DesktopShell 的大部分、环境状态、Web 预览降级）质量不错，问题集中在"命令字符串 + 插件通道 + 路径字符串"三类。

---

## 0. TL;DR（10 条）

1. **主链路第一断点：环境永远判不"就绪"**。`DesktopToolchain._canRun()`（`lib/services/desktop_toolchain.dart:106-120`）用 `runInShell: false` 直接跑 `flutter.bat`；Windows 的 `CreateProcess` 不能执行 `.bat`，异常被吞 → `status().flutter == false` → `EnvironmentController._desktopCheck()`（`lib/features/environment/environment_controller.dart:549-560`）把 `_checkFailed` 置真 → `allDone=false`（`:436-438`）→ `ProjectsPage` 永远停在"开发环境未就绪"（`lib/features/projects/projects_page.dart:400-425`），**创建/克隆按钮不可用**（`:340-346`）。修法一行：`.bat/.cmd` 走 `cmd /c` 或 `runInShell:true`。详见 §3-P0-1。
2. **主链路第二断点：默认交互终端启动不了**。`PtySession._ensure()`（`lib/features/terminal/pty_session.dart:22-25`）用 `File('$prefix/bin/bash').existsSync()` 当门禁；桌面 `prefix = DesktopToolchain.home`，Windows 没有 `bin/bash` → `ensure()` 直接 return，不报错、不启动进程 → 终端面板空白（静默失败）。修法：桌面分支改为"始终可启动 cmd.exe（或探测 pwsh）"。
3. **Git 面板全挂是必然的**。`GitRepo.command()`（`lib/services/git_repo.dart:51`）拼的是 `LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o ...' git ... -C 'root'`：POSIX 环境变量前缀 + 单引号 + `-C 'root'`。Windows 上无论走 `Shell.exec`→`cmd /c`（`desktop_shell.dart:36-38`）还是走 `ConsoleSession`→`_normalizeForDesktop`（`console_session.dart:124-152`，只做单引号→双引号转换），`LC_ALL=C` 都会被 cmd 当成命令名 → `'LC_ALL' 不是内部或外部命令`。**所以 Git 面板、`git snapshot`（工程打开时的状态刷新）、克隆后的登录检测全部失败**。必须改成 `Process.run(git.exe, args, cwd: root, environment: ...)`，不要再拼 shell 字符串。
4. **GitHub 登录依赖 gh CLI + POSIX 重定向**：`GithubAccount.loginCommand`（`lib/features/git/github_account.dart:41-43`）= `LC_ALL=C gh auth login ... </dev/null && gh auth setup-git ...`；`</dev/null` 在 cmd 非法；`gh` 也不在 DesktopToolchain 的安装清单里（`desktop_toolchain.dart:125-259` 只有 JDK/SDK/Git/Flutter）。→ Windows 上"登录 GitHub"完全不可用。**最小可靠路径不是装 gh，而是：PAT/设备码 → 写 app 私有 `git-credentials` + `credential.helper=store` + `GIT_CONFIG_GLOBAL`，git 全走参数数组**。见 §5。
5. **终端命令归一化只覆盖了 1 个形状**。`ConsoleSession._normalizeForDesktop()` 只认 `bash android_build.sh` 前缀和 `mkdir -p 'X' && cd 'X' && rest`（`console_session.dart:128-143`）。未覆盖：`GIT_TERMINAL_PROMPT=0 ... git clone`（克隆）、`if [ ! -d web ]; then ... stty -echo; flutter run --machine ...`（Web 预览）、`bash .flit/scripts/android_components.sh`（APK 构建前置检查）、`mkdir -p build && dart compile exe`（Dart 可执行）、`rm -rf`、`find`、`chmod`、`env -0`、`</dev/null`。前两项是 P0。见 §3 P0-4/5/6 与 §6。
6. **flutter_pty 0.4.2 确实支持 Windows（ConPTY），但有三个硬伤**（读 pub 源码得到，版本 0.4.2）：① 每个 PTY 启动前 `Sleep(1000)`；② C 侧把 Dart 传来的 UTF-8 字节**按 Latin-1 逐字节扩宽成 WCHAR**（`src/flutter_pty_win.c` `build_command`/`build_environment`/`build_working_directory`）→ **任何非 ASCII 的环境变量值/工作目录（中文用户名、中文项目路径）都会变成乱码**，`CreateProcessW` 直接失败或 PATH 解析错；③ `Pty.kill()` = `Process.killPid(pid, sigkill)`（`lib/flutter_pty.dart:186-190`）只终止根 `cmd.exe`，孙进程（dart.exe / java.exe / gradle）残留，且从不 `ClosePseudoConsole` → 输出管道可能不关，`ConsoleSession._watch` 等 `outputDone` 可能永久挂起（"停止/关闭项目"卡住）。见 §6.2。
7. **所有 Android 原生插件在 Windows 都无实现**：`flit_env`（已由 `Shell`/`DesktopShell` 全量绕过）、`flit_work`（`WorkKeepAlive` 自带 try/catch，等于 no-op）、`flit_files`（`share/installApk/open` → MissingPluginException，调用点在 `file_card.dart:155-200`、`app_versions_page.dart:83-95`，被 `_run` 捕获后把英文异常原文弹给用户）、`flit_lsp`（LSP 完全不可用，`LspClient` 捕获后 `LanguageServiceState.unavailable`）、`flit_device`（`discoverAdb` 有 catch 返回 `[]`；`pairingStatus/startPairing/openWirelessSettings/pairingReadiness` 没 catch，靠页面级 try/catch 弹原文）。→ **不崩，但功能静默缺失**，需要逐点禁用+文案。
8. **`permission_handler` 在 Windows 上是"永远 GRANTED"**（读 `permission_handler_windows-0.2.1` 源码：`checkPermissionStatus` 直接回 `GRANTED`，`requestPermissions` 全部回 `GRANTED`）。因此 `SharedStorageAccess.isGranted()`（`shared_storage_access.dart:10-13`）恒真 → 文件树"共享存储"页签直接进入 `/storage/emulated/0`（`file_tree_drawer.dart:158`）→ `Directory.list()` 抛错 → 用户看到"无法读取目录"(Android 文案)。**不是崩溃，是错误行为 + 误导文案**。
9. **路径字符串不一致是编辑器"看起来正常、细节全错"的根因**：工程绝对路径统一由 `'$projectPath/$rel'` 拼出（`project_documents.dart:84,318,390`、`project_files.dart:48`、`editor_page.dart:178`），即 `C:\...\proj/rel` 混合分隔符；而 LSP 诊断回来的是 `Uri.toFilePath()` 的 `C:\...\proj\rel`。`LspClient.acceptsDiagnostics()`（`lsp_client.dart:227-232`）与 `EditorIntelligence`（`editor_intelligence.dart:21-25`）用 `==` 比字符串 → **诊断永远被丢弃**。同类：`path.split('/').last` 拿工程名（`project_session.dart:34`、`project_actions.dart:267`、`file_card.dart:129`）在 Windows 上返回整条路径。
10. **测试基线不可信**：CI `windows-latest` 上 `flutter test` 实为 **231 passed / 96 failed**（artifact `build-logs/test.log` 里 `::error::231 tests passed, 96 failed.`），但 workflow 里 `flutter test | Tee-Object` 使退出码恒为 0（`windows-build.yml` 的 "Full test suite (仅记录，不阻断)"），所以 CI 显示 success。96 个失败里约 8 成是**测试假设 Android**（mock 的是 MethodChannel，而 `isDesktopPlatform` 让产品代码绕过 mock 去跑真实 cmd/Dart 文件 API），约 2 成是真实 Windows 行为差异（见 §11）。修复方向：给 `Shell`/平台分支加可注入 seam，而不是继续"仅记录"。

---

## 1. 现状：哪些层已经桌面化，哪些还是 Android 假设

### 1.1 已桌面化（Windows 上可直接工作，质量较好）

| 层 | 文件 | 状态 |
|---|---|---|
| 平台分叉总闸 | `lib/services/shell.dart:19` `isDesktopPlatform => !Platform.isAndroid` | ✅ 所有 `Shell` 方法（`shell.dart:22-96`）都分叉到 `DesktopShell`；Android 原生插件被整体绕过 |
| 进程执行 | `lib/services/desktop_shell.dart:30-58` `exec()` | ⚠️ 可用但有坑：`cmd.exe /c`、`SystemEncoding` 解码、`_posixShim` 只覆盖 7 种命令形状（`:204-300`） |
| 文件系统 | `lib/services/local_fs.dart` 全文件 | ✅ 纯 Dart；`canonical/isInside/exists/scanProjects/listTree` 都处理了 Windows 分隔符与大小写（`:12,228-247`） |
| 文件变更 | `lib/services/file_ops.dart:229-336` | ✅ `copy/move/delete/rename/create` 桌面分支全 Dart（`:65,105,121,157`），有 `isInside` 越界门禁 |
| 文档读写 | `lib/features/workspace/project_documents.dart:113-120,145-149` | ✅ 桌面分支走 `LocalFs`（读文本/原子写），绕开 Android 的 realpath+base64+chmod 脚本 |
| 工程列表扫描 | `project_list.dart:72-85` + `desktop_shell.dart:270-288` | ✅ 被 shim 翻译成 `LocalFs.scanProjects` |
| 文件树 | `project_files.dart:26-40` + `desktop_shell.dart:290-297` | ⚠️ 可用，但 `LocalFs.listTree` 跳过所有 dotfile（`:210-212`），比 Android 的 find（只 prune 3 个目录）少显示 `.gitignore/.metadata/.idea` |
| 环境就绪 | `environment_status.dart:56-82`、`environment_controller.dart:463-469,549-560` | ⚠️ 有桌面分支，但被 P0-1（`.bat` 判定）卡死 |
| 工具链定位 | `desktop_toolchain.dart:17-104` | ✅ home/PATH/`java.exe/adb.exe/flutter.bat/git.exe` 都 Windows 化；`childEnvironment`（`:63-81`）注入隔离 PATH |
| Web 预览降级 | `web_run_page.dart:14-63,78-85` | ✅ 桌面端明确"不支持内嵌 WebView"，改为显示 URL + 系统浏览器；但文案硬编码中文（未走 l10n） |
| 设备枚举 | `adb_ops.dart:117-131` → `Shell.exec('adb devices -l')` | ✅ PATH 里有 `platform-tools`，cmd 能解析 `adb` |
| 文件打开方式 | `file_kind.dart:40-57` 扩展名表 | ✅ 大部分文件能按后缀判类型（嗅探见 P1-7） |

### 1.2 仍然假设 Android / POSIX（本报告主要对象）

| 类别 | 代表位置 | 说明 |
|---|---|---|
| POSIX 命令字符串 | `create_project_page.dart:37,50`、`clone_project_page.dart:47-49`、`git_repo.dart:51`、`github_account.dart:41-45`、`project_actions.dart:19,28,233,272`、`web_runner.dart:88-95`、`android_build_wrapper.dart:185,263`、`file_kind.dart:64-67`、`project_list.dart:74-84`（已有 shim）、`env_vars_page.dart:45`（已有 shim） | 共 11 处；其中 4 处会直接失败、2 处静默错误 |
| MethodChannel 插件 | `flit_env`（已绕过）、`flit_work`、`flit_files`、`flit_lsp`、`flit_device` | 见 §7 表 |
| Android 专属路径 | `/storage/emulated/0`（`file_tree_drawer.dart:158,200`）、`/sdcard`（`session_environment.dart:18`）、`$HOME` 语义（`shell.dart:15`、`project_actions.dart:19`） | 桌面侧 `$HOME` 已换成 `DesktopToolchain.home`，但 `/storage/emulated/0` 只出现在共享存储浏览（P1） |
| Android 专属 UI | 无线调试配对（`device_connect_page.dart:205-300`）、通知配对指南（`device_pairing_guide_page.dart`）、USB 指南（`device_usb_guide.dart`）、"安装未知来源应用"流程（`file_card.dart:160-175`、`app_versions_page.dart:83-95`）、后台保活/电池优化（`background_access.dart`、`settings_page.dart:70-110`） | 都是 P1/P2 的"隐藏或替换"项 |
| 编辑器语言服务 | `flit_lsp`（`lsp_client.dart:46,73,147,162`） | 没有桌面传输层（P1） |

---

## 2. 「Platform.isAndroid」分叉点全量清单

`grep -rn "isDesktopPlatform\|Platform.is" lib` 的非 UI 结论：

| 分叉点 | 位置 | Windows 行为 |
|---|---|---|
| `isDesktopPlatform` 定义 | `shell.dart:19` | `true` → 后续全部走桌面分支 |
| `terminalEnvSource` | `shell.dart:13-16` | Windows 返回 `''`（正确） |
| `Shell.bootstrapStatus` | `shell.dart:26-33` → `desktop_shell.dart:22-27` | 返回 `{home: %LOCALAPPDATA%\FlitDesk, bootstrapped: true, platform: windows}` |
| `Shell.deployBootstrap` | `shell.dart:36-39` | `true`（无 bootstrap 概念，正确） |
| `Shell.exec` | `shell.dart:42-52` → `DesktopShell.exec` | `cmd /c`（见 P0-7 的 shim 覆盖面） |
| `Shell.sha256OfFile` | `shell.dart:55-58` → `desktop_shell.dart:134-154` | `certutil -hashfile`（正确） |
| `Shell.openUrl` | `shell.dart:61-64` → `desktop_shell.dart:157-170` | `cmd /c start "" url`（P2：URL 含 `&` 会被 cmd 截断） |
| `Shell.openSettings` | `shell.dart:67-70` | 恒 `false`（P2，UI 需隐藏入口） |
| `Shell.hasBinary` / `which` / `environment` / `revealDirectory` | `shell.dart:75-96` | 见 P0-2/P0-3（`which` 拼接 bug） |
| `pty_launcher` 桌面分支 | `pty_launcher.dart:29-36,67-92` | 走 ConPTY + `cmd.exe`（见 §6） |
| `pty_launcher.kill` | `pty_launcher.dart:108-119` | Windows 跳过进程组 kill，只 `pty.kill`（见 §6.2） |
| `console_session` 命令归一化 | `console_session.dart:124-152` | 覆盖面不足（P0-4/5/6） |
| `project_documents` 读写 | `project_documents.dart:113,145` | ✅ Dart 分支 |
| `file_ops` 变更 | `file_ops.dart:65,105,121,157` | ✅ Dart 分支 |
| `environment_controller` | `:216,270,463,497,639,793` | 桌面提示"不支持单组件安装/多版本切换"（文案硬编码中文，P2） |
| `environment_status` | `:85` → `_inspectDesktop()` | ✅ 但依赖 `DesktopToolchain.status()`（P0-1） |
| `web_run_page` | `:78` | ✅ 降级 |
| `auto_proxy` | 无分叉（直接调 `FlitEnv`，`auto_proxy.dart:14,28,40`） | 异常被 catch，`address=null` → 代理永不生效（P1） |
| `appearance_preferences` | 无分叉（`FlitDevice.setLanguage`，`:69,145`） | 插件内部 catch（`flit_device.dart:14-18`），无影响 |

`plugins/*` 侧：`flit_env/flit_work/flit_files/flit_lsp/flit_device` **没有任何 `windows/` 或纯 Dart 实现**（`plugins/*/lib/*.dart` 全部是 `MethodChannel` 薄壳，见 §7）。`pubspec.yaml:23-30` 用 `path:` 引用这些插件，因此 Windows 构建会注册它们但没有原生实现 → 调用即 `MissingPluginException`（并非编译错误，所以 CI 绿）。

---

## 3. 崩溃 / 静默失败缺口表（P0 / P1 / P2）

> P0 = 阻断主链路（创建/打开/编辑/终端/Git/推送），必须改；P1 = 功能错误或体验严重受损；P2 = 打磨。
> "现象"列 = Windows 上的实际表现（推演 + CI 证据）；"改法"列给到函数级，完整方案见 §4-§9。

### P0（阻断，必须改）

| # | 位置 | 现象 | 根因 | 改法（摘要） |
|---|---|---|---|---|
| P0-1 | `lib/services/desktop_toolchain.dart:106-120`（`_canRun`，`:92` 用于 flutter），影响 `environment_controller.dart:549-560`、`projects_page.dart:400-425` | 装好 Flutter 后仍显示"开发环境未就绪"，创建/克隆入口不可用；`flutter doctor` 永远进不去 | `Process.run(flutterExe, ..., runInShell: false)` 无法执行 `flutter.bat`；异常被 `catch` 吞成 `false` | `_canRun`：当 exe 以 `.bat/.cmd` 结尾时 `runInShell: true`，或统一 `Process.run('cmd.exe', ['/c', exe, ...args])`；新增 `bool _isBatch(String p)`。**与 01 报告的环境层修复必须同批做**，否则功能层全部被门口挡住 |
| P0-2 | `lib/services/desktop_shell.dart:77-95`（`which`），被 `create_project_page.dart:126-128`、`clone_project_page.dart:103-104` 使用 | 创建项目页预检"Flutter/Dart 无法运行"（`_ToolCheck.broken`），`Create` 按钮永久禁用（`create_project_page.dart:513`）。**注意**：克隆页预检用的是 `git`（`.exe`），`_runSimple('git',['--version'])` 碰巧能跑，所以克隆页预检大概率正常——但 `which()` 返回错路径对任何使用该返回值的调用方都成立 | `which()` 命中 `.bat/.cmd` 后仍无条件拼 `.exe`（`:88-92`），返回不存在的 `...\flutter.exe`；`_runSimple`（`:311-325`）又用 `runInShell:false` 执行 | `which()` 返回 `_existsBinary` 命中的**真实路径**（把后缀带回来）；`_runSimple` 对 `.bat/.cmd` 用 `cmd /c` 或 `runInShell:true`；`command -v` shim 改为直接返回 `which()` 结果并要求调用方自行跑 `--version` |
| P0-3 | `lib/features/projects/create_project_page.dart:37,50`、`clone_project_page.dart:47-49`；归一化 `console_session.dart:124-152` | 创建：**可工作**（`mkdir -p 'X' && cd 'X'` 被正则翻译成 `if not exist "X" mkdir "X" & cd /d "X"`）；克隆：**必失败** —— cmd 报 `'GIT_TERMINAL_PROMPT' 不是内部或外部命令` | 克隆命令的 `GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh ...'` 是 POSIX 变量前缀语法；`_cmdQuotes` 只会把 `'...'` 换成 `"..."`，不认变量前缀 | 克隆不要拼 shell：Dart 里 `Directory(dest).createSync(recursive: true)`，再 `Process.run(gitExe, ['clone', ...flags, url, dirName], workingDirectory: dest, environment: childEnv + {'GIT_TERMINAL_PROMPT':'0'})`；删除 `GIT_SSH_COMMAND`（MinGit 不自带 ssh，见 §5.4） |
| P0-4 | `lib/services/git_repo.dart:51`（`command`），被 `git_repo.dart:43,52`、`project_git.dart:107-108` 使用 | **Git 面板完全不可用**：状态刷新（`project_git.dart:49` → `repo.snapshot()` → `Shell.exec`）报 `'LC_ALL' 不是内部或外部命令`；分支/暂存/提交/推送全部失败 | 命令串以 `LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh ...' git ... -C 'root'` 开头，cmd 不认 POSIX 变量前缀与单引号 | 见 §5.2：新增 `GitProcess`（`Process.run(gitExe, args, workingDirectory: root, environment: ...)`），`GitRepo` 只保留 `List<String> args`；删除 `LC_ALL`、`-C`、`GIT_SSH_COMMAND` |
| P0-5 | `lib/features/run/web_runner.dart:86-96`（`if [ ! -d web ]; then ... stty -echo; flutter run --machine ...`） | 点"Web 预览"→ 命令在 cmd 里语法错误，`web.state=failed`；`run_web` 测试之外无任何可用路径 | `[ ! -d web ]`、`stty`、`|| exit $?` 均非 cmd；`_normalizeForDesktop` 不匹配 | 拆成 Dart 步骤：`if (!Directory('$root/web').existsSync()) await runFlutter(['create','--platforms','web','.'])`；然后 `flutter run --machine -d web-server --web-hostname 127.0.0.1 --web-port $port --no-devtools`（参数数组）；`stty` 需要去掉（Windows ConPTY 无此命令，也不必要） |
| P0-6 | `lib/features/environment/android_build_wrapper.dart:185`（`_check`），`:263`（`android_platform.sh`）；调用链 `project_actions.dart:305-327` → `editor_run_controls.dart:363-376` | "打包 APK"必定弹"补齐 Android 构建组件"，确认后安装脚本也跑不起来 → **无法出 APK** | `_check` 跑 `bash "$HOME/.flit/scripts/android_components.sh"`：`bash` 在 Windows 解析到 `C:\Windows\System32\bash.exe`（WSL 存根）→ 输出 `Windows Subsystem for Linux has no installed distributions.`（CI 日志里同一句出现在 `setup_runner_test` / `git_repo_test`，实证）→ `exitCode != 0` → 抛错 | 桌面分支：`_check` 改为纯 Dart 检查 —— `DesktopToolchain.status()`（jdk/sdk/aapt2/platform）+ 直接读 `build.gradle` 的 `ndkVersion/buildToolsVersion/compileSdk`（`_readRequirements` 已经是 Dart 读文件，可复用）；缺失时走 task-1 的桌面安装器，不再调用 bash |
| P0-7 | `lib/features/terminal/pty_session.dart:22-25`（`File('$prefix/bin/bash')`） | 终端面板打开后**没有任何进程**、无提示；用户以为卡住 | 桌面 `prefix=DesktopToolchain.home`，没有 `bin/bash` → `_ensure()` 静默 return | 分叉：`if (!isDesktopPlatform) {传统检查}`，桌面端直接 `start(workingDirectory: tc.home)`；`_startDesktop` 已支持 cmd.exe（`pty_launcher.dart:74-91`） |
| P0-8 | `lib/features/terminal/pty_launcher.dart:67-92` + flutter_pty 0.4.2 原生实现 | 中文用户名/中文项目路径下：会话启动失败（`Failed to create process`）或 PATH 失效；停止/关闭会话后 `dart.exe/java.exe` 残留、会话卡在 `stopping` | ① flutter_pty C 侧 `build_command/build_environment/build_working_directory` 把 UTF-8 字节按 Latin-1 扩宽成 UTF-16（`src/flutter_pty_win.c:42,56,107`）→ 非 ASCII 全乱码；② `Sleep(1000)` 每次启动多 1s；③ `Pty.kill()`=`Process.killPid`（`lib/flutter_pty.dart:186-190`）只杀 cmd.exe；④ 从不 `ClosePseudoConsole` | 见 §6.3：短期"ASCII 化 home + 检测非 ASCII 时降级 pipe 模式"；中期 fork/vendored patch（`third_party/flutter_pty` 用 `MultiByteToWideChar(CP_UTF8)`）+ `taskkill /T /F` / Job Object 杀进程树 + 关闭 PTY |

### P1（功能错误 / 体验严重受损）

| # | 位置 | 现象 | 根因 | 改法 |
|---|---|---|---|---|
| P1-1 | `lib/features/git/github_account.dart:41-45,65-75` | GitHub 永远"未登录(缺少 gh)"；即使装了 gh 也因 `>/dev/null`、`</dev/null` 失败 | 依赖 gh CLI + POSIX 重定向；`command -v gh` 的 shim 把 `gh auth token ... >/dev/null 2>&1` 漏给 cmd | 见 §5.3：设备码/PAT + `credential.helper=store`（纯 Dart），gh 仅作为可选增强 |
| P1-2 | `lib/features/editor/lsp/lsp_client.dart:46,50,73,147,162`（`FlitLsp.*`） | 编辑器无诊断、无 LSP 补全/签名/快速修复；`editor_analysis_status.dart` 显示降级（`LanguageServiceState.unavailable`） | MethodChannel `flit/lsp` 在 Windows 无实现 → MissingPluginException；`EventChannel` 同样 | 见 §8：纯 Dart `Process` 传输层；dart 可执行文件 = `<flutter>/bin/cache/dart-sdk/bin/dart.exe`；启动参数照抄 Android 原生 `dart language-server --protocol=lsp`（`plugins/flit_lsp/.../LspServer.kt:35`，`FlitLspPlugin.kt:57-60`） |
| P1-3 | `lib/features/workspace/project_session.dart:34`、`lib/features/workspace/project_actions.dart:267`、`lib/features/editor/widgets/file_card.dart:129`、`lib/features/editor/lsp/lsp_client.dart:88` | AppBar/抽屉标题/文件卡标题显示**完整路径**而不是工程名；`dart compile exe` 生成 `bin/<C:\整条路径>.dart`（必然失败） | `path.split('/').last` 假设 `/`；Windows 绝对路径用 `\` | 统一 `String baseName(String path)`：`path.split(RegExp(r'[\\/]')).where(...).last`；或 `LocalFs.leafName`（`local_fs.dart:241-245` 已有 `_leaf`，提升为公开方法） |
| P1-4 | `project_documents.dart:84,318,390`、`project_files.dart:48`、`editor_page.dart:178`（`'$projectPath/$rel'`）+ `lsp_client.dart:227-232`、`protocol.dart:51-52`、`editor_intelligence.dart:21-25` | 诊断永远丢弃（`report.path` = `C:\...\a.dart` ≠ key `C:\.../a.dart`）；LSP 的 `documentChanges` 匹配也可能错 | 混合分隔符 + `==` 字符串比较 | 新增 `LocalFs.absolute(root, rel)` 与 `LocalFs.same()`；LSP 侧 `acceptsDiagnostics` 用 `LspProtocol.samePath(report.path, path)`（`Uri.parse(...).toFilePath()` 后 `File(...).resolveSymbolicLinksSync()` 或大小写不敏感比较） |
| P1-5 | `lib/features/editor/file_kind.dart:64-67`（`sniffCommand`）+ `project_files.dart:44-53` | 未知后缀的二进制文件被当文本打开（乱码/卡编辑器）；`head/od/grep` 在 cmd 不存在，输出是错误文本，`fileKindFromSniff` 判为 `code` | POSIX 管线，未被 shim 覆盖 | 纯 Dart `FileKind sniffFile(String absPath)`：读前 8KB，含 `0x00` → binary；`project_files.dart:48` 改调它；删除 `sniffCommand` 或保留给 Android |
| P1-6 | `lib/features/editor/widgets/file_tree_drawer.dart:141-160,200-205,314,376,497,539` | 文件树"共享存储"页签：`permission_handler` 在 Windows 恒 GRANTED（见 TL;DR-8）→ 直接进入 `/storage/emulated/0` → 弹"无法读取目录: ..."；浏览列表里 `e.path.split('/').last` 得到整条路径 | 硬编码 Android 共享存储根 + `/` 分隔假设 + 权限语义不适用 | 桌面端隐藏 `_Loc.storage` 页签，改为"打开本地目录/导入文件"（用 `file_selector`，见 §9.3）；`_browseDir` 初值改为 `Platform.environment['USERPROFILE']`；名称用 `baseName` |
| P1-7 | `lib/services/auto_proxy.dart:14,28,40` | Windows 上"自动代理"永不生效（`address` 恒 null）；设置页开关形同虚设 | 依赖 `FlitEnv.systemProxy()` / `onSystemProxyChanged`（Android 原生） | 桌面实现：读 WinINET（`HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings` 的 `ProxyEnable/ProxyServer`，用 `reg query` 解析）或 `netsh winhttp show proxy`；`applyToDart()` 保持；`envVars()` 继续注入 `HTTP(S)_PROXY` |
| P1-8 | `lib/services/background_access.dart:16-24,63-64`、`lib/features/settings/settings_page.dart:70-110` | 首次启动弹"后台运行/通知/电池优化"Android 对话框；`Permission.notification.status` 在 Windows 恒 GRANTED → 显示"已启用"（假） | Android 概念 | 桌面端跳过 `BackgroundAccess.explain`（`workbench_page.dart:66` 调用处加平台判断）；设置页隐藏"后台运行"分组 |
| P1-9 | `lib/features/editor/widgets/file_card.dart:155-200`、`lib/features/settings/app_versions_page.dart:83-95` | 点"安装/分享/用其他应用打开"→ 弹 `MissingPluginException(No implementation found for method share on channel flit/files)` 原文 | `flit_files` 无 Windows 实现 | 新增 `DesktopFiles`（§9.3）：`open`=ShellExecute/`start ""`；`reveal`=`explorer /select,`；`installApk`=`adb -s <serial> install -r`；`share`=复制路径到剪贴板+提示。卡片按钮按平台过滤（`cardActions(path, platform)`） |
| P1-10 | `lib/features/device/device_connect_page.dart:224-300`、`device_pairing_guide_page.dart:54,133,203`、`device_usb_guide.dart` | 无线配对页：`discoverAdb` 返回空 → 一直"搜索中"；`startPairing/pairingStatus/pairingReadiness` 抛 MissingPluginException → 页面显示异常原文；USB 指南文案是手机端操作 | Android NSD/系统配对弹窗/通知 | Windows 隐藏"无线调试配对"入口与指南，仅保留"USB/局域网 adb connect"（`adb pair` 命令行方式可选保留给高级用户）；文案见 §10 的 l10n 落地方式 |
| P1-11 | `lib/services/local_fs.dart:196-224`（`listTree`，`:210-212`） | 文件树看不到 `.gitignore`、`.metadata`、`.idea`、`.vscode` 等（Android 上用 `find` 是能看到的） | `listTree` 跳过所有 `.` 开头名字；Android 的 find 只 prune `build/.dart_tool/.git` | 只跳过 `skip` 集合（`build/.dart_tool/.git`）与 `.`/`..`，保留其它 dotfile |
| P1-12 | `lib/features/terminal/console_session.dart:117-122`（`_cmdQuotes`） | commit message / 分支名 / 描述里含 `"`、`&`、`%`、`^`、`!` 时命令被 cmd 拆坏（`_cmdQuotes` 只做单引号→双引号，无 cmd 转义） | 用 shell 字符串传参 | Git 全部走参数数组（P0-4 已含）；若必须走 shell，新增 `String quoteForCmd(String s)`：对 `&|<>^%"` 做 `^` 转义、路径用 `"..."`，并单测 |

### P2（打磨）

| # | 位置 | 现象 | 改法 |
|---|---|---|---|
| P2-1 | `web_run_page.dart:35-53` | 降级面板文案硬编码中文（未进 ARB），英文 UI 会中英混杂 | 加 l10n key（§9.4） |
| P2-2 | `lib/features/run/web_runner.dart:88-95` | Web 预览只靠 `flutter run`，无"打包 Web"引导；`ProjectBuild.web` 没有 `artifactPath`（`project_actions.dart:32-38`）→ 构建完不打开产物 | 加 `artifactPath: 'build/web/index.html'`；产物卡复用 `builtArtifacts`（`project_actions.dart:136-137` → `editor_page.dart:98`） |
| P2-3 | `desktop_shell.dart:157-170`（`openUrl`） | `cmd /c start "" <url>` 遇到 `&`、`?a=b&c=d` 被截断 | `rundll32 url.dll,FileProtocolHandler "<url>"` 或 `Process.run('explorer.exe',[url])` |
| P2-4 | `lib/features/editor/widgets/markdown_preview.dart:133` | 图片路径判定 `src.startsWith('/')` 不认 `C:\...`；相对路径拼 `projectRoot` 用 `/` | 用 `Uri` 解析或 `File(src).isAbsolute` |
| P2-5 | `environment_controller.dart:216-219,270-273` | 桌面端不支持单组件安装/版本切换的提示是硬编码中文 | 进 ARB；UI 上把"多版本"整块隐藏 |
| P2-6 | `lib/features/projects/create_project_page.dart:494` | 位置预览固定显示 `$HOME/<name>`，Windows 上应显示 `%LOCALAPPDATA%\FlitDesk\projects\<name>` | 用 `widget.projectRoot` + 分隔符 |
| P2-7 | `lib/features/projects/projects_page.dart:65-67` | 兜底路径是 Android 私有目录字符串 | 兜底改为 `DesktopToolchain().projectsDir`（`desktop_toolchain.dart:43`） |
| P2-8 | `lib/features/projects/projects_page.dart:116-134` | "工程存在应用私有目录、卸载即删"的说明对桌面不成立 | 桌面换文案：工程在 `%LOCALAPPDATA%\FlitDesk\projects`，可随时用资源管理器打开 |
| P2-9 | `lib/features/terminal/global_terminal_panel.dart:448` 等 | 软键盘/特殊键 UI 在桌面多余（`/`、Ctrl 修饰键） | 桌面隐藏虚拟键盘行（`global_terminal_panel.dart:532` 一带已有 `interactive` 判断，加平台条件） |
| P2-10 | `lib/features/editor/widgets/editor_run_controls.dart` 整块 | 顶栏"平台"选择器列出 ADB 设备；Windows 上若用户没装 phone driver，列表空 → 只剩 Web，可接受；但"选择平台"空态文案可优化 | 文案见 §10 的 l10n 落地方式 |
| P2-11 | `main.dart:63-73` | `SystemChrome.setEnabledSystemUIMode(edgeToEdge)` 在 Windows 为 no-op（无害），但可加平台判断减少噪音 | 包 `if (Platform.isAndroid)` |

---

## 4. 创建项目 / 克隆项目 / 打开已有目录：完整链路与逐步改法

### 4.1 现状链路（自 UI 到进程）

**（A）新建项目**

1. `ProjectsPage._init()`（`projects_page.dart:59-79`）：`Shell.bootstrapStatus()['home']` → 桌面为 `%LOCALAPPDATA%\FlitDesk`（`desktop_shell.dart:22-27` + `desktop_toolchain.dart:22-32`）→ root = `<home>/projects`；`environmentReady` 为真时才 `projects.refresh()`（`:78`）。
2. 点 "+"：`_createProject()`（`:190-219`）→ 推 `CreateProjectPage`。
3. 页面 `initState` → `_check()`（`create_project_page.dart:118-146`）：`Shell.exec('command -v flutter >/dev/null 2>&1 || exit 127; flutter --version')` → **被 `_posixShim` 命中**（`desktop_shell.dart:208-224`）→ `hasBinary('flutter')` → `which('flutter')`（P0-2 返回错路径）→ `_runSimple('flutter',['--version'])`（P0-2 无法执行 .bat）→ `_ToolCheck.broken` → 按钮禁用。
4. `_submit()`（`:170-215`）：重名预检 `Shell.exec("[ -e 'P' ] || [ -L 'P' ]")` → shim 命中（`desktop_shell.dart:235-243`）→ 正常；返回 `CreateProjectParams`。
5. `projects_page.dart:213-218` → `_runTask(buildFlutterCreateCommand(params), openOnSuccess: true)`。
6. `_runTask()`（`:248-282`）：新建 `ConsoleSession(kind: temp)`，`task.run(command)` → `ConsoleSession.start()` → `_normalizeForDesktop()`（P0-3：`mkdir -p 'X' && cd 'X'` 被翻译，**创建本身可用**）→ `PtyLauncher._startDesktop` → `Pty.start('cmd.exe', ['/c', normalized])`。
7. `_finishOp()`（`:289-317`）：`projects.refresh()`（shim→LocalFs）→ 成功则 `onOpenProject(path)` → `ProjectWorkspace.open` → `EditorPage`。

**（B）克隆项目**

1. 点下载图标 → `_cloneProject()`（`projects_page.dart:223-246`）→ `CloneProjectPage`。
2. `_runPrecheck()`（`clone_project_page.dart:101-125`）：`command -v git ... git --version` → 同 P0-2 问题（`which('git')` 会拼 `.exe` 恰好对，但 `_runSimple('git')` 能跑，因为 git 是 .exe → 这一项**可能碰巧可用**；`git` 若来自 MinGit 的 `cmd/git.exe` 也在 PATH，OK）。
3. `_submit()`（`:141-181`）：目标目录预检（shim OK）→ 返回 params。
4. `buildGitCloneCommand()`（`:38-50`）：`mkdir -p 'dest' && cd 'dest' && GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh ...' git clone ...` → `_normalizeForDesktop` 只翻译 mkdir/cd，**rest 里的变量前缀留给 cmd → 必失败**（P0-3）。
5. `_finishOp()`：失败后 `_needsLogin`（`projects_page.dart:285-287`）匹配 `could not read Username|terminal prompts disabled|...`；cmd 的失败文本是"`'GIT_TERMINAL_PROMPT' 不是内部或外部命令`" → 不匹配 → 用户看到"克隆失败（退出码 1）"。

**（C）打开已有目录**

- 现状：**没有系统目录选择器**。首页只列 `<home>/projects` 下一层目录（`project_list.dart:127-157` → shim）；用户想打开磁盘上任意目录（如 `D:\code\app`），要么把它放进 `%LOCALAPPDATA%\FlitDesk\projects`，要么无路可走。
- 打开动作：`ProjectList` tile onTap → `widget.onOpenProject(entry.path)`（`projects_page.dart:520`）→ `workbench_page.dart:96` `ProjectWorkspace.open(path)` → `ProjectSession` 构造 → `activate()`（`project_session.dart:105-109`）→ `language.ensureStarted(path)`（LSP，P1-2）+ `_detectKind()`（`cat 'path/pubspec.yaml'` → shim OK）+ `_ensureDependencies()`（`[ -f ... ] && echo RESOLVED` → shim OK）。
- 注意：`ProjectSession.name`（`:34`）在 Windows 上 = 整条路径 → `EditorPage` 标题错误（P1-3）。

### 4.2 推荐实现（函数级）

新增 `lib/services/process_launcher.dart`（或并入 `desktop_shell.dart`）：

```dart
/// 跨平台一次性命令。Windows 上不拼 shell 字符串，直接 exe+args。
class ProcessSpec {
  const ProcessSpec(this.exe, this.args, {this.workingDirectory, this.env, this.runInShell});
  final String exe;
  final List<String> args;
  final String? workingDirectory;
  final Map<String, String>? env;
  final bool? runInShell;
}

class ProcessRunner {
  Future<({int code, String out})> run(ProcessSpec spec, {int timeoutMs = 120000});
  /// .bat/.cmd 自动走 cmd /c；其余直跑
  bool needsShell(String exe) => Platform.isWindows && (exe.endsWith('.bat') || exe.endsWith('.cmd'));
}
```

- `create_project_page.dart`：删掉 `buildDartCreateCommand/buildFlutterCreateCommand` 的**执行用途**，改为 `List<String> flutterCreateArgs(CreateProjectParams p)` + `List<String> dartCreateArgs(...)`（保留两个 `build*Command` 仅供 Android/测试，Android 路径不变）：

```dart
String? buildCreateCommand(CreateProjectParams p) =>
    isDesktopPlatform ? null : (p.type == 'dart' ? buildDartCreateCommand(p) : buildFlutterCreateCommand(p));

// 桌面：Dart 侧建目录 + 参数数组
Future<void> createProject(CreateProjectParams p) async {
  final dir = Directory(p.projectRoot)..createSync(recursive: true);
  final exe = p.type == 'dart'
      ? WidgetsBinding... // 用 ToolResolve.dartExe()
      : DesktopToolchain().flutterExe; // flutter.bat
  final args = p.type == 'dart'
      ? ['create', '--no-pub', '--template', p.template, p.name]
      : ['create', '--no-pub', '--platforms=${p.platforms.join(',')}', '--org', p.org,
         if (p.empty) '--empty', if (...) '-a', 'java',
         if (p.description.trim().isNotEmpty) '--description', p.description.trim(), p.name];
  final r = await ProcessRunner().run(ProcessSpec(exe, args, workingDirectory: p.projectRoot, env: DesktopToolchain().childEnvironment), timeoutMs: 600000);
  ...
}
```

- `clone_project_page.dart`：`List<String> gitCloneArgs(CloneProjectParams p)`（`--branch`、`--depth 1`、url、dirName）；执行前 `Directory(p.targetDir).createSync(recursive: true)`；env 加 `GIT_TERMINAL_PROMPT=0`；**去掉 `GIT_SSH_COMMAND`**，若 URL 是 `git@`/`ssh://` 则在 Windows 上提示"请改成 HTTPS（Windows 便携 Git 不带 ssh）"，或直接转换为 `https://github.com/<owner>/<repo>.git`。
- "打开已有目录"：新增 `lib/services/desktop_directory_picker.dart`：

```dart
Future<String?> pickDirectory(BuildContext context, {String? initial});
// Windows: file_selector -> getDirectoryPath()；Android: 维持 SharedStorageAccess 流程
```
  并在 `ProjectsPage` AppBar 加"打开目录"按钮（`projects_page.dart:336-352` 同排），成功后 `widget.onOpenProject(path)`；同时允许把工程根改为用户选择的目录（持久化到 `appearance_preferences`，新增 `projectsRoot` 字段）——**这一项是 Windows 体验的关键差异**：不应强迫用户把工程放进 `%LOCALAPPDATA%`。

---

## 5. Git / GitHub：Windows 上的最小可靠路径

### 5.1 现状证据

| 位置 | 内容 | Windows 结果 |
|---|---|---|
| `git_repo.dart:51` | `LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=yes' git --no-pager --literal-pathspecs -c core.quotepath=false -c color.ui=false -C 'root' <args...>` | ❌ cmd：`'LC_ALL' 不是内部或外部命令`；即使能跑，`-C 'root'` 的单引号也不是 cmd 的引号 |
| `git_repo.dart:42-48` | `_shell` 走 `Shell.instance.exec` | ❌ 同上 |
| `project_git.dart:107-120` | Git 操作用 `executions.start(RunConfiguration(command: repo.command(args)))` 进终端 | ❌ 归一化只换引号，变量前缀仍在 |
| `git_repo.dart:78-84` | 注释还写着 `/sdcard` 别名问题 | 无害，但说明代码是 Android 语境 |
| `git_repo.dart:97-136` | `status --porcelain=v1 -z` 的解析 | ✅ 平台无关；Windows 下 git 输出的路径是 `/` 分隔（相对路径），解析正确 |
| `project_git.dart:218-224` | `git config --local user.name/email` | ✅ 只要能执行 git |
| `github_account.dart:41-45` | `LC_ALL=C gh auth login ... </dev/null && gh auth setup-git --hostname github.com` | ❌ `</dev/null`、`LC_ALL`、无 gh |
| `github_account.dart:65,69-71,84` | `command -v gh`、`gh auth token ... >/dev/null 2>&1`、`gh api user` | ❌ 探针前两条被 shim 部分处理，但 `>/dev/null` 未处理 → cmd 报错；且 gh 不存在 → `GithubAuth.missing` |
| `github_mirror.dart:17-36` | `gh-proxy.com` 前缀只对 `github.com/api.github.com/objects.githubusercontent.com` 生效 | ✅ 平台无关；但只影响"下载工具链/Release 资产"，**不影响 git clone/push**（git 直连 github.com 仍可能被墙）。Windows 端是否需要镜像取决于用户网络，建议做成设置项 |

**结论：现在 Windows 上 Git 不可用不是"某条命令拼错"，而是整层实现方式选错。** 修法不是补正则，而是把这层从"拼 shell 字符串"换成"参数数组 + Process"。`project_git.dart`/`git_panel.dart` 的业务逻辑（stage/commit/push/分支/冲突）**不需要改**，只要 `GitRepo` 换执行器。

### 5.2 新的 Git 执行层（建议新增 `lib/services/git_process.dart`）

```dart
/// 一个工程的 Git 进程边界。所有参数走 argv，绝不拼 shell。
class GitProcess {
  GitProcess(this.root, {Map<String, String>? environment, String? executable})
      : _environment = environment, _exe = executable;

  final String root;
  final Map<String, String>? _environment;
  final String? _exe;

  String get executable => _exe ?? _resolveGit();       // MinGit: <home>\git\cmd\git.exe；否则 PATH 里的 git.exe
  Map<String, String> get environment => {
        ...( _environment ?? DesktopToolchain().childEnvironment),
        'GIT_TERMINAL_PROMPT': '0',
        'GIT_CONFIG_NOSYSTEM': '1',                        // 不读系统 gitconfig，避免用户全局配置干扰
        'GIT_CONFIG_GLOBAL': _globalConfigPath(),          // <home>\.flit\gitconfig
        if (Platform.isWindows) 'GIT_ASKPASS': 'echo',     // 兜底：不允许弹窗
      };

  Future<GitResult> run(List<String> args, {int timeoutMs = 60000}) async {
    final r = await Process.run(
      executable, ['--no-pager', '--literal-pathspecs', '-c', 'core.quotepath=false', '-c', 'color.ui=false', ...args],
      workingDirectory: root, environment: environment,
      stdoutEncoding: const SystemEncoding(), stderrEncoding: const SystemEncoding(),
    ).timeout(Duration(milliseconds: timeoutMs));
    return (code: r.exitCode, out: '${r.stdout}${r.stderr}');
  }
}
```

- `GitRepo`：把 `GitExecute` 的签名从 `Future<GitResult> Function(String command)` 改为 `Future<GitResult> Function(List<String> args)`；`command(List<String>)` 删除。
- `ProjectGit._command`（`project_git.dart:107-108`）：不再 `_terminal(repo.command(args))`，改为"直接 `repo.run(args)` + 把输出写进终端日志"；若希望终端里可见，用 `RunConfiguration` 的 `displayCommand` 字段显示等价命令文本，但执行仍走 `repo.run`（`console_session.dart:169` 已支持 `displayCommand`）。
- 纯 Dart 侧**不要**再用 `LC_ALL`（Windows 无意义）、`-C`（改用 `workingDirectory`）、`GIT_SSH_COMMAND`（Windows 无 ssh 时是负资产）。

### 5.3 GitHub 登录与 push（不依赖 gh）

**目标**：用户在 Flit 里点"登录 GitHub"→ 浏览器授权 → 回到 Flit 即为已登录 → 之后 clone/push 私有库无需再输入凭据。

**方案 A（推荐，纯 HTTP 设备流）**：新增 `lib/services/github_device_flow.dart`

```dart
class GithubDeviceFlow {
  GithubDeviceFlow({required this.clientId, HttpClient? http});
  final String clientId;                       // OAuth App，经 --dart-define=FLIT_GH_CLIENT_ID 注入

  Future<DeviceCode> requestCode({List<String> scopes = const ['repo', 'read:org', 'workflow']});
  Future<DeviceTokenResult> poll(DeviceCode code);   // 处理 authorization_pending / slow_down / expired_token / access_denied
}

class DeviceCode { final String deviceCode, userCode, verificationUri; final int interval; final DateTime expiresAt; }
sealed class DeviceTokenResult {}  // Token(String) | Pending | SlowDown(int) | Expired | Denied | Error(String)
```
- 端点：`POST https://github.com/login/device/code`（form: `client_id`, `scope`，`Accept: application/json`）；`POST https://github.com/login/oauth/access_token`（`grant_type=urn:ietf:params:oauth:grant-type:device_code`）。**需要 GitHub OAuth App 的 client_id**（公开信息，无 secret；设备流不需要 client_secret）。这是产品/运维动作：在 GitHub 上注册一个 OAuth App（callback 可留空），把 client_id 通过 `--dart-define` 注入构建，或用 `String.fromEnvironment('FLIT_GH_CLIENT_ID')` + 缺省时退回方案 B。
- 不要复用 gh CLI 的 client_id（第三方应用凭据，未经授权不应使用）。

**方案 B（兜底，PAT）**：设置页增加"用个人访问令牌登录"输入框（scope 勾 `repo`），验证 `GET https://api.github.com/user`（`Authorization: Bearer <tok>`），成功后走同一存储路径。

**凭据落地（两种方案共用）**：新增 `lib/services/git_credentials.dart`

```dart
class GitCredentials {
  GitCredentials({DesktopToolchain? toolchain});
  String get globalConfigPath => '<home>\\.flit\\gitconfig';
  String get storePath       => '<home>\\.flit\\git-credentials';

  /// 写 credential.helper=store + user.name/email；0600 语义在 Windows 由 ACL 兜底
  Future<void> save({required String host, required String username, required String token, String? name, String? email});
  Future<void> clear(String host);
  Future<({String username, String token})?> load(String host);
}
```
- 生成 `<home>\.flit\gitconfig`：
  ```ini
  [credential]
      helper = "store --file=C:/Users/<u>/AppData/Local/FlitDesk/.flit/git-credentials"
  [user]
      name = ...
      email = ...
  [http]
      sslVerify = true
  ```
- 生成 `git-credentials`（一行）：`https://<username>:<token>@github.com`
- 所有 Git 进程注入 `GIT_CONFIG_GLOBAL=<home>\.flit\gitconfig`（`GitProcess.environment` 已含）→ **不污染用户全局 `~/.gitconfig`**，也不依赖 Git Credential Manager（MinGit 不自带 GCM，见 §5.4）。
- 安全：文件放在 app 私有目录，Windows 上建议 `icacls` 收紧（可后续做）；UI 明确提示"令牌保存在本机应用目录"。
- 头像/昵称：`GET https://api.github.com/user`（纯 Dart），替换 `GithubAccount._probe('gh api user')`（`github_account.dart:84`）。

### 5.4 关键约束：MinGit 不含 ssh、不含 GCM

`desktop_toolchain.dart:209-227` 下载的是 **MinGit**（`_resolveMinGitUrl` 只匹配 `mingit*64-bit*.zip`）。MinGit 只带 `cmd/git.exe`、`mingw64/bin/git.exe` 与核心 DLL，**没有 `ssh.exe`、没有 `git-credential-manager`**。因此：
- `git@github.com:` / `ssh://` 克隆在 Windows 默认失败 → 桌面端 URL 校验（`clone_project_page.dart:136`、`project_git.dart:208`）应允许但给明确提示，或自动把 `git@github.com:owner/repo.git` 转成 `https://github.com/owner/repo.git`。
- HTTPS push 必须靠 `credential.helper=store`（§5.3）或 `http.extraHeader`（不推荐，token 会进进程参数）。**不能用交互式提示**（`GIT_TERMINAL_PROMPT=0` 已保证不挂起）。
- 若要让用户复用系统已装的 Git for Windows（带 GCM/ssh），加设置项"使用系统 Git"：探测 `where git` 并优先用它；默认仍用 MinGit 保证可移植。

### 5.5 端到端"提交到 GitHub 仓库"最小可靠路径（验收清单）

1. 设置/克隆页登录（设备码或 PAT）→ `GitCredentials.save` 写 gitconfig + credentials。
2. `Directory(projectRoot).createSync` + `git clone`（HTTPS，env `GIT_TERMINAL_PROMPT=0`）。
3. 打开工程 → `GitRepo.snapshot()`（`Process.run`）→ 面板显示改动。
4. `git add -A` → `git commit -m <msg>`（**message 走 argv，天然免疫引号/中文**；编码用 `--encoding=UTF-8` 可选）。
5. `git push --set-upstream origin <branch>`（首次）→ `git push`。
6. 失败时把 stderr 原文显示在终端 + SnackBar（现有 `_terminal`/`_finishOp` 逻辑可复用，只要退出码真实）。

> 注意：`project_git.dart:139-149` 的 `commit` 会先 `snapshot()` 检查 staged；`push` 会检查 upstream（`:184-206`）。这些逻辑与平台无关，**不要重写**。

---

## 6. 终端：flutter_pty 的 Windows 支持与 cmd.exe 现实

### 6.1 flutter_pty 0.4.2 的 Windows 事实（读包源码，非猜测）

`pubspec.lock:153-160` 锁定 `flutter_pty 0.4.2`。从 pub.dev 归档解包核对（`/tmp/fp`）：

| 事实 | 证据 |
|---|---|
| Windows 是**官方支持平台**，ffiPlugin（CMake 构建，C/C++，**不需要 Rust/cargo**） | `pubspec.yaml` 的 `flutter.plugin.platforms.windows.ffiPlugin: true`；`windows/CMakeLists.txt`；README 平台表 Windows ✔️ |
| 用 **ConPTY**（非 winpty） | `src/flutter_pty_win.c`：`CreatePseudoConsole`、`ResizePseudoConsole`、`PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` |
| 每次启动 `Sleep(1000)` | `src/flutter_pty_win.c` `CreateProcessW` 之前 |
| 退出码是 Windows 32 位有符号值（崩溃为负） | `lib/flutter_pty.dart:160-176` 文档 |
| `kill()` = `Process.killPid(pid, signal)` | `lib/flutter_pty.dart:186-190` → 只杀根进程，无进程树 |
| 输入 `pty_write` 直接 `WriteFile` 原始字节 | `src/flutter_pty_win.c:433-442`（ConPTY 输入按 UTF-8 解释，中文输入可行） |
| **argv / env / workingDirectory 用"字节→WCHAR"逐字节扩宽** | `src/flutter_pty_win.c` `build_command`（`command[i]=(WCHAR)executable[j]`）、`build_environment`、`build_working_directory` |
| 没有 `ClosePseudoConsole` / 句柄释放 | `src/flutter_pty_win.c`（无该调用；`startupInfo` 注释掉的 free 也印证） |

**因此结论**：`pty_launcher._startDesktop`（`pty_launcher.dart:67-92`）的调用方式在**纯 ASCII 环境 + 简单命令**下可用；一旦路径或环境变量含中文（Windows 中文用户 `C:\Users\张三\AppData\...` 极常见），就会 `Failed to create process` 或 PATH 乱码。这是 Windows 版"装完能开、点了就报错"的典型陷阱。

### 6.2 现有桌面终端实现的具体问题

| # | 位置 | 问题 |
|---|---|---|
| 6.2.1 | `pty_launcher.dart:76-90` | 交互 shell 用 `cmd.exe /K`（无后续命令）→ 可以；但 cwd 默认 `tc.home`，不 `cd` 到用户工程（工程内 shell 由 `run_sessions.dart:66` 传 `workingDirectory: projectPath`，OK） |
| 6.2.2 | `pty_launcher.dart:79-81` | 没有 `chcp 65001`：Windows 中文系统控制台默认 CP936，cmd 内建命令走 `WriteConsoleW` 经 ConPTY 转 UTF-8 尚可，但**子进程按 GBK 写原始字节**（java/gradle/部分 CLI）会被 `Utf8Decoder`（`console_session.dart:204`）解成 U+FFFD |
| 6.2.3 | `console_session.dart:124-152` | 归一化只覆盖 2 种形状；`_cmdQuotes` 无 cmd 转义（见 P1-12） |
| 6.2.4 | `console_session.dart:282-300`（`_stop`） | 先写 `\x03` 等 3s 再 `kill()`；ConPTY 下 Ctrl+C 对 cmd 有效（发给前台进程组），但 `kill()` 只杀根进程 → 孙进程残留；且 `outputDone` 可能不完成 → `await done` 挂起 |
| 6.2.5 | `pty_launcher.dart:108-119` | Windows 分支只 `pty.kill(sigkill)`，没有 `taskkill /T /F` |
| 6.2.6 | `pty_session.dart:22-25` | 默认 shell 根本不启动（P0-7） |
| 6.2.7 | `session_environment.dart:10-24` | Android 专用变量（`PREFIX/ANDROID_ROOT/ANDROID_DATA/EXTERNAL_STORAGE/LD_PRELOAD`）；桌面路径没走这个函数（`pty_launcher._startDesktop` 自己拼 env，正确），但**Android 语义残留在共享代码里**，易误用 |
| 6.2.8 | `global_terminal_panel.dart:448,532` | 软键盘/Ctrl 修饰键 UI；桌面端可隐藏 |

### 6.3 推荐设计（无 PTY 的降级 + 有 PTY 的加固）

**（1）抽象层保持 `SessionProcess`（`console_session.dart:20-26`）不变**，新增两个实现：

```dart
// lib/features/terminal/pty_session_process.dart
class PtySessionProcess implements SessionProcess { ... }   // 现有 _PtyProcess 提取

// lib/features/terminal/pipe_session_process.dart
class PipeSessionProcess implements SessionProcess {
  /// Process.start(exe, args, runInShell: true, workingDirectory: ..., environment: ...)
  /// output = stdout+stderr 合并流；write -> stdin；resize -> no-op (记录尺寸但不生效)
  /// kill -> Process.kill() + `taskkill /PID <pid> /T /F`(Windows)
  /// exitCode -> process.exitCode
  final bool limited = true;  // UI 用它显示"基础模式"
}
```

**（2）`PtyLauncher._startDesktop` 加固**（保留 PTY 优先）：

```dart
Future<SessionProcess> _startDesktop({...}) async {
  final win = Platform.isWindows;
  final exe = win ? 'cmd.exe' : '/bin/sh';
  final cwd = workingDirectory ?? tc.home;
  final baseEnv = {...tc.childEnvironment, ...proxy.envVars(), 'TERM': 'xterm-256color'};
  final args = command == null
      ? (win ? ['/K', 'chcp 65001>nul'] : ['-i'])                       // 交互: 先切 UTF-8
      : (win ? ['/c', 'chcp 65001>nul & ', command] : ['-c', command]); // 一次性: 同会话切
  if (!win && ...) ...
  try {
    return PtySessionProcess(Pty.start(exe, arguments: args, workingDirectory: cwd, environment: baseEnv, rows: rows, columns: columns));
  } on StateError catch (_) {                       // 'Failed to create PTY'（非 ASCII 路径等）
    return PipeSessionProcess.start(exe, args, cwd, baseEnv);   // 自动降级
  }
}
```
> `chcp 65001>nul &` 前缀在交互模式下用 `/K` 加一次即可；不要在每个命令前重复。

**（3）进程树终止**：Windows 上把 `taskkill /PID <pid> /T /F` 作为 kill 主路径（`Pty.pid` 是 cmd.exe 的 pid）：
```dart
Future<void> killTree(int pid) async {
  if (Platform.isWindows) {
    await Process.run('taskkill.exe', ['/PID', '$pid', '/T', '/F']);
  } else { try { Process.killPid(-pid, ProcessSignal.sigkill); } catch (_) {} }
}
```
并在 `ConsoleSession._stop()` 超时分支调用 `killTree` 而不是仅 `_process?.kill()`。

**（4）中文/非 ASCII 路径**（两选一，建议都做）：
- 短期：`DesktopToolchain.defaultHome()`（`desktop_toolchain.dart:22-32`）优先用 ASCII 路径：若 `%LOCALAPPDATA%` 含非 ASCII，退回 `C:\FlitDesk`（可写性检查 + 回退 `%ProgramData%\FlitDesk`）；并在 UI 提示"工程路径建议使用英文目录"。
- 中期：把 flutter_pty fork 到 `third_party/flutter_pty`（仓库已有 `third_party/xterm` 先例），把三处"字节→WCHAR"改为 `MultiByteToWideChar(CP_UTF8, ...)`，并把 env block 排序；`pubspec.yaml:19` 改为 `path: third_party/flutter_pty`。这是 30 行以内的补丁，收益巨大（否则所有中文用户名用户都不可用）。

**（5）无 PTY 时的 UI**：`ConsoleSession` 增加 `bool ptyAvailable`；终端面板头部显示徽标"基础模式（无 PTY）"，与 l10n key `desktopNoPtyBasicMode`；`interactive` 仍为 `kind == shell`（输入可用），但提示"全屏 TUI（vim/top）不可用"。若 Pipe 模式连 stdin 都不可用（极少数），把 `interactive` 置 false，复用现有只读路径（`global_terminal_panel.dart:233,369,532` 已按 `interactive` 处理）。

**（6）命令归一化重构**：新增 `lib/services/command_normalizer.dart`（纯函数，可单测）：

```dart
sealed class NormalizedCommand {}
class ShellCommand extends NormalizedCommand { final String text; }        // 给 cmd/sh
class ArgCommand extends NormalizedCommand { final ProcessSpec spec; }     // 直接 Process

NormalizedCommand normalizeForWindows(String posixCommand);
```
映射表（必须覆盖）：

| POSIX 形状 | Windows 等价 |
|---|---|
| `mkdir -p 'X' && cd 'X' && REST` | `ArgCommand`：Dart 建目录 + 以 cwd=REST 执行（首选）；退化为 `if not exist "X" mkdir "X" & cd /d "X" && REST` |
| `VAR=val VAR2='...' cmd args` | 环境变量注入到 `ProcessSpec.env`（**不要**拼 `set`） |
| `</dev/null` | 删除（或 `>nul`） |
| `2>&1` | 保留（cmd 支持） |
| `&&` / `\|\|` | 保留（cmd 支持）；`;` → `&` |
| `[ -d X ]` / `[ -f X ]` | `if exist "X"`（目录/文件都适用）；`!` → `if not exist` |
| `rm -rf X` | `if exist "X" rmdir /s /q "X"`（目录）/ `del /f /q "X"`（文件） |
| `find ... -printf` | 不要翻译，调用方改 `LocalFs`（现状已对 project_list/project_files 做了） |
| `chmod` / `chown` / `ln -s` | Windows 无对应（`chmod` 可忽略；符号链接需开发者模式/管理员，暂缓） |
| `bash script.sh` | 桌面端不应存在；若来自 Android 脚本层（build wrapper / setup），改为 Dart（§4.2、P0-6） |
| `stty -echo` | 删除（ConPTY 无此概念，也不影响 flutter run） |
| 多行 `\n` | 合并为 `&` 链（或拆成多次 `Process` 调用，首选） |
| `$HOME` / `~` | 替换为 `DesktopToolchain.home`（**在 Dart 里替换，不要在 cmd 里依赖 `%USERPROFILE%`**） |

**（7）编码**：`chcp 65001` + `SystemEncoding` 兜底解码：
```dart
// console_session.dart:204 附近
.transform(const Utf8Decoder(allowMalformed: true))
```
改为可配置 `encoding`；桌面默认 UTF-8（chcp 65001 后正确），若检测到大量 U+FFFD 则回退 `gbk`（Dart 无内置 GBK，需 `charset`/`fast_gbk` 包，P2；先靠 chcp 解决 95% 场景）。

**（8）exit code**：`cmd /c a && b` 返回最后一条的退出码，`a` 失败则短路返回 a 的码 —— 对 Flutter/git 足够。注意 cmd 内建命令的"成功但非 0"差异（如 `cd` 到不存在目录返回 1，OK）；`2>&1` 合并后 `Shell.exec` 里 `'${r.stdout}${r.stderr}'` 会重复（`desktop_shell.dart:48` 已把两者拼接，若命令自身又 `2>&1` 则 stderr 为空，不会重复）。**建议**在 `ProcessRunner` 里对 stdout/stderr 分别收集，避免重复与乱序。

---

## 7. 设备 / 文件导出分享 / 后台保活 / 代理：Windows 处理建议

### 7.1 设备（ADB）

| 能力 | 现状（Android） | Windows 可行性 | 建议 |
|---|---|---|---|
| 设备枚举 | `adb_ops.dart:117-131` | ✅ `Shell.exec('adb devices -l')` → cmd 找到 `platform-tools\adb.exe` | 保持；注意 USB 需 OEM 驱动（弹提示） |
| `adb connect/pair/disconnect` | `device_connection.dart:192,270,306,381` | ⚠️ `adb pair host:port code` 经 `_normalizeForDesktop` 变双引号 → 可用；但**无线配对需要手机端系统弹窗**（`FlitDevice.startPairing`） | 命令行 `adb pair` 保留；"通知配对"整块隐藏 |
| mDNS 发现 | `FlitDevice.discoverAdb`（`device_connect_page.dart:294`、`device_connection.dart:571`） | ❌ NSD Android API；Dart 侧 catch 返回 `[]`（`flit_device.dart:46-49`） | 依赖"搜索"按钮的路径会一直空 → 改为手动输入 IP:端口 + 最近记录（偏好已存 `adbHost/adbConnectPort`） |
| 配对状态/系统设置跳转 | `pairingStatus/startPairing/openWirelessSettings/pairingReadiness` | ❌ MethodChannel 无实现（页面 catch 弹原文） | 隐藏入口；或实现 Windows 版"adb 二进制管理"页 |
| USB 指南 | `device_usb_guide.dart` | ❌ 文案是手机操作 | 桌面版文案：启用开发者选项/USB 调试 → 插线 → 授权弹窗 → `adb devices` 确认 |
| 运行目标 | `editor_run_controls.dart:536-560`、`project_session.dart:72-93` | ✅ 有设备即可 `flutter run -d <serial>`（`project_actions.dart:232-238`，wrapper 剥离后命令可用） | 保持；无设备时自动 Web |

**P1 改法**：`device_connect_page.dart` 增加 `if (isDesktopPlatform)` 分支：只显示 USB/局域网卡片 + 手动连接表单；隐藏"无线配对指南"按钮与轮询（`:138-178` 的 `_schedulePoll`/`_readPairingStatus` 不再调用）。

### 7.2 文件导出 / 分享 / 安装 APK

Android 语义：`FlitFiles.share/installApk/open` → SAF/FileProvider/系统安装器。Windows 建议新增 `lib/services/desktop_files.dart`：

```dart
class DesktopFiles {
  Future<bool> open(String path);          // ShellExecute: Process.run('cmd.exe',['/c','start','',path])（加引号）
  Future<bool> reveal(String path);        // explorer.exe /select,"<path>"
  Future<bool> share(String path);         // 无系统分享：复制路径+剪贴板 + SnackBar；或打开所在文件夹
  Future<bool> installApk(String path, {String? deviceSerial}); // adb -s <serial> install -r "<apk>"
}
```
UI 侧按平台过滤按钮：
- `file_kind.dart` 的 `cardActions(path)` 增加 `platform` 参数，Windows 上 apk 卡只给"安装到设备（需连接）"与"打开所在文件夹"；其他卡给"打开"与"打开所在文件夹"。
- `app_versions_page.dart:83-95`：Windows 上改为"用浏览器下载"（`Shell.openUrl(asset.url)`），不下载到本地再 share。
- 文案：`installLocally`/`share`/`openWith` 在 Windows 上换成 `openInExplorer`/`installToDevice`。

### 7.3 后台保活 / 通知 / 电池

- `WorkKeepAlive`（`flit_work.dart:17-30`）每次调用都 try/catch，Windows 上是**no-op**（不会崩）→ 保持，无需改。
- `BackgroundAccess.explain`（`background_access.dart:16-24`）会被 `workbench_page.dart:66` 在首次进环境页前调用 → Windows 上应直接 `return`：
  ```dart
  static Future<void> explain(BuildContext context) async {
    if (isDesktopPlatform) return;   // 桌面无需后台保活/通知权限
    ...
  }
  ```
- `settings_page.dart:70-110` 的"通知/电池优化"分组：桌面隐藏（同一 `isDesktopPlatform` 判断），并去掉 `Permission.notification.status` 的假 GRANTED 显示。
- `Permission.notification.status` 在 Windows 恒 GRANTED（读了 `permission_handler_windows` 源码），**任何依赖它做判断的 UI 都会撒谎**，必须整体跳过。

### 7.4 代理（auto_proxy）

- 现状：`AutoProxy` 依赖 `FlitEnv.systemProxy()` / `onSystemProxyChanged`（Android 原生）；Windows 上 `address` 恒 `null` → 开关无效、`applyToDart()` 清空 `HttpOverrides`。
- 建议：新增 `lib/services/system_proxy_windows.dart`：
  ```dart
  Future<String?> readWindowsProxy();   // reg query HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings /v ProxyServer（读 ProxyEnable）
  // 或 netsh winhttp show proxy 解析
  ```
  在 `AutoProxy.load()`（`auto_proxy.dart:24-48`）里 `if (Platform.isWindows) address = await readWindowsProxy(); else FlitEnv...`；`onSystemProxyChanged` 的注册加平台判断（`auto_proxy.dart:14`），Windows 上改用定时/页面 resume 时刷新。
- 注意 `applyToDart` 的 `findProxy` 只影响 Dart `HttpClient`（app 内下载），终端进程靠 `envVars()`（`auto_proxy.dart:80-92`）注入 `HTTP(S)_PROXY` —— git 会读这些变量，所以链路是通的，只要 `address` 能取到。
- 对 git clone 的镜像需求（github_mirror.dart 只作用于 API/Release 资产）：Windows 端建议加设置项"GitHub 加速前缀"，在 clone URL 上做 `https://gh-proxy.com/https://github.com/...`（git 支持该形式），或在 `git config http.<url>.proxy` 里配代理。**现阶段可不做**，列为 P2。

---

## 8. 编辑器 / LSP：Windows 上的 dart analysis server

### 8.1 现状

- `LspClient` 的所有进程能力都经 `FlitLsp`（MethodChannel `flit/lsp` + EventChannel `flit/lspEvents`）：`lsp_client.dart:46,50,73,147,162,313`。
- Android 原生实现（`plugins/flit_lsp/android/.../LspServer.kt:35`）的启动方式是关键参考：
  ```kotlin
  ProcessBuilder(dartBin, "language-server", "--protocol=lsp")
    .directory(File(rootPath))
    .environment().putAll(FlitEnv.environment())
  ```
  `dartBin` = `<home>/toolchains/flutter/current/bin/cache/dart-sdk/bin/dart`（`FlitLspPlugin.kt:57-60`）。
  传输：`Content-Length: N\r\n\r\n<json>`（`LspServer.kt` 的 `send/readLoop`），请求超时 25s，stderr 单独 drain，进程退出推 `flit/serverExited`。
- Windows 上：MethodChannel/EventChannel 无实现 → `FlitLsp.start()` 抛 `MissingPluginException` → `_start` catch → `state=unavailable`（`lsp_client.dart:135-141`）；`FlitLsp.notifications` 的 `onError` 也置 unavailable（`:68-70`）。**不崩，静默降级**；`editor_analysis_status.dart` 会显示 "Dart 基础补全"（本地 `completion_engine.dart` 仍可用），但**没有诊断、签名、快速修复**。

### 8.2 推荐实现（纯 Dart 传输层）

新增：
- `lib/features/editor/lsp/lsp_transport.dart`
  ```dart
  abstract interface class LspTransport {
    Future<bool> start({required String rootPath, required int session});
    Future<String?> request(String method, String paramsJson, {Duration timeout = const Duration(seconds: 25)});
    Future<bool> notify(String method, String paramsJson);
    Stream<dynamic> get notifications;    // 已附加 flitSession 的 JSON 字符串
    Future<void> stop();
    bool get running;
  }
  ```
- `lib/features/editor/lsp/native_lsp_transport.dart`：把现有 `FlitLsp` 调用搬进来（Android 不变）。
- `lib/features/editor/lsp/process_lsp_transport.dart`：桌面实现
  ```dart
  class ProcessLspTransport implements LspTransport {
    ProcessLspTransport(this._dartExe, this._environment);
    Future<bool> start({required String rootPath, required int session}) async {
      _process = await Process.start(_dartExe, ['language-server', '--protocol=lsp'],
        workingDirectory: rootPath, environment: _environment, runInShell: false);
      // stdout: 解析 Content-Length 帧；stderr: 逐行 log；退出: 推 flit/serverExited
    }
  }
  ```
  dart 可执行文件：`DesktopToolchain` 新增
  ```dart
  String get dartExe => '$flutterDir${_sep}bin${_sep}cache${_sep}dart-sdk${_sep}bin${_sep}dart$_exe';   // desktop_toolchain.dart 内，_exe 已有(:59)
  bool get dartSdkReady => File(dartExe).existsSync();
  ```
- `LspClient` 构造改为注入 `LspTransport`（默认按平台选），删除对 `FlitLsp` 的直接引用；其余协议逻辑（initialize/rootUri/capabilities/文档同步）完全复用。

### 8.3 URI 与路径（Windows 细节）

- `LspProtocol.fileUri`（`protocol.dart:49`）用 `Uri.file(path)`：Windows 上 `Uri.file('C:\\a\\b.dart')` → `file:///C:/a/b.dart`（正确，大小写保留）；`pathOfUri` → `C:\a\b.dart`。
- 但工程内路径目前是混合分隔符（§P1-4）→ 必须统一：
  ```dart
  // 建议加在 LocalFs
  String absoluteOf(String root, String relative) =>
      '$root${root.endsWith(Platform.pathSeparator) ? '' : Platform.pathSeparator}'
      '${relative.replaceAll('/', Platform.pathSeparator)}';
  bool samePath(String a, String b) => ...;   // canonical + 大小写不敏感
  ```
  改调用点：`project_documents.dart:84,318,390`、`project_files.dart:48`、`editor_page.dart:178`、`editor_intelligence.dart:58-71` 的 `path` 全部用 `absoluteOf`；`DiagnosticsReport.parse` 后用 `samePath` 过滤。
- `rootUri` 在 Windows 上必须是 `file:///C:/...`（`Uri.file` 已保证）；`workspaceFolders[0].name` 用 `baseName`（`lsp_client.dart:88`）。
- analysis server 的 `processId: null` 保持（`lsp_client.dart:83`），Windows 无需额外处理。
- `textDocument/completion`、`codeAction` 的 `documentChanges` URI 匹配：用 `samePath` 而非 `!=`（`protocol.dart:343`、`lsp_client.dart:330` 一带）。
- 失败兜底：保留 `dartBasicCompletion` 文案与本地 `CompletionEngine`（`editor_analysis_status.dart` 已在 unavailable 时降级显示，无需大改）。

---

## 9. 推荐新增文件与改动清单（可直接照着写）

### 9.1 新增文件

| 文件 | 作用 | 关键 API |
|---|---|---|
| `lib/services/process_runner.dart` | 跨平台一次性进程（数组参数，自动处理 `.bat`） | `Future<({int code, String out})> run(ProcessSpec, {int timeoutMs})`；`bool needsShell(String exe)` |
| `lib/services/command_normalizer.dart` | POSIX→Windows 命令归一化（纯函数、可单测） | `NormalizedCommand normalizeForWindows(String cmd)` |
| `lib/services/git_process.dart` | Git 参数数组执行器 | `Future<GitResult> run(List<String> args)` |
| `lib/services/git_credentials.dart` | app 私有 gitconfig + credentials 落地 | `save/load/clear/globalConfigPath` |
| `lib/services/github_device_flow.dart` | 纯 Dart OAuth 设备流 | `requestCode()`, `poll()` |
| `lib/services/desktop_directory_picker.dart` | 目录/文件选择（file_selector） | `pickDirectory()`, `pickFile()` |
| `lib/services/desktop_files.dart` | 打开所在文件夹/外部程序/安装 APK | `open/reveal/share/installApk` |
| `lib/services/system_proxy_windows.dart` | 读 WinINET 代理 | `readWindowsProxy()` |
| `lib/features/terminal/pty_session_process.dart` | 从 `pty_launcher.dart` 抽出的 PTY 实现 | — |
| `lib/features/terminal/pipe_session_process.dart` | 无 PTY 降级实现 | — |
| `lib/features/editor/lsp/lsp_transport.dart` + `native_lsp_transport.dart` + `process_lsp_transport.dart` | LSP 传输抽象与桌面实现 | 见 §8.2 |

### 9.2 现有文件改动点（按文件）

| 文件 | 改动 |
|---|---|
| `lib/services/desktop_toolchain.dart` | 新增 `dartExe`、`dartSdkReady`；`_canRun` 支持 `.bat/.cmd`；`defaultHome()` ASCII 兜底（§6.3-4） |
| `lib/services/desktop_shell.dart` | `which()` 返回真实后缀路径；`_runSimple` 走 `ProcessRunner`；`openUrl` 改 `rundll32`；`_posixShim` 补 `head/od/grep` 与常见形状（或让调用方改 Dart） |
| `lib/services/shell.dart` | 新增 `runProcess(ProcessSpec)` 门面；`isDesktopPlatform` 保持不变（供测试注入，见 §10.3） |
| `lib/services/git_repo.dart` | 删除 `command()` 字符串，改 `List<String> args` + `GitProcess` |
| `lib/features/git/project_git.dart` | `_command` 走 `repo.run(args)`；终端显示用 `displayCommand` |
| `lib/features/git/github_account.dart` | 删除 gh 依赖；改用 `GithubDeviceFlow`/PAT + `GitCredentials`；`refresh()` 用 `/user` 接口 |
| `lib/features/projects/create_project_page.dart` | 桌面端执行改 Dart（§4.2）；位置预览显示真实 root |
| `lib/features/projects/clone_project_page.dart` | 桌面端 `gitCloneArgs` + Dart mkdir + env；SSH→HTTPS 提示 |
| `lib/features/projects/projects_page.dart` | 增加"打开目录"；兜底 root 改 `DesktopToolchain().projectsDir`；存储说明文案平台化 |
| `lib/features/workspace/project_session.dart` | `name` 用 `baseName`；`_detectKind`/`_ensureDeps` 可保留（shim 已覆盖） |
| `lib/features/workspace/project_actions.dart` | `dartExeConfiguration` 的 name/mkdir 平台化（或改 ArgCommand） |
| `lib/features/workspace/project_documents.dart` | 路径统一 `absoluteOf`；保存/读取桌面分支已 OK |
| `lib/features/workspace/project_files.dart` | `sniffFile` 替换 `sniffCommand`；`_relative` 用统一路径 |
| `lib/features/editor/file_kind.dart` | 新增 `sniffFile`；`cardActions` 增加平台参数 |
| `lib/features/editor/widgets/file_tree_drawer.dart` | 桌面隐藏共享存储页签；名称 `baseName`；浏览根改 `USERPROFILE` |
| `lib/features/editor/widgets/file_card.dart` | 平台化动作（`DesktopFiles`） |
| `lib/features/editor/lsp/lsp_client.dart` | 注入 `LspTransport`；路径比较 `samePath` |
| `lib/features/editor/lsp/protocol.dart` | 新增 `samePath`/`normalizePath`；`documentChanges` 匹配用它 |
| `lib/features/terminal/console_session.dart` | 归一化迁到 `command_normalizer.dart`；`_cmdQuotes` 替换为 `quoteForCmd`；解码器可配置；`killTree` |
| `lib/features/terminal/pty_launcher.dart` | `_startDesktop` 加 `chcp 65001` + 降级；`_PtyProcess.kill` 用 `killTree` |
| `lib/features/terminal/pty_session.dart` | 桌面端去掉 `bin/bash` 门禁 |
| `lib/features/run/web_runner.dart` | 删除 shell 前缀，改 Dart 步骤 + 参数数组 |
| `lib/features/environment/android_build_wrapper.dart` | `_check` 桌面分支纯 Dart；`_repair` 桌面走 `DesktopToolchain.install` |
| `lib/services/auto_proxy.dart` | 平台分支 + Windows 代理读取 |
| `lib/services/background_access.dart` | 桌面直接 return |
| `lib/features/settings/settings_page.dart` / `app_versions_page.dart` | 隐藏后台/APK 安装分组；更新改浏览器 |

### 9.3 依赖新增

- `file_selector: ^1.1.0`（官方，支持 windows/linux/macos/android/ios）：用于"打开已有目录"与"导入文件"。替代 SharedStorageAccess 的共享存储浏览。
- 可选 `charset`/`fast_gbk`：仅在需要 GBK 解码时（chcp 65001 解决大部分，先不加）。
- 不需要 `webview_windows`（保持"系统浏览器打开"更稳，P2 再评估）。
- `archive` 不需要（环境层用 `tar.exe`/`Expand-Archive`，见 01 报告）。

---

## 10. 可暂缓功能清单（明确标记"Windows 暂不支持" + UI 文案位置）

> 原则：**不留崩溃路径**。每条都要么隐藏入口，要么禁用按钮 + 说明，要么替换为桌面等价物。

| # | 功能 | 位置 | Windows 处理 | 建议文案（l10n key） |
|---|---|---|---|---|
| S1 | 无线调试配对（NSD + 系统配对弹窗 + 通知） | `device_connect_page.dart:205-300`、`device_pairing_guide_page.dart` 全页 | 隐藏"无线配对指南"入口与自动发现；保留手动 `adb pair` 输入 | `windowsWirelessPairingUnsupported` = "Windows 暂不支持无线调试配对，请用 USB 数据线连接，或在命令行执行 adb pair" |
| S2 | 共享存储浏览（SAF/权限） | `file_tree_drawer.dart:141-160,200-205`、`shared_storage_access.dart` | 隐藏 `_Loc.storage`；改 `desktop_directory_picker` | `desktopImportFromDisk` = "从磁盘导入文件" |
| S3 | APK 安装（未知来源授权）/系统分享 | `file_card.dart:160-200`、`app_versions_page.dart:83-95` | 改 `adb install -r`（需连设备）；无设备时禁用 + 说明；分享→打开所在文件夹 | `installApkNeedsDevice` / `openInExplorer` |
| S4 | 应用自更新（下载 APK → 安装） | `app_versions_page.dart`、`app_releases.dart` | 改为"用浏览器下载"，或隐藏"更新"分组 | `updateViaBrowser` |
| S5 | 前台保活服务/电池优化/通知权限 | `background_access.dart`、`settings_page.dart:70-110`、`flit_work` | 桌面直接跳过（`isDesktopPlatform` 提前 return）；隐藏设置分组 | `desktopNoBackgroundService` |
| S6 | 跟随系统代理 | `auto_proxy.dart` | 先读 WinINET（P1），或隐藏开关 | `desktopProxyManualHint` |
| S7 | 内嵌 WebView 预览 | `web_run_page.dart:78-84` | 已降级为"显示 URL + 浏览器打开"（保留） | 把 `:35-53` 硬编码中文迁到 ARB：`desktopNoEmbeddedWebView` |
| S8 | bash/Termux 脚本族（构建 APK、工具链管理、环境检查） | `android_build_wrapper.dart:185,263`、`setup_runner.dart`、`environment_controller.dart:284,506` | 桌面全部走 Dart（01 报告的环境层 + 本文 P0-6） | 无需新增（内部错误不上 UI） |
| S9 | 系统设置页直达（`FlitEnv.openSettings`） | `shell.dart:67-70` | Windows 返回 false；调用方隐藏入口 | — |
| S10 | 软键盘/IME 相关终端控件 | `global_terminal_panel.dart:448,532` | 桌面隐藏虚拟键盘行 | — |
| S11 | 多版本工具链切换/删除 | `environment_controller.dart:216-219,270-273` | 已提示不支持（文案硬编码）→ 迁 ARB + 隐藏 | `desktopSingleToolchain` |
| S12 | 共享存储权限申请弹窗 | `shared_storage_access.dart:22-63` | 桌面不调用（S2 已隐藏入口） | — |

**l10n 落地方式**：`l10n.yaml` 指定 `template-arb-file: app_zh.arb`、`arb-dir: lib/l10n`；新增 key 要**同时**改 `lib/l10n/app_zh.arb`（模板）和 `lib/l10n/app_en.arb`，然后 `flutter gen-l10n` 重新生成 `app_localizations*.dart`。**不能只改生成的 dart**（会被覆盖）。

---

## 11. 测试清单

### 11.1 现状（CI 实测，run 42348982433 @ windows-latest）

- ✅ `flutter build windows --release` 通过（flutter_pty 的 ConPTY 原生代码在 windows runner 上编译通过，说明不需要 Rust、只需 MSVC —— MSVC 是 Flutter Windows 构建的既有要求）。
- ✅ `flutter test test/local_fs_test.dart`（阻断步骤）通过 → `LocalFs` 的 Windows 语义（canonical/isInside/scanProjects/listTree）是可信的，可作为其他改造的参照实现。
- ⚠️ `flutter test` 全量：**231 passed / 96 failed**，但步骤显示 success，原因是 workflow 用 `flutter test | Tee-Object -FilePath test.log`（管道退出码来自 `Tee-Object`）。日志末行：`::error::231 tests passed, 96 failed.`
- 96 个失败分桶（逐条读过 `test.log`）：
  1. **测试假设 Android 的 MethodChannel mock，而桌面分支绕过 mock 跑真实进程/文件**（~60 条）：`editor_page_test`（找不到 `CodeField`）、`run_controls_test`（target 空）、`device_connect_page_test`/`device_connection_test`（真实 `adb` 不存在 → "无法确认连接状态，请先安装 ADB"）、`settings_pages_test`（`pumpAndSettle` 超时）、`project_storage_test`、`web_preview_test`（桌面无 WebView，返回 fallback）。
  2. **真实 POSIX 依赖**（~8 条）：`git_repo_test`、`project_git_test`、`setup_runner_test` 报 `Bad state: Windows Subsystem for Linux has no installed distributions.` —— 这正是 `bash` 在 Windows 解析到 `C:\Windows\System32\bash.exe`（WSL 存根）的直接证据，也印证了 §3 P0-3/P0-6 的根因。
  3. **路径/POSIX 断言**（~6 条）：`project_files_test` 期望 `.../missing` 实得 `...\missing`；`android_build_wrapper_test` 期望 `bash "$HOME/..."` 实得剥离后的命令。
  4. **`DesktopShell.exec` 在 fake_async 里创建真实定时器**（~4 条）：`git_panel_test`、`run_controls_test` 报 `Pending timers: Timer(duration: 0:00:15) ... DesktopShell.exec (desktop_shell.dart:47)`，以及 `TimeoutException after 0:00:30`。
  5. **Unix 权限位/平台差异**（~2 条）：`project_files_test "atomic save preserves executable bits"` 期望 493(0755) 实得 438(0666)。
  6. **镜像常量测试**（1 条）：`github_mirror_test` 期望字面量前缀，与 `String.fromEnvironment` 的默认值组合不符（测试自身假设问题）。

**含义**：Windows CI 现在**没有可信的功能回归基线**；但 `build windows` 绿说明编译层没问题。建议（与 03 报告联动）：把 `flutter test` 改成阻断，同时按下节先补"平台注入 seam"，否则会一片红。

### 11.2 需要补的纯 Dart 单测（全部可离线、无窗口）

| 测试文件（建议） | 覆盖点 |
|---|---|
| `test/command_normalizer_test.dart` | `mkdir -p 'X' && cd 'X' && rest` → ArgCommand cwd；`VAR=val cmd` → env；`</dev/null` 移除；`[ -d X ]`→`if exist`；`rm -rf`→`rmdir /s /q`；`;`→`&`；多行合并；`$HOME`/`~` 替换；未知 POSIX 命令返回 null（调用方兜底报错） |
| `test/process_runner_test.dart` | `.bat/.cmd` → `needsShell` true；`.exe` false；timeout → code 124；stdout/stderr 分离不重复；环境变量注入（含中文值，验证不经过 shell） |
| `test/git_process_test.dart` | `run(['status','-z'])` 的 argv 顺序与 `--no-pager/--literal-pathspecs/-c` 前缀；`GIT_TERMINAL_PROMPT=0`/`GIT_CONFIG_GLOBAL` 在 env；工作目录=repo root；不含 `LC_ALL`/`-C`/`GIT_SSH_COMMAND`（字符串断言，防回归） |
| `test/git_credentials_test.dart`（tmp 目录） | 写 gitconfig 内容（credential.helper 指向 store --file、user.name/email）；写 git-credentials 行格式；`load` 读回；`clear` 只删目标 host；路径用 `Platform.pathSeparator` |
| `test/github_device_flow_test.dart`（注入 fake HttpClient） | `requestCode` 解析 `device_code/user_code/verification_uri/interval/expires_in`；`poll` 处理 `authorization_pending`/`slow_down`/`expired_token`/`access_denied`/成功；JSON 错误不抛未捕获异常 |
| `test/path_utils_test.dart` | `baseName('C:\\a\\b')=='b'`、`baseName('C:/a/b')=='b'`、根路径、尾分隔符；`absoluteOf(root, 'a/b')` 在 Windows 上含 `\`；`samePath('C:\\A\\b','c:/a/B')` true（大小写不敏感） |
| `test/lsp_protocol_test.dart`（补现有 `lsp_client_test.dart`） | `fileUri('C:\\a b\\x.dart')=='file:///C:/a%20b/x.dart'`；`pathOfUri` 往返；`samePath` 对 mixed separator/大小写；`documentChanges` 匹配；`positionToOffset/offsetToPosition`（已有） |
| `test/file_kind_test.dart`（补） | `sniffFile`：含 `0x00` → binary；纯 UTF-8 文本 → code；空文件 → code；中文 UTF-8 不误判；`cardActions('a.apk', windows)` 不含 share/installApk |
| `test/local_fs_test.dart`（补） | `listTree` 保留 `.gitignore`（P1-11）；`absoluteOf`/`baseName`；`isInside` 大小写；`scanProjects` 排除 `build/.dart_tool/.git` |
| `test/console_session_test.dart`（补 `session_model_test.dart`） | 归一化后的命令文本；`killTree` 在非 Windows 走进程组分支（平台注入 fake）；`ptyAvailable=false` 时 `interactive` 行为 |
| `test/create_project_test.dart`（补） | `flutterCreateArgs`/`dartCreateArgs` 数组断言（含 `--description` 中文、`-a java`、`--empty`、`--platforms=a,b`）；桌面路径不再生成 `mkdir -p` 字符串 |
| `test/clone_project_test.dart`（新） | `gitCloneArgs`（branch/shallow/url/dir）；SSH→HTTPS 提示判定 |
| `test/web_runner_command_test.dart` | 桌面 Web 启动改为 ArgCommand 后：无 `stty`、无 `[ ! -d ]`、cwd=project root、port/hostname 参数正确 |

### 11.3 测试可运行性前提（重要）

现在 60+ UI 测试在 Windows 上失败，根因是 `Shell`/`isDesktopPlatform` 不可注入。建议加最小 seam（与 03 报告联动）：

```dart
// lib/services/platform_profile.dart
class PlatformProfile {
  const PlatformProfile({required this.isDesktop, required this.isWindows, this.isAndroid = false});
  static PlatformProfile current = PlatformProfile(
    isDesktop: !Platform.isAndroid, isWindows: Platform.isWindows, isAndroid: Platform.isAndroid);
}
```
把 `isDesktopPlatform`（`shell.dart:19`）与 `Platform.isWindows` 热点改为读 `PlatformProfile.current`，测试里 `setUp(() => PlatformProfile.current = PlatformProfile(isDesktop: false, isWindows: false, isAndroid: true))` 即可让现有 Android 语义测试继续通过；再加一组 `isDesktop: true` 的 Windows 测试验证桌面分支。**这一步不做，Windows CI 上的 `flutter test` 无法阻断。**

### 11.4 真机验证清单（本机无 flutter/dart，未验证）

1. 中文用户名下 `flutter --version` 预检（P0-1/P0-2：验证 `.bat` 直跑确实失败，`runInShell:true` 是否解决）。
2. 中文路径下 PTY 启动（P0-8：预期 `Failed to create process`）；确认 ASCII home 兜底有效。
3. 停止/关闭会话后 `Get-Process dart,java,gradle` 是否残留（P0-8 kill 树）。
4. `permission_handler` Windows 恒 GRANTED（读源码结论，需运行时确认）。
5. `gh` 是否存在、`git clone` 走 `credential.helper=store` 能否在无 GCM 的 MinGit 上非交互 push（§5.3 是方案核心，必须实测）。
6. `chcp 65001` 后 flutter/gradle 中文输出是否正常（P0-8 编码）。
7. `adb devices` 是否需要额外 driver；`adb pair` 在 Windows 是否可用。
8. `dart language-server --protocol=lsp` 在 Windows Flutter SDK 的 `dart.exe` 上是否可用（LSP 方案的前置）。

---

## 12. 附录：本报告用到的关键证据索引

| 主题 | 文件:行号 |
|---|---|
| 平台总闸 | `lib/services/shell.dart:19` |
| Shell→DesktopShell | `lib/services/shell.dart:22-96`、`lib/services/desktop_shell.dart:22-58` |
| POSIX shim 覆盖面 | `lib/services/desktop_shell.dart:204-300`（7 种形状） |
| which() bug | `lib/services/desktop_shell.dart:77-95`（`:88-92` 拼 `.exe`） |
| `_runSimple` 无法跑 .bat | `lib/services/desktop_shell.dart:311-325` |
| `.bat` 就绪判定失败 | `lib/services/desktop_toolchain.dart:92,106-120` |
| 环境未就绪 gating | `lib/features/environment/environment_controller.dart:436-438,549-560`、`lib/features/projects/projects_page.dart:400-425` |
| 创建项目命令 | `lib/features/projects/create_project_page.dart:36-52`（`:37,50`） |
| 创建预检 | `lib/features/projects/create_project_page.dart:118-146`、`:513` |
| 克隆命令 | `lib/features/projects/clone_project_page.dart:38-50`（`:47-49`） |
| 工程列表扫描 | `lib/features/projects/project_list.dart:72-85`、`lib/services/desktop_shell.dart:270-288` |
| 文件树命令 | `lib/features/workspace/project_files.dart:26-40`、`lib/services/desktop_shell.dart:290-297` |
| listTree 跳过 dotfile | `lib/services/local_fs.dart:196-224`（`:210-212`） |
| 文档读写桌面分支 | `lib/features/workspace/project_documents.dart:111-166`（`:113,145`） |
| 混合路径拼接 | `lib/features/workspace/project_documents.dart:84,318,390`、`lib/features/workspace/project_files.dart:48`、`lib/features/editor/editor_page.dart:178` |
| 诊断被丢弃 | `lib/features/editor/lsp/lsp_client.dart:227-232`、`lib/features/editor/controller/editor_intelligence.dart:21-25` |
| LSP 通道调用 | `lib/features/editor/lsp/lsp_client.dart:46,50,73,147,162,313` |
| Android LSP 启动参数 | `plugins/flit_lsp/android/src/main/kotlin/cc/lycstar/flit/lsp/LspServer.kt:35`、`FlitLspPlugin.kt:57-60` |
| Git 命令拼装 | `lib/services/git_repo.dart:42-52`（`:51`） |
| Git 面板执行 | `lib/features/git/project_git.dart:107-120`、`:122-224` |
| GitHub 登录命令 | `lib/features/git/github_account.dart:41-45,65-75,84` |
| Git 镜像 | `lib/services/github_mirror.dart:17-36` |
| 归一化/引号 | `lib/features/terminal/console_session.dart:115-152`（`_cmdQuotes`、`_normalizeForDesktop`） |
| 会话停止 | `lib/features/terminal/console_session.dart:279-300` |
| 默认 shell 门禁 | `lib/features/terminal/pty_session.dart:17-27`（`:22-25`） |
| PTY 桌面分支 | `lib/features/terminal/pty_launcher.dart:64-93`（`:74-91`） |
| PTY kill | `lib/features/terminal/pty_launcher.dart:108-119` |
| Web 预览命令 | `lib/features/run/web_runner.dart:86-96` |
| WebView 降级 | `lib/features/run/web_run_page.dart:14-63,78-91` |
| Web 构建入口 | `lib/features/editor/widgets/editor_run_controls.dart:381-385`、`lib/features/workspace/project_actions.dart:32-38` |
| APK 构建 wrapper | `lib/features/environment/android_build_wrapper.dart:174-221`（`:185`）、`:263` |
| 设备连接执行 | `lib/features/device/device_connection.dart:104-110,192-197,270-274,306,381` |
| 配对页 | `lib/features/device/device_connect_page.dart:138,205-300`、`device_pairing_guide_page.dart:54,133,203` |
| 共享存储权限 | `lib/services/shared_storage_access.dart:10-20,22-63` |
| 共享存储浏览 | `lib/features/editor/widgets/file_tree_drawer.dart:141-160,200-205,314,376,497,539` |
| 后台保活 | `lib/services/background_access.dart:16-24,52-95`、`plugins/flit_work/lib/flit_work.dart:17-30` |
| 自动代理 | `lib/services/auto_proxy.dart:14,24-48,80-92` |
| 文件分享/安装 | `lib/features/editor/widgets/file_card.dart:155-200`、`lib/features/settings/app_versions_page.dart:83-95` |
| 嗅探命令 | `lib/features/editor/file_kind.dart:64-67`、`lib/features/workspace/project_files.dart:44-53` |
| 工程名 split('/') | `lib/features/workspace/project_session.dart:34`、`lib/features/workspace/project_actions.dart:267`、`lib/features/editor/widgets/file_card.dart:129`、`lib/features/editor/lsp/lsp_client.dart:88` |
| flutter_pty 版本 | `pubspec.lock:153-160`、`pubspec.yaml:19` |
| flutter_pty Windows 实现 | pub 归档 `flutter_pty-0.4.2`：`pubspec.yaml`（windows ffiPlugin）、`windows/CMakeLists.txt`、`src/flutter_pty_win.c`（CreatePseudoConsole/ResizePseudoConsole、Sleep(1000)、字节→WCHAR）、`lib/flutter_pty.dart:186-190`（kill=Process.killPid） |
| permission_handler_windows 语义 | pub 归档 `permission_handler_windows-0.2.1`：`windows/permission_handler_windows_plugin.cpp`（checkPermissionStatus→GRANTED；requestPermissions→全 GRANTED） |
| CI 证据 | Actions run `42348982433`（job `128332845517`）：`flutter build windows` success；`build-logs` artifact 中 `test.log` 末行 `::error::231 tests passed, 96 failed.`；`analyze.log` "No issues found!" |

---

## 13. 一句话交接

功能层不是"重写"，而是**三处换实现 + 六个入口收口**：
- 换实现：① `git_repo/github_account` → 参数数组 + 私有凭据；② `web_runner` + `android_build_wrapper` 的 bash 命令 → Dart 步骤；③ LSP MethodChannel → 纯 Dart `Process` 传输。
- 收口：`.bat` 执行与 `which()`（P0-1/2）、默认 shell 门禁（P0-7）、PTY 非 ASCII/kill 树（P0-8）、命令归一化（P0-3/4/5/6）、共享存储/配对/分享的 UI 隐藏（S1/S2/S3）、测试 seam（§11.3）。

按 §9.2 的改动列表逐文件落地，配合 01 报告的环境层修复，即可达成"创建 → 编辑 → 终端 → Git → 推送 GitHub → 出 APK/Web"的最小闭环。

---

## 14. 补证与置信度（写完初稿后追加）

### 14.1 新增硬证据：flutter_pty 确实被编译进 Windows 包

CI run `42348982433` 的 job log（`Package artifact` 步骤，2026-11-07T06:58:15Z，`build\windows\x64\runner\Release` 列表）包含：

```
flit.exe                    91136
flutter_pty.dll             18944
flutter_windows.dll      21289472
msvcp140.dll / vcruntime140*.dll ...
```

→ 说明：①`windows/CMakeLists.txt` + `src/flutter_pty_win.c` 的 ConPTY 实现在 CI 的 MSVC 环境里编译成功；②产物里带着 `flutter_pty.dll`，运行时 `DynamicLibrary.open('flutter_pty.dll')`（`lib/flutter_pty.dart:11-19`）能找到。
因此"flutter_pty 是否支持 Windows"**不再是风险项**，剩余风险全是运行期语义（§6.1 的非 ASCII、kill、编码）。

### 14.2 置信度分级

| 断言 | 置信度 | 依据 | 验证方法 |
|---|---|---|---|
| `.bat` 不能用 `runInShell:false` 执行（Dart Windows 走 `CreateProcess`） | 高（推断，未实测） | dart:io 文档/实现：批处理必须经 `cmd.exe` 解释 | §11.4-1，一行 probe：`Process.run('C:\\...\\flutter.bat', ['--version'], runInShell: false)` 对照 `runInShell: true` |
| PTY 下非 ASCII env/cwd 乱码 | 高 | `src/flutter_pty_win.c` 三处 `(WCHAR)char` 逐字节扩宽 | 中文用户名机器上建工程并开会话 |
| PTY `kill` 不杀进程树、不关 ConPTY | 高 | `lib/flutter_pty.dart:186-190` + win.c 无 `ClosePseudoConsole` | 跑 `flutter build apk` 后关闭会话，`Get-Process java,dart` |
| permission_handler 在 Windows 恒 GRANTED | 高 | `permission_handler_windows-0.2.1` 的 `checkPermissionStatus` / `requestPermissions` | 运行时看"共享存储"页签是否直接进 `/storage/emulated/0` |
| `git_repo.command()` 在 cmd 必失败 | 高 | POSIX 变量前缀 + 单引号；cmd 语法 | 打开任意工程看 Git 面板错误文本 |
| `flit_lsp` 在 Windows 无实现 → LSP 不可用 | 确定 | `plugins/flit_lsp/` 只有 `android/`；Dart 侧只有 MethodChannel | 运行时 `MissingPluginException`（被 catch 成 unavailable） |
| 诊断因混合分隔符被丢弃 | 中高 | `Uri.toFilePath()` 返回 `\`；`acceptsDiagnostics` 用 `==` | 单测 `samePath`；真机看编辑器有无波浪线 |
| 创建项目在 Windows"可工作"（归一化正则命中） | 中高 | `console_session.dart:132-139` 正则与 `buildFlutterCreateCommand` 结构匹配 | 真机点一次"新建项目"看终端输出 |
| 克隆页预检正常（git 是 .exe） | 中高 | `_runSimple('git')` 能执行 .exe | 真机看预检行 |

### 14.3 澄清：`Shell.exec` 的中文解码其实大概率是好的

`DesktopShell.exec` 用 `stdoutEncoding: const SystemEncoding()`（`desktop_shell.dart:44-45`）。Windows 中文系统上 `SystemEncoding` = ANSI 代码页（CP936/GBK），与 cmd 子进程的输出编码一致 → **`Shell.exec` 返回的中文（adb/git/cmd 报错）大概率正常**。
乱码风险集中在 **PTY 路径**：`console_session.dart:200-204` 强制 `Utf8Decoder(allowMalformed:true)`，而 cmd 子进程可能按 GBK 写原始字节 → 需要 `chcp 65001`（§6.3-2）。不要把这两条路径混为一谈，也不要为了"修编码"把 `Shell.exec` 改成 UTF-8 解码（那才会把现在正常的中文弄坏）。

### 14.4 如何复现 CI 的 96 个失败

任意 Windows 机器：
```bash
flutter create --platforms=windows --project-name flit --org cc.lycstar .
flutter pub get
flutter test            # 末行会打印 "N tests passed, M failed."
```
**不要**用 `flutter test | Tee-Object -FilePath test.log`（PowerShell 管道退出码来自 `Tee-Object`，永远 0）——这正是 CI 步骤显示 success 的原因（见 03 报告）。

### 14.5 与另外两份报告的分工

- 环境层（就绪判定、工具链安装、下载/解压/校验、`DesktopToolchain.status()` 的 `.bat` 修复）：见 `01-environment.md`。
- CI / 打包 / 发布 / 桌面外壳 UX / 测试阻断策略：见 `03-build-ci-ux.md`。
- 本文只在交界处给"功能入口被谁卡住"的指针（P0-1、P0-6、S8），实现细节不重复；`flutter_pty` 原生层补丁（`third_party/flutter_pty`）落在本文 §6.3-4，因为它是终端功能的前置。