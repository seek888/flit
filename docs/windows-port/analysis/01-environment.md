# 01 · Windows 环境层与工具链缺口分析

- 分析对象：`windows/full-desktop`（HEAD `b02a4cc`，工作树干净）
- 范围：`lib/features/environment/*`、`lib/services/{desktop_toolchain,desktop_shell,shell,local_fs,app_releases,github_mirror}.dart`、`assets/scripts/*.sh`、`pubspec.yaml`/`pubspec.lock`、`.github/workflows/windows-build.yml`、`plugins/*`
- 方法：只读静态精读 + grep；本机无 dart/flutter，**未执行任何编译或测试**；用 GitHub Actions 日志做基线（见 §8.1）
- 结论一句话：Windows 的「桌面壳」已经可用（能编译、能起窗口、终端走 cmd.exe、文件层与 WebView 降级都已平台化），但**「环境层」只完成了一半**——安装器有骨架却不可靠/不可验证，检测器会把首次安装判死，构建前的组件检查仍然硬编码 bash。

---

## 0. TL;DR（8 条）

1. **代码比 README 新**。`windows/full-desktop` 已有 `DesktopShell`/`DesktopToolchain`/`LocalFs`、`EnvironmentController` 的 5 处桌面分支、PTY 的 `_startDesktop`、Web 预览降级、Windows CI。README/CI release note 里「环境安装、构建 APK、ADB 尚未移植」在**环境层仍然成立**，但原因不是「没写」，而是**写了但跑不通**。
2. **环境就绪判定会稳定失败**：`DesktopToolchain.status()` 用 `flutter --version` 探测 Flutter（25s 超时），而首次运行要 bootstrap Dart SDK/引擎（分钟级）；桌面又把 `flutter_warmup` 硬标 DONE，没有预热阶段 → Flutter 永远 MISSING（`desktop_toolchain.dart:92,106-120`；`environment_controller.dart:541-560`）。
3. **APK 构建在 preflight 就被判死**：`AndroidBuildWrapper._check()` 硬编码 `bash "$HOME/.flit/scripts/android_components.sh"`，桌面 `Shell.exec` 把它交给 `cmd.exe /c`，`bash` 不存在 → 抛 `StateError` → 构建立即失败（`android_build_wrapper.dart:185,187-193` → `project_actions.dart:309-326` → `editor_run_controls.dart:363-376`）。
4. **Git 会阻断整链**：MinGit 地址来自 `https://api.github.com/...`（**未加 `GithubMirror` 镜像**，国内几乎不可达），而「复用系统 git」是**死代码**（`_canRun('git.exe')` 先 `File('git.exe').existsSync()` 恒 false）→ `flutter_tools` FAILED → `_blockAfter` 把后面阶段全 BLOCKED（`desktop_toolchain.dart:93-95,106-107,279-297`；`environment_controller.dart:735-749,824-836`）。
5. **下载层没有校验、没有进度、没有超时**：`_download` 从不调用 `onProgress`，缓存判据是「文件 >1MB 就算下好了」，没有 SHA-256 校验；半截包会永久卡住（`desktop_toolchain.dart:338-362,344`）。这与 Android 侧「SHA-256 不通过不收货」的协议完全不一致（`docs/runtime-environment.md:15,94`）。
6. **不需要新增 `archive` 依赖**：解压继续用 Windows 自带 `tar.exe`（bsdtar，Win10 1803+）为主、`powershell Expand-Archive` 单命令兜底即可；`archive` 只建议作为 **dev_dependency**（测试构造 zip fixture）。见 §4.3。
7. **状态机可以完全对齐**，不需要改 `__STAGE__` 协议：把桌面逻辑收进新的 `DesktopSetupRunner`，用类型化事件发 `__STAGE__/__VER__`，controller 的 `_onPtyText` 解析路径保持不变。建议新文件见 §4.1/§4.5。
8. **测试基线是坏的**：最新 Windows CI（run `42348982433`）阻断步骤只跑 `local_fs_test`（10 passed），全量 `flutter test` 是 **231 passed / 96 failed**，且 `continue-on-error` 掩盖了它（`windows-build.yml:40-49`，日志 §8.1）。根因之一是 `isDesktopPlatform = !Platform.isAndroid`（`shell.dart:19`）让**所有 Android 分支测试在桌面测试宿主上走桌面分支**，mock 全失效。这也是 Windows 移植必须先补的测试 seam。

---

## 1. 现状盘点（逐文件）

### 1.1 平台边界：一个全局布尔值

```dart
// lib/services/shell.dart:19
bool get isDesktopPlatform => !Platform.isAndroid;
```

- 语义是「非 Android 即桌面」，**Linux/macOS 桌面也会被当成 Windows 路径处理**（`desktop_toolchain.dart:140,169` 下载 `windows/x64` 与 `commandlinetools-win-*`）。当前只承诺 Windows，但这个定义会误伤其它桌面平台，也把测试宿主（Linux/Windows）全部推进桌面分支。
- 门面 `Shell`（`shell.dart:22-97`）已经把 `bootstrapStatus / deployBootstrap / exec / sha256OfFile / openUrl / openSettings` 二分；桌面额外提供 `hasBinary / which / environment / revealDirectory`（`shell.dart:72-96`）。
- 「桌面判断」散落在 6 个文件 13 处（`grep -n isDesktopPlatform`）：environment_controller（5）、environment_status（1）、console_session（1）、pty_launcher（1）、web_run_page（1）、project_documents（2）、file_ops（4）、shell（8）——没有单一注入点，这是测试不可移植的根源。

### 1.2 `lib/features/environment/` 逐文件

| 文件 | 行数 | 职责 | Windows 现状 | 关键位置 |
| --- | --- | --- | --- | --- |
| `environment_controller.dart` | 837 | 安装编排 + 阶段状态机 + 终端会话 | 有桌面分支，但依赖 `DesktopToolchain`；桌面语义散落 5 处 | `20-70` 阶段定义、`112-141` 标记解析、`396-434` PTY 行解析、`441-494` 刷新、`496-525` 已装列表、`541-560` 桌面免检+检测、`563-635` 桌面按阶段安装、`685-776` 一键安装、`792-822` 阶段执行 |
| `setup_runner.dart` | 185 | 把 16 个 `.sh` + `env.sh` 写进 `$HOME/.flit`；拼装安装命令 | **桌面仍在写脚本**（无用）；命令全是 bash | `32-49` 脚本清单、`51-52` 路径、`55-74` 原子部署、`77-126` env.sh、`128-142` bootstrap/stage 命令、`144-184` 安装命令 |
| `bootstrap_installer.dart` | 85 | 下载 bootstrap zip → sha256 → `Shell.deployBootstrap` | 桌面 `deployBootstrap` 直接返回 true（空实现） | `10-85`；`78-81` 调 deploy |
| `environment_status.dart` | 112 | 只读快照；`inspect()` 供首页/设置页 | 有 `_inspectDesktop`，但映射逻辑与 controller 重复 | `22-23` ready、`48-52` 130s 超时、`56-82` 桌面检测、`84-111` 脚本检测 |
| `toolchain_catalog.dart` | 344 | GitHub Releases 精确 tag 解析 + 摘要 | 纯数据/网络层，跨平台可用；但资产全是 **aarch64-linux-android** | `27-46` 常量与 bootstrap、`48-114` 组件表、`124-147` resolve、`247-253` sha 解析 |
| `toolchain_component.dart` | 77 | 组件→版本列表/安装匹配 | 纯逻辑，可用 | `23-31` 组件表、`56-77` downloads/matches |
| `installed_toolchain.dart` | 72 | `__TOOL__` 行解析/展示 | 纯逻辑，可用；桌面没有生产者 | `52-71` parse |
| `android_build_wrapper.dart` | 554 | APK/设备运行前补包（唯一入口） | **不可用**：探测/补装全 bash；诊断正则假定了 Linux 路径 | `51-57` 可注入 probe、`174-220` `_check`、`222-318` `_repair`、`320-336` `_installCommand`、`352-382` gradle 字面量解析（可复用）、`385-553` 诊断 |
| `environment_page.dart` | 279 | 环境页 UI | 复用同一套 `stages`，无需大改 | `94-119` 折叠/组件区、`146-278` 摘要卡 |
| `widgets/stage_timeline.dart` | 203 | 阶段时间线（聚合 + 子任务行） | 协议对齐即可复用 | `27-134` 聚合状态、`137-183` 子任务行 |
| `widgets/toolchain_components_section.dart` | 141 | 组件管理入口 | 桌面 `installed` 恒空 → 全显示「未安装」 | `60-136`；`79-87` 状态文案 |
| `widgets/component_versions_sheet.dart` | 271 | 版本目录弹层 | 依赖本地 `installed`，桌面无数据 | `133-264` |
| `widgets/installed_toolchain_tile.dart` | 100 | 本地版本行（切换/删除/修复） | 桌面操作被 controller 拒绝 | `46-98` |

### 1.3 `lib/services/` 逐文件

| 文件 | 行数 | 职责 | Windows 现状 | 关键位置 |
| --- | --- | --- | --- | --- |
| `desktop_toolchain.dart` | 485 | 桌面工具链：布局、childEnvironment、检测、下载、解压、安装 | **骨架完整但仍不可用**（详见 §2.3/§3） | `22-32` home、`34-36` 版本常量、`38-60` 路径、`63-81` 环境注入、`85-104` status、`106-120` `_canRun`、`125-259` install、`261-276` licenses、`279-297` MinGit、`300-323` Flutter 清单、`338-397` 下载、`401-419` 解压、`428-449` versionOf |
| `desktop_shell.dart` | 326 | 桌面进程/系统能力 + POSIX 惯用法 shim | 可用但有 6 类坑（见 §2.4） | `22-27` bootstrapStatus、`30-58` exec、`61-127` hasBinary/which、`134-154` sha256、`204-300` posixShim、`311-325` `_runSimple` |
| `shell.dart` | 97 | 原生边界门面 | 可用 | `8` shQuote、`13-16` terminalEnvSource、`19` isDesktopPlatform、`22-96` |
| `local_fs.dart` | 265 | 文件层（替代 find/realpath/base64） | **已完全平台化**，Windows 有单测 | `15-30` canonical、`125-139` dirSize、`143-192` scanProjects、`196-224` listTree |
| `app_releases.dart` | 158 | 应用自身 Release/更新 | 有 Windows 语义问题（只认 APK） | `63-71` 构建匹配、`75-114` 下载到 `.flit/updates`、`150-158` `isApk` |
| `github_mirror.dart` | 37 | GitHub 加速前缀 | 可用；**DesktopToolchain 没用它** | `17-20` prefix、`23-37` wrap |
| `auto_proxy.dart` | 95 | 系统代理跟随 | 直接调 `FlitEnv`（Android 插件）；Windows 静默失效 | `14`、`28`、`40`（均 try/catch 包裹，不崩但不生效） |

### 1.4 `assets/scripts/`：15 个脚本 + `lib.sh`

| 脚本 | 行数 | 做什么 | 被谁调用 | Windows |
| --- | --- | --- | --- | --- |
| `lib.sh` | 225 | 公共库：加载 `env.sh`（`7-12`）、`__STAGE__` 输出 `st()`（`37`）、安装标记 `installed_ok/mark_installed`（`42-46`）、`die`（`56-60`）、`init_stage` ERR trap（`64-67`）、`stage_main` 入口协议（`78-101`，`--check`/`--release`/`--install`）、`configure_apt`（`105-112`）、`dl()` 多源下载+sha256+断点（`114-181`）、软链布局 `link_android_tools`（`184-193`）、`archive_path`（`195`）、`publish_directory` 原子落位（`197-214`）、`flutter_complete/select_flutter`（`216-225`） | 全部脚本 `source`；`component_checks.sh` 在 `34` 行被 source | ✗ |
| `check.sh` | 15 | 逐个脚本 `--check`，异常补 `__STAGE__<id>:FAILED`，退出码=失败数（`8-14`） | `environment_controller._refreshStatus:476`、`environment_status._inspect:101` | ✗（shebang 写死 termux 路径 `:1`） |
| `component_checks.sh` | 31 | 共用只读判据：`tool_works`（`4`）、`package_revision`（`5-7`）、`component_usable`（`8-31`；ndk 断言 `linux-arm64`/`readlink` `23-24`） | `lib.sh:34` | ✗ |
| `android_components.sh` | 35 | 构建前只读探测，输出 `__MISSING__<id>:<ver>`（`4`）；`--baseline` 查 java + 任一 build-tools/aapt2（`18-26`）；`--device` 查 platform-tools（`27`） | `android_build_wrapper._check:185` | ✗ |
| `toolchain_manager.sh` | 62 | `--list` 发 `__TOOL__` 行（`10-33`）；`--select` 切 Flutter `current`（`34-38`）；`--delete` 校验路径白名单（`5-7`）并删，删 build-tools 后重刷 gradle（`39-60`） | controller `:284`（切换/删除）、`:506`（--list） | ✗ |
| `android_jdk.sh` | 52 | probe 判 `java -version`（`8-23`）；install 走自建 apt 源装 `openjdk-17`（`25-50`） | pipeline（`stage_scripts.android_sdk` 首个） | ✗ |
| `android_sdk.sh` | 154 | 解 `.tar.xz`、校验 receipts/`source.properties`、分组件落位、licenses（`32-152`） | pipeline + `SetupRunner.installCommand` | ✗ |
| `android_ndk.sh` | 69 | 解 tar.xz（`--strip-components`）、补 `linux-x86_64 → linux-arm64` 软链（`53-55`） | pipeline | ✗ |
| `android_cmake.sh` | 91 | 解 tar.xz、`cmake --version`/ninja 校验、补 `source.properties`（`55-89`） | pipeline | ✗ |
| `android_gradle.sh` | 70 | 写 `gradle.properties` 的 `android.aapt2FromMavenOverride` + `android.builder.sdkDownload=false`、写 `init.d/flit-toolchain.gradle` 守卫（`37-65`） | pipeline；`toolchain_manager --delete` 会再调（`:51`） | ✗（**ARM64 专用**，Windows 不能跑） |
| `android_platform.sh` | 24 | 官方 `sdkmanager` 装 `platforms;android-<api>` 兜底（`12-23`） | `android_build_wrapper._repair:263` | ✗ |
| `flutter_sdk.sh` | 52 | 解 Flutter tar.xz、改 shebang 到 `$PREFIX/bin/bash`（`33-37`）、校验 dart、切 `current`（`47`） | pipeline + catalog 安装 | ✗ |
| `flutter_tools.sh` | 51 | apt 装 `git`/`gh`（`9-49`）；probe 用 `command -v` | pipeline | ✗ |
| `flutter_warmup.sh` | 40 | probe 只看 `flutter_tools.stamp/snapshot`（`12-21`），install 跑 `flutter --version` 预热（`23-38`） | pipeline | ✗（**它正是 Windows 缺的那一步**，见 §2.3） |
| `net_probe.sh` | 40 | `curl` 探 Google/GitHub/镜像/百度，输出 `__NET__<name>` 标记（含 HTTP 码与耗时，`13-26`） | controller `probeNetwork:313` | ✗（Windows 有 curl.exe 但没 bash） |

> 注：任务描述写「15 个脚本」；实际是 **15 个功能脚本 + `lib.sh` 公共库 = 16 个文件**（`setup_runner.dart:32-49` 的 `_scriptNames` 也是 16 项）。

### 1.5 脚本调用关系（现状）

```text
EnvironmentController
├─ _init() ───────────────► SetupRunner.installScripts()  → 写 16 个 .sh + env.sh 到 <home>/.flit/scripts
├─ refreshStatus() ──────► bash check.sh ──► 每个 x.sh --check ──► st() __STAGE__ / __VER__
├─ startPipeline()
│   ├─ BootstrapInstaller.install() ──► Shell.deployBootstrap()（Windows 空实现返回 true）
│   └─ _runStageInTerminal() ──► SetupRunner.stageCommand() + bash x.sh --check
│                              └─ 桌面走 _runStageDesktop() → DesktopToolchain.install()（无脚本）
├─ installFromCatalog() ─► SetupRunner.installCommand() → bash x.sh --release <url> <sha> ...
├─ changeInstalled() ────► bash toolchain_manager.sh --select/--delete
├─ _loadInstalled() ─────► bash toolchain_manager.sh --list（桌面直接返回空）
├─ probeNetwork() ───────► bash net_probe.sh
└─ _loadSizes() ─────────► du 命令（桌面走 LocalFs.dirSize）

AndroidBuildWrapper._check/_repair
├─ bash android_components.sh（桌面阻断构建）
├─ SetupRunner.installCommand() → bash android_sdk.sh --release ...
└─ bash android_platform.sh <api>（404 兜底）

ProjectBuild（project_actions.dart:13-53）
├─ debugApk/releaseApk/run: bash "$HOME/.flit/scripts/android_build.sh" flutter build apk|run ...
├─ web: flutter build web --release
└─ 桌面 console 归一化（console_session.dart:128）剥掉 android_build.sh 前缀
```

### 1.6 依赖 / 插件矩阵（Windows）

| 依赖 | 版本/来源 | Windows | 证据 |
| --- | --- | --- | --- |
| `flutter_pty` | ^0.4.2，pub.dev，声明 `windows: {ffiPlugin: true}` | ✅ ConPTY 可用 | `pubspec.yaml`；pub.dev API `flutter_pty 0.4.2` 的 plugin platforms 含 windows；`pty_launcher.dart:74-91,111` 已按 Windows 分支 |
| `webview_flutter` | ^4.10.0 | ❌ 无 Windows 实现（只有 android/wkwebview） | `pubspec.lock:480-507`；已降级为「浏览器打开」（`web_run_page.dart:78`，commit `8162285`） |
| `permission_handler` | ^12.0.0 | ✅ 有 `permission_handler_windows`（federated） | `pubspec.lock:331-334`；实际未做 Windows 适配（`background_access.dart:64-91` 走 Android 语义） |
| `flit_env` / `flit_device` / `flit_work` / `flit_lsp` / `flit_files` | path 插件 | ❌ **全部只声明 android** | 各 `plugins/*/pubspec.yaml` 的 `flutter.plugin.platforms`；Windows 构建会把它们排除出 registrant，调用即 `MissingPluginException`（多数被 try/catch 吞掉，但功能不可用） |
| `xterm` | third_party 本地 fork | ✅ 纯 Dart | `pubspec.lock` |
| `archive` | 未引入 | —（不推荐生产引入） | `pubspec.lock` 无该项 |

Android 专属插件在桌面造成的实际后果（超出环境层，但影响「Windows 上能做什么」的预期）：

- `flit_lsp`：语言服务（`lsp_client.dart:46-78`，`start` 失败会被 catch 成 `unavailable`）→ 编辑器有本地补全，但没有 Dart 分析/诊断。
- `flit_device`：无线配对/NSD 发现/通知/电池优化（`device_connect_page.dart:138,224,238,255,294`；`device_pairing_guide_page.dart:54,203`；`background_access.dart:64-91`）→ Windows 上**无线配对链路不存在**；USB/网络 adb 仍可能可用（见 §2.4）。
- `flit_files`：APK 安装/打开/分享（`file_card.dart:165-187`，`app_versions_page.dart:87-92`）→ Windows 无 APK 安装语义，应隐藏入口（P2）。
- `flit_work`：保活通道失败静默（`flit_work.dart:16-30`），无影响。

### 1.7 构建产物与 CI 现状

- 仓库**没有 `windows/` 平台目录**（`ls` 根目录只有 `android/`），Windows runner 由 CI 临时生成：`flutter create --platforms=windows --project-name flit --org cc.lycstar .`（`windows-build.yml:33-35`）→ 本地开发无法复现构建、runner 变更不入库。
- CI 只把 `flutter test test/local_fs_test.dart` 设为阻断（`windows-build.yml:40-41`）；全量测试与 analyze 是 `continue-on-error`（`:43-49`）。
- 最新一次 Windows 构建（run `42348982433`，main `b02a4cc`，2026-11-07）**成功**，Flutter stable **3.47.9**；阻断的 LocalFs 测试 10 passed；全量 **231 passed / 96 failed**。
- Flutter 版本漂移：CI/桌面安装最新 stable（3.47.9），Android catalog 钉死 `3.47.8`（`toolchain_catalog.dart:39`），桌面安装则从 manifest 取当前 stable（`desktop_toolchain.dart:300-323`）→ 两端版本不一致，测试/文档会互相打架。

---

## 2. Windows 上「开发环境就绪」的判定链路与失败点

### 2.1 链路 A：首页/工作台「环境已就绪」（UI → status）

```text
WorkbenchPage._probeReady()                         lib/features/projects/workbench_page.dart:76
  └─ EnvironmentStatus.inspect()                    lib/features/environment/environment_status.dart:48
       └─ _inspect()  [isDesktopPlatform]           :84-85
            └─ _inspectDesktop()                    :56-82
                 └─ DesktopToolchain().status()     lib/services/desktop_toolchain.dart:85-104
                      ├─ java  -version   (≤25s)    :86,106-120
                      ├─ adb   version    (≤25s)    :87
                      ├─ aapt2 = <sdk>/build-tools/36.0.0/aapt2.exe（仅存在性） :88-89,99
                      ├─ android.jar = <sdk>/platforms/android-36/android.jar  :90-91,100
                      ├─ flutter --version (≤25s)   :92
                      └─ git.exe / git --version     :93-95
       → 8 个 __STAGE__ 标记 → EnvironmentStatus.fromCheck(exitCode: allOk?0:1)  :74-78
  └─ environmentReady = (env.home==null ? _bootstrapped : env.allDone) && !changing  workbench_page.dart:84
```

**失败点（必然出现）**

1. **`flutter` 探测会超时**（`desktop_toolchain.dart:92` + `:106-120`）：全新 Flutter SDK 第一次执行 `flutter --version` 会构建 `flutter_tools` 快照、下载 Dart SDK 与引擎产物（数百 MB，分钟级）。25s 的 `.timeout` 一到就返回 false；而且 **`.timeout` 不会杀子进程**，下一次 status 又会起一个新 flutter 进程 → 多个 flutter 并发抢 `bin/cache/lockfile`，报 "Waiting for another flutter command to release the startup lock"。结果：装完 Flutter 之后 `flutter_sdk` 仍然是 MISSING，`ready=false`，`environmentReady=false` → **建/开工程被禁**。
2. **`flutter_warmup` 被当成「桌面无需」直接 DONE**（`environment_controller.dart:541-546,556`）：Android 靠 `flutter_warmup.sh`（`flutter_warmup.sh:23-38`）真正跑一次 `flutter --version`；桌面把这一步删掉了，于是「首次 bootstrap」被塞进了 25s 的探测里 → 和失败点 1 形成死锁。
3. **串行探测 + 外层 130s 超时**（`environment_status.dart:48-52`）：4 个进程串行，各 25s；加上首次 flutter bootstrap，可能超过 130s → `inspect()` 直接返回 `bootstrapped:false, checkFailed:true`，首页显示「未安装」。
4. **判据绑死版本**：`aapt2` 只认 `build-tools/36.0.0`、`platform` 只认 `android-36`（`:34-36,88-91`）。用户/项目装了 35.0.0 或 36.1 会被判「缺」；反过来，只要目录存在就算 OK，不校验 `source.properties`（Android 侧 `component_checks.sh:8-31` 是校验的）。
5. **`_checkFailed` 只覆盖 jdk/sdk/flutter**（`environment_controller.dart:559`），不含 aapt2/platform/git → `checkFailed` 与 `allDone` 语义分裂（UI 显示「未就绪」但不算「检查失败」）。

### 2.2 链路 B：环境页进入 / 刷新（UI → controller → shell → 脚本）

```text
EnvironmentPage.initState → env.refreshOnOpen()      environment_page.dart:47
  └─ EnvironmentController.init()/_init()             environment_controller.dart:322,335-349
       ├─ Shell.bootstrapStatus()                     shell.dart:26-33
       │    └─ DesktopShell.bootstrapStatus()          desktop_shell.dart:22-27
       │         → {home: <LOCALAPPDATA>\FlitDesk, prefix: 同, bootstrapped: true}
       ├─ SetupRunner(home, prefix).installScripts()  environment_controller.dart:341-343
       │    → 在 <home>/.flit/scripts 写 16 个 .sh + env.sh（**桌面永不需要**）  setup_runner.dart:55-74
       └─ refreshStatus() → _refreshStatus()          environment_controller.dart:441-494
            ├─ bootstrapped = true → 桌面分支         :463
            │    └─ _desktopCheck() → status() → 8 个 __STAGE__（无 __VER__） :549-560
            ├─ _loadSizes()（LocalFs.dirSize 可用）    :638-657
            └─ _loadInstalled() → 桌面恒返回 []        :496-503
```

**失败点**

1. **`_refreshStatus` 的桌面分支有前提**：`if (isDesktopPlatform && bootstrapped)`（`:463`）。只要 `bootstrapStatus()` 抛错或返回 false（`Shell.exec` 超时/异常），就会落到 **bash 分支** `:471-484` 去跑 `bash check.sh` —— 在 Windows 上 `cmd.exe /c` 找 bash 失败 → 检查恒失败。
2. **无版本信息**：桌面只发 `__STAGE__`，不发 `__VER__`（`:549-558` 对比 `:419-422`），而 `DesktopToolchain.versionOf`（`:428-449`）虽已写好但**全仓无调用**（grep 确认）。`StageTimeline` 的子任务行因此永远没有版本号。
3. **已装列表恒空**：`:496-503` 直接 `installed = const []` → 组件管理区（`toolchain_components_section.dart:60-136`）把所有组件显示成「未安装」，而摘要卡同时显示「环境就绪」，UI 自相矛盾。
4. **映射逻辑三份**：`_desktopCheck`（`:549-560`）、`_desktopNotRequired`（`:541-546`）、`EnvironmentStatus._inspectDesktop`（`:56-82`）各维护一份 id→判据映射，任何新组件都要改三处（`readyStageIds` 注释里已经警告过同类问题，`environment_controller.dart:64-70`）。

### 2.3 链路 C：一键安装（UI → controller → runner → DesktopToolchain → 子进程）

```text
「开始安装」environment_page.dart:232 → EnvironmentController.startPipeline() environment_controller.dart:685
  ├─ _refreshStatus(c)                                     :693
  ├─ ① bootstrap 阶段                                      :696-729
  │    （桌面因 bootstrapped=true 通常跳过；若为 false：）
  │    _runner.bootstrapSpec() → ToolchainCatalog.resolve('bootstrap')
  │       → GitHub release bootstrap-aarch64-* / bootstrap-aarch64.zip   toolchain_catalog.dart:40-46,124-147
  │    BootstrapInstaller.install() → 下载 + sha256                     bootstrap_installer.dart:10-85
  │       → Shell.deployBootstrap() → 桌面直接 return true（空实现）    shell.dart:36-38
  │    → stages['bootstrap']=DONE（**什么都没装**）                      :716-717
  ├─ ② 阶段循环 for stageDefs.skip(1) → stageScripts[id]   :732-752
  │    _runStageInTerminal() → 桌面 _runStageDesktop()     :792-793,563-635
  │      ├─ android_jdk   → install(flutter:false, androidSdk:false)     desktop_toolchain.dart:125-160
  │      │     Adoptium zip → tar.exe 解压 → rename → status()
  │      ├─ android_sdk   → install(flutter:false)                       :162-206
  │      │     commandlinetools-win-13114758_latest.zip → tar.exe
  │      │     sdkmanager --licenses / --install platform-tools platforms;android-36 build-tools;36.0.0
  │      ├─ android_ndk / android_cmake / android_gradle / flutter_warmup
  │      │     → _desktopNotRequired 直接 DONE（不安装、不校验）          :588-591,541-546
  │      ├─ flutter_tools → install(androidSdk:false, flutter:true)      :208-227
  │      │     MinGit 解析 (api.github.com 直连) → 下载 → tar.exe → rename
  │      ├─ flutter_sdk  → install(androidSdk:false)（已装则跳过）        :229-254
  │      │     releases_windows.json → storage.googleapis.com zip → tar.exe
  │      └─ 每步后 status() 判定 ok / FAILED                              :610-624
  └─ ③ _refreshStatus(c) → 打印「环境就绪 / 验证失败」                     :754-762
```

**失败点（按发生概率排序）**

1. **Git 永远不就绪（国内必现）**：`_resolveMinGitUrl` 直接打 `https://api.github.com/repos/git-for-windows/git/releases/latest`（`:281-283`），**没有走 `GithubMirror.wrap`**（对比 `toolchain_catalog.dart:132`）；失败返回 null → `install` 只打一行「无法解析 MinGit 下载地址，跳过」（`:215`），git 仍缺 → `flutter_tools` 阶段 `ok=false` → `FAILED`（`:618-624`）→ `_blockAfter('flutter_tools')`（`:741-748,824-836`）把 `flutter_sdk` 也置 BLOCKED → **环境永远不就绪**。
   - 而本该兜底的「用系统 git」是死代码：`File(gitExe).existsSync() || await _canRun('git$_exe', ...)`（`:93-95`），`_canRun` 第一行 `if (!File(exe).existsSync()) return false;`（`:107`）——传进去的是裸名 `git.exe`，相对路径永远不存在 → 恒 false。
2. **Flutter 装完被判失败**：同 §2.1-1（首次 `flutter --version` > 25s）→ `flutter_sdk` 阶段 `FAILED`（`:610-624`）。这两条串起来，就是「装完一键安装，环境页仍是失败」。
3. **`.bat` 参数按 shell 规则解析**：Dart 官方文档（`Process.start`）明确 "On Windows, if executable is a batch file ('.bat' or '.cmd'), it may be launched by the operating system in a system shell regardless of the value of runInShell. This could result in arguments being parsed according to shell rules."。`sdkmanager`/`avdmanager` 都是 `.bat`，当前用 `Process.run(toolsBin, ['--sdk_root=$sdkDir', ...], runInShell: true)`（`:190-200`，`:261-276`）：当 `LOCALAPPDATA`/用户名含空格或 `&`（如 `C:\Users\Zhang San\AppData\...`、`C:\Users\A&B\...`）时，`--sdk_root=...` 会被 shell 切断 → SDK 装到错误位置或直接失败。**这是「换一台机器就装不上」的隐性炸弹。**
4. **下载无校验、缓存启发式**：`_download` 从不调用传入的 `onProgress`（`:139-143,168-172,217-218,237-238` 都传 `(got,total){}`，函数体也没用，`:338-362`）；缓存判据是 `if (file.existsSync() && file.lengthSync() > 1MB) return;`（`:344`）——半截 JDK/Flutter 包会被当成完整缓存，之后每次 `tar.exe` 解压都失败，且**不会重下**；没有 SHA-256，对比 Android 侧 `lib.sh:114-181` + `bootstrap_installer.dart:68-74` 的「校验不通过不收货」是倒退。
5. **没有进度、没有空闲超时、不能取消**：1GB+ 的 Flutter 下载期间控制台一片空白；`_runStageDesktop` 只是 `await for` 消费 stream（`:606-609`），没有超时；`HttpClient` 只有 `connectionTimeout`（`:329,347`），服务端挂住就永久等待；用户的 ⏹ 只能置 `stopRequested`，而下一行检查发生在**流结束之后**（`:607`）。
6. **`aapt2`/platform 只认固定版本**：见 §2.1-4；且如果 `sdkmanager` 装的是 `build-tools;36.0.0`，正好命中；一旦默认版本升级（Google 每年两次）代码常量（`:35`）就过期。
7. **bootstrap 空实现后门**：若哪天桌面 `bootstrapped` 变成 false（比如把 `bootstrapStatus` 改成真实检测），pipeline 会下载 **aarch64 Termux bootstrap**（`toolchain_catalog.dart:42-46`）并解到 `<home>` 的父目录（`environment_controller.dart:711`），然后 `deployBootstrap` 返回 true 标记 DONE。目前被 `bootstrapped: true` 掩盖，属于「将来一定会踩」的坑（P1）。
8. **重复安装浪费**：`flutter_tools` 阶段 `install(androidSdk:false, flutter:true)`（`:600`）会同时装 Git **和 Flutter**，随后 `flutter_sdk` 阶段再判一次；语义上 `flutter_tools` 应只装 Git（参数粒度问题）。

### 2.4 链路 D：APK 构建 / 设备运行（当前 100% 阻断）

```text
EditorRunControls 构建按钮                          lib/features/editor/widgets/editor_run_controls.dart:363,374
  └─ ProjectActions.build(kind, confirmRepair)      lib/features/workspace/project_actions.dart:305-327
       └─ AndroidBuildWrapper.start()                lib/features/environment/android_build_wrapper.dart:80-109
            ├─ _readRequirements()（读 gradle 文件，纯 Dart ✅）  :153-172
            └─ _check(declared, baseline: true)        :174-220
                 └─ _probe('bash "$HOME/.flit/scripts/android_components.sh" ...')  :185
                      └─ Shell.exec → DesktopShell.exec → cmd.exe /c  desktop_shell.dart:30-58
                           → "'bash' 不是内部或外部命令" exitCode=1
                 → if (exitCode != 0) throw StateError("Android 环境检查失败…")  :187-193
       → 构建会话根本没启动，用户看到「环境检查失败」
```

- 即使绕过 preflight（`confirmRepair == null` 时 `build()` 走 `:309-310` 直接执行），实际命令是 `bash "…/android_build.sh" flutter build apk --debug --target-platform android-arm64 2>&1`（`project_actions.dart:19,28`）。桌面 console 会剥掉 `bash "…android_build.sh"` 前缀（`console_session.dart:124-152`，特别是 `:128`），剩下 `flutter build apk …` 在 `cmd.exe /c` 里是**可执行的**（`cmd` 按 PATHEXT 找 `flutter.bat`；环境已由 `PtyLauncher._startDesktop` 注入 `DesktopToolchain.childEnvironment`，`pty_launcher.dart:67-92`）。也就是说**构建命令本身没问题，挡路的是 preflight**。
- 补装路径同样断：`_installCommand` → `catalog.resolve` → `SetupRunner.installCommand`（`setup_runner.dart:144-184`）→ `bash .../android_sdk.sh --release ...`；`_repair` 里的 platform 404 兜底也是 `bash android_platform.sh`（`android_build_wrapper.dart:263`）。
- 设备运行同理：`run()` 里 `android.start(...)` 也走 `_check`（`project_actions.dart:239-246`），在 Windows 上同样抛错；而 `run:web` 不走 wrapper，但它的命令是 POSIX 脚本（`web_runner.dart:86-92`：`if [ ! -d web ]`、`stty -echo`）→ `cmd` 直接语法错误。
- `AndroidBuildDiagnostics` 的路径正则假定 `/ndk/`、`/aapt2` 形式（`android_build_wrapper.dart:474-478`），Windows 的 `\ndk\` 匹配不上 → 失败诊断会漏（P2）。

### 2.5 失败点汇总

| # | 链路 | 失败点 | 证据 | 影响 |
| --- | --- | --- | --- | --- |
| F1 | A/B/C | flutter 首次运行 >25s 探测超时 + 无预热阶段 | `desktop_toolchain.dart:92,106-120`；`environment_controller.dart:541-560` | Flutter 恒 MISSING，环境永不就绪 |
| F2 | A | 4 个探测串行 + inspect 130s 超时 | `environment_status.dart:48-52` | 首页「未安装/检查失败」 |
| F3 | A | aapt2/platform 绑死 36.0.0/android-36 | `desktop_toolchain.dart:34-36,88-91` | 版本稍异即判缺 |
| F4 | B | bootstrapStatus 异常时回落 bash 分支 | `environment_controller.dart:463-484` | 检查恒失败 |
| F5 | B | 无 `__VER__`、已装列表恒空 | `:549-558,496-503`；`desktop_toolchain.dart:428-449` | UI 自相矛盾 |
| F6 | C | MinGit 直连 api.github.com（无镜像） | `desktop_toolchain.dart:279-297` | git 缺 → 整链 BLOCKED |
| F7 | C | 系统 git 复用是死代码 | `:93-95` + `:106-107` | 无法兜底 |
| F8 | C | 下载无 sha256、缓存 >1MB 即命中 | `:338-362,344` | 坏包永久失败 |
| F9 | C | 无进度/无空闲超时/不可取消 | `:139-143…237-238`, `:606-609` | 用户以为卡死 |
| F10 | C | sdkmanager `.bat` 参数按 shell 解析 | `:190-200,261-276` + Dart 文档 NOTE | 路径含空格/& 就装不上 |
| F11 | C | bootstrap 空实现（deployBootstrap=true） | `shell.dart:36-38`；`environment_controller.dart:696-729` | 将来会假成功/下错架构 |
| F12 | C | 桌面仍写 16 个 `.sh`+env.sh | `environment_controller.dart:341-343`；`setup_runner.dart:55-74` | 无用 IO、误导排查 |
| F13 | D | preflight 硬编码 bash | `android_build_wrapper.dart:185,187-193` | **APK 构建/设备运行 100% 失败** |
| F14 | D | 补装命令全 bash | `:263,320-336`；`setup_runner.dart:144-184` | 缺组件无法修 |
| F15 | D | web run/build 无桌面命令 | `web_runner.dart:86-92`；`project_actions.dart:32-38` | Web 预览/构建不可用 |
| F16 | D | 构建诊断正则只认 `/` 路径 | `android_build_wrapper.dart:474-478` | 缺包诊断漏检（P2） |

---

## 3. 缺口表（P0 / P1 / P2）

> 级别定义：**P0** = 阻断「环境就绪」或阻断 APK/Web 构建，必须改；**P1** = 重要功能缺失或会稳定踩坑；**P2** = 打磨/一致性/信息补齐。

### P0

| ID | 缺口 | 证据（文件:行号） | 改法（函数签名级） | 新增文件 | 风险 |
| --- | --- | --- | --- | --- | --- |
| P0-1 | 首次安装后 Flutter 永远探测失败：`status()` 用 `flutter --version`（25s）当判据；桌面没有 warmup 阶段 | `desktop_toolchain.dart:92,106-120`；`environment_controller.dart:541-546,556`；`environment_status.dart:48-52` | `Future<ToolchainStatus> status({bool structuralOnly = true})`：默认只做**结构判据**（文件/目录/`source.properties`，不 exec）；新增 `Future<void> warmUp({required void Function(String) log, Duration timeout = const Duration(minutes: 30)})` 跑一次 `flutter --version`（流式输出、无 25s 上限、失败可重试）；`_canRun(String exe, List<String> args, {Duration timeout = const Duration(seconds: 25)})` 并 `try { } finally { 杀进程 }`；`flutter_warmup` 从 `_desktopNotRequired` 移出，改为真实阶段 | 无（改 3 个文件） | 预热必须可跳过（离线环境），否则又把就绪判死；`status(structuralOnly:false)` 的旧调用点要逐一审 |
| P0-2 | APK 构建/设备运行被 `bash android_components.sh` preflight 阻断 | `android_build_wrapper.dart:185,187-193`；`project_actions.dart:309-326`；`editor_run_controls.dart:363-376` | 把默认 probe 改成平台工厂：`AndroidBuildWrapper({..., Future<List<AndroidComponent>> Function(List<AndroidComponent>, {bool baseline, bool device})? check})`，默认 `check = isDesktopPlatform ? DesktopComponentProbe().check : _scriptCheck`；桌面实现 `Future<List<AndroidComponent>> check(List<AndroidComponent> declared, {bool baseline = false, bool device = false})` 纯目录扫描（`build-tools/<v>/source.properties`、`platforms/android-*/`、`platform-tools/adb.exe`、`cmdline-tools/latest/`），baseline 的 aapt2 用「任一 build-tools 下的 `aapt2.exe`」 | `lib/features/environment/android_component_probe.dart` | 判据必须与 `component_checks.sh:8-31` 等价，否则「脚本说缺/Dart 说不缺」两套真值；建议加 parity 测试 |
| P0-3 | Git 无法就绪 → 整链 BLOCKED（MinGit 直连 + 系统 git 死代码） | `desktop_toolchain.dart:93-95,106-107,279-297`；`environment_controller.dart:735-749,824-836` | `Future<String?> resolveMinGitUrl()` 内改用 `GithubMirror.wrap('https://api.github.com/repos/git-for-windows/git/releases/latest')`；`bool _canRunPath(String exe, List<String> args)` 或 `String? which(String name)`（PATH 查找，不要求 `File('git.exe')`）；`ToolchainStatus.git` 判据改为「`File(gitExe).existsSync()` 或 `which('git') != null`」；git 失败**不阻断** flutter 阶段（`_blockAfter` 跳过非依赖项，或把 git 降级为警告 + `flutter_tools` 用 `DONE_WITH_WARNING` 状态） | 无 | 放宽 git 阻断会让「无 git 的 Flutter」在 pub/git 依赖处才炸；建议 UI 明确提示而非静默通过 |
| P0-4 | 下载无完整性校验、缓存启发式导致坏包永久失败 | `desktop_toolchain.dart:338-362,344,401-419` | `Future<void> download(String url, String dest, {required String? sha256, void Function(int received, int total)? onProgress, Duration idleTimeout = const Duration(seconds: 60), bool resumable = true})`；缓存判据改为「存在 && sha256 匹配」；`Future<void> extract(String archive, String dest)` 用 `try { tar.exe } on ProcessException { powershell 兜底 }`；解压后校验关键文件（`java.exe`/`adb.exe`/`flutter.bat`）再 `publish` | `lib/services/toolchain/download.dart`、`lib/services/toolchain/archive.dart` | `certutil` 计算 1GB 文件 SHA-256 需要数秒~十秒，需在后台/进度提示；摘要来源：Flutter manifest 有 `sha256`、Adoptium assets API 有 `package.checksum`（均已实测），cmdline-tools 需 pin 常量或 TOFU（见 §4.3） |
| P0-5 | 没有「按组件补齐」的桌面通道（项目要求其它 build-tools/platform/NDK 时无解） | `android_build_wrapper.dart:320-336`；`setup_runner.dart:144-184`；`desktop_toolchain.dart:34-36` | `Future<void> installComponent(AndroidComponent component)` 走 `SdkManager.install(['build-tools;$v' / 'platforms;android-$api' / 'platform-tools' / 'ndk;$rev' / 'cmake;$v'])`；`AndroidBuildWrapper._installCommand` 平台分支：桌面 `return DesktopToolchain().installComponent(component)`（返回可等待的 Future/Stream 而非 bash 字符串） | `lib/services/toolchain/sdk_manager.dart` | sdkmanager 需要先接受 licenses；离线时无解，需要明确错误文案；NDK/CMake 在 Windows 上官方包很大（~1GB），要按需 |

### P1

| ID | 缺口 | 证据 | 改法 | 新增文件 |
| --- | --- | --- | --- | --- |
| P1-1 | `.bat` 参数按 shell 规则 → 路径含空格/`&` 时 sdkmanager 失败 | `desktop_toolchain.dart:190-200,261-276` | 绕开 `.bat`：`Process.start(javaExe, ['-classpath', '<cmdline-tools>/latest/lib/sdkmanager.jar', 'com.android.sdklib.tool.sdkmanager.SdkManagerCli', ...])`（java.exe 参数不经 shell）；licenses 同理。`SdkManager.install(List<String> packages)` / `acceptLicenses()` | `lib/services/toolchain/sdk_manager.dart` |
| P1-2 | 组件管理页在桌面完全失效（恒「未安装」；点安装触发整链重装） | `environment_controller.dart:215-220,266-273,496-503`；`toolchain_components_section.dart:60-136` | `Future<List<InstalledToolchain>> listInstalled()`：扫 `build-tools/*`、`platforms/*`、`ndk/*`、`cmake/*`、`flutter/`，读 `source.properties` 的 `Pkg.Revision`、`LocalFs.dirSize`，生成与 `__TOOL__` 相同字段（`InstalledToolchain` 是纯解析类，可直接构造）；`changeInstalled(tool,{delete})` 桌面实现 `uninstall()`/`selectFlutter()`（删目录 / 改 `current` 标记文件） | 无（或并入 `desktop_toolchain.dart`） |
| P1-3 | 网络探测在桌面是空操作 | `environment_controller.dart:301-320,313` | 新增纯 Dart 探测：`Future<Map<String, ({int code, double seconds})>> probeTargets(List<Uri>)`，用 `HttpClient`（已装 `AutoProxy` 的 `HttpOverrides`），输出同一 `__NET__` 协议 | `lib/services/net_probe.dart` |
| P1-4 | Web 运行命令是 POSIX；Web 构建缺少 `web/` 前置与产物路径 | `web_runner.dart:86-92`；`project_actions.dart:32-38` | `String buildWebRunCommand({required int port, required HostPlatform platform})`：桌面在 Dart 侧判断 `Directory('web').existsSync()`，缺则先跑 `flutter create --platforms web .`，命令只剩 `flutter run --machine -d web-server --web-hostname 0.0.0.0 --web-port <p> --no-devtools`（去掉 `stty -echo`，ConPTY 不需要）；`ProjectBuild.web` 增 `artifactPath: 'build/web'`（目录产物，文件卡需支持目录或改为 zip 列表） | 无 |
| P1-5 | Git 命令是 POSIX 前缀 + 单引号 → Git 面板在 Windows 全废 | `git_repo.dart:50-52` | `String gitCommand(List<String> args, {required String root, required HostPlatform platform})`：Windows 版去掉 `LC_ALL=C`/`GIT_TERMINAL_PROMPT=0`/`GIT_SSH_COMMAND='...'`（改由 `DesktopShell.exec` 注入 env），用 `"..."` 引用；`DesktopShell.exec` 增 `environment` 合并参数 | 无 |
| P1-6 | 新建工程预检用裸名跑 `.bat` → 按钮被禁 | `create_project_page.dart:127`；`desktop_shell.dart:220-222,311-325` | `_posixShim` 的 `command -v X` 分支改用 `which(name)` 的**绝对路径**；Windows 走 `Process.start('cmd.exe', ['/c', '"$path"', '--version'])`；或新增 `Future<Map<String,dynamic>> DesktopShell.runTool(String name, List<String> args)` | 无 |
| P1-7 | 下载无进度/不可取消 | `desktop_toolchain.dart:139-143,168-172,217-218,237-238`；`environment_controller.dart:606-609` | `download(..., {onProgress})` 真回调 + `_runStageDesktop` 用 `_progress(c, msg)` 原地刷新；`await for` 循环里检查 `c.stopRequested` 并抛 `_Cancelled` 终止下载 | 同 P0-4 |
| P1-8 | 镜像/代理未统一 | `desktop_toolchain.dart:140,169,279-297,300-323`；`desktop_shell.dart:40-46` | GitHub 两个来源套 `GithubMirror.wrap`；Flutter 用 `FLUTTER_STORAGE_BASE_URL`（可配，默认官方）；Adoptium 用 `FLIT_ADOPTIUM_BASE`（可配）；`DesktopShell.exec` 的 `environment` 合并 `AutoProxy().envVars()` | 无 |
| P1-9 | `childEnvironment` 缺 Android 侧已有的镜像变量 | `desktop_toolchain.dart:63-81` vs `setup_runner.dart:109-124` | `Map<String,String> childEnvironment({Map<String,String> extra = const {}})` 增加 `PUB_HOSTED_URL`、`FLUTTER_STORAGE_BASE_URL`（与 Android 同默认值），去掉 Windows 下无意义的 `JDK_JAVA_OPTIONS`/`LD_*`（本来就没有 ✓） | 无 |
| P1-10 | 平台判定无注入点 → 测试不可移植（CI 96 失败，Android 分支不可测） | `shell.dart:19`；`environment_controller_test.dart:89` 等（§8.2） | `enum HostPlatform { android, windows, linux, macos }` + `HostPlatform get hostPlatform` + `@visibleForTesting void setHostPlatform(HostPlatform?)`；`bool get isDesktopPlatform => hostPlatform != HostPlatform.android`；测试 `setHostPlatform(HostPlatform.android)` 即可恢复 Android 分支与 FlitEnv mock | `lib/core/host_platform.dart` |
| P1-11 | 状态映射三份会漂移 | `environment_controller.dart:541-560`；`environment_status.dart:56-82` | 收敛为 `ToolchainStatus.toStageMarkers()`（返回 `List<({String id, bool ok, String? version, bool optional})>`），controller 与 `EnvironmentStatus` 都调它 | 无 |
| P1-12 | 「桌面无需」组件（NDK/CMake/gradle/warmup）被静默 DONE，项目真需要时误判就绪 | `environment_controller.dart:541-546,588-591` | `StageState` 增 `String? note`（如「按需安装」），`_desktopNotRequired` 改为 `desktopOptional`：标志 DONE + note；`_desktopCheck` 对 NDK/CMake 做**结构性可选检测**（存在则发真实版本），UI 在子任务行显示 note | 无 |
| P1-13 | `_runner == null` / bootstrap 空实现后门 | `environment_controller.dart:686,696-729,711`；`shell.dart:36-38` | runner 接口加 `bool get needsBootstrap`（桌面 false）→ pipeline 跳过整个 ①；`Shell.deployBootstrap` 桌面改 `throw UnsupportedError` 而非 true | 无 |
| P1-14 | `_extract` 在 `tar.exe` 缺失时抛未捕获异常 | `desktop_toolchain.dart:401-419` | `try { Process.runSync('tar.exe') } on ProcessException { powershell 兜底 }`，两者都失败抛带提示的 `StateError` | `lib/services/toolchain/archive.dart` |
| P1-15 | 旧 `SetupRunner` 桌面仍写脚本/生成 env.sh | `environment_controller.dart:341-343`；`setup_runner.dart:55-74` | `_init()` 桌面跳过 `installScripts()`，只在需要 catalog 时构造 `ToolchainCatalog`（`SetupRunner` 保留给 Android） | 无 |

### P2

| ID | 缺口 | 证据 | 改法 |
| --- | --- | --- | --- |
| P2-1 | 桌面不发 `__VER__`，版本信息空白 | `environment_controller.dart:549-558`；`desktop_toolchain.dart:428-449`（`versionOf` 无调用） | 读文件即可纯离线获得：JDK `<jdk>/release` 的 `JAVA_VERSION`、Flutter `<flutter>/version`（与 `flutter_warmup.sh:17` 同款）、build-tools `source.properties` 的 `Pkg.Revision`；git 用 `git --version` |
| P2-2 | 桌面文案硬编码中文，绕过 l10n | `environment_controller.dart:217,271,570-591,620-623` | 全部改 `strings.*`（`l10n/strings.dart` + en/zh 两份 ar） |
| P2-3 | `dart compile exe` 命令在 cmd 下留 `-p` 目录 | `project_actions.dart:266-275`（`mkdir -p build`，无 `cd`，不匹配 `console_session.dart:130-143` 的 mkdir+cd 模式） | `normalizeConsoleCommand` 单独处理 `mkdir -p <dir> && rest` → `if not exist "<dir>" mkdir "<dir>" & rest` |
| P2-4 | `hasBinary/which` 递归扫整棵 SDK/Flutter 树（1GB） | `desktop_shell.dart:107-127` | 定向查找已知位置（`platform-tools/adb.exe`、`build-tools/*/aapt2.exe`、`cmdline-tools/latest/bin`、`flutter/bin`、`jdk/bin`、`git/cmd`），或建一次索引缓存 |
| P2-5 | 桌面首次启动弹 Android 后台权限说明 | `workbench_page.dart:50-51`；`background_access.dart:14-31,64-91` | `if (isDesktopPlatform) return;`（`BackgroundAccess.explain` 早退） |
| P2-6 | ADB 无线配对/NSD/通知/电池优化依赖 Android 插件 | `device_connect_page.dart:138,224,238,255,294-295`；`device_pairing_guide_page.dart:54,133,203` | 桌面隐藏配对/无线入口；保留 `adb devices`/`adb connect <host:port>` 手动路径（`adb_ops.dart:118-122`、`device_connection.dart:104-106,270-272` 已可用） |
| P2-7 | `AppReleases` 只认 APK，更新流程对 Windows 无意义 | `app_releases.dart:75-114,150-158` | Windows 用同一 release 的 `flit-windows-x64.zip`（CI 已产出）；更新=下载 zip→提示手动解压（P2 阶段） |
| P2-8 | `windows/` runner 不入库 | `windows-build.yml:33-35` | 提交 `windows/` 或加 `tool/scaffold_windows.*`；CI 改成 `flutter create` 仅在缺失时 |
| P2-9 | CI 全量测试/analyze 不阻断 | `windows-build.yml:43-49` | P0/P1 修完后把 desktop 相关测试 + analyze 提升为阻断子集，逐步收口 |
| P2-10 | `android.builder.sdkDownload=false` 若残留会阻断桌面 AGP 自动补包 | `android_gradle.sh:41-45`（不会在桌面执行 ✓，但 `GRADLE_USER_HOME` 若被复用会带进来） | 桌面 `gradleHome` 独立（`desktop_toolchain.dart:41` 已独立 ✓）；文档说明不要复用 Android 的 `.gradle` |
| P2-11 | Flutter 版本漂移：CI 3.47.9 / Android 3.47.8 / 桌面 latest | `toolchain_catalog.dart:39`；`desktop_toolchain.dart:300-323` | `DesktopToolchain` 也接受 `ToolchainCatalog.flutterVersion`（或用 manifest 按版本号精确取 archive），并在 CI 打印两端版本一致性检查 |
| P2-12 | macOS/Linux 桌面会拿到 Windows 资产 | `desktop_toolchain.dart:140,169` + `shell.dart:19` | 若 Linux/macOS 不在范围：在 `DesktopToolchain` 里显式 `if (!Platform.isWindows) throw UnsupportedError`，避免半坏；若在范围：资产 URL 按平台分支（P2 再议） |
| P2-13 | 脚本 shebang 写死 termux 路径 | `check.sh:1`、`android_sdk.sh:1` 等 12 处 | Android-only，无需改；文档标注「不要在 Windows 上跑」 |

---

## 4. 推荐方案

### 4.1 分层与新增文件

```text
UI（EnvironmentPage / StageTimeline / ComponentVersionsSheet）      —— 0 改动
        │  stages: Map<String, StageState>（协议不变）
EnvironmentController（837 行，只保留编排与状态）
        │
        ├─ SetupRunnerApi（抽象）
        │    ├─ SetupRunner          （Android，bash 脚本，现状保留）
        │    └─ DesktopSetupRunner   （Windows，Dart 直装）  ★ 新文件
        │
        └─ EnvironmentStatus.inspect() / ToolchainStatus.toStageMarkers()（单一映射源）

DesktopToolchain（services，无 UI；保留为门面）
        ├─ ToolchainLayout          纯路径 / childEnvironment        ★ 新文件
        ├─ ToolchainProbe           结构判据 + 可选 exec            ★ 新文件
        ├─ ToolchainInstaller       阶段步骤（下载→校验→解压→落位）  ★ 新文件
        ├─ Downloader / Archive / SdkManager / Hash                  ★ 新文件
        └─ DesktopComponentProbe     android_components.sh 的对等实现 ★ 新文件
```

建议落地目录：

```
lib/core/host_platform.dart                       # HostPlatform 枚举 + 测试注入
lib/services/toolchain/layout.dart                # 路径、childEnvironment、版本常量（单一来源）
lib/services/toolchain/download.dart              # 下载 + 进度 + 断点 + sha256
lib/services/toolchain/archive.dart               # tar.exe → PowerShell 回退
lib/services/toolchain/sdk_manager.dart           # java -jar sdkmanager.jar（绕开 .bat 引号）
lib/services/toolchain/probe.dart                 # 结构判据（jdk/sdk/flutter/git）
lib/services/toolchain/installer.dart             # 安装步骤编排（可注入 Downloader/Archive/Probe）
lib/services/net_probe.dart                       # net_probe.sh 的 Dart 对等实现
lib/services/console_command.dart                 # 从 ConsoleSession 抽出的命令归一化（纯函数）
lib/features/environment/desktop_setup_runner.dart# 桌面 runner（阶段计划 + 事件）
lib/features/environment/setup_event.dart         # SetupEvent（Stage/Version/Log/Progress）
lib/features/environment/android_component_probe.dart # 组件探测（纯目录扫描）
```

**为什么 runner 要单独一个文件**：`EnvironmentController` 已经 837 行，混了「UI 状态、终端协议解析、平台分支、产品文案」四件事；桌面逻辑再塞进去只会让 `isDesktopPlatform` 分支从 5 处膨胀到 10+ 处。新 runner 负责「做什么、按什么顺序、失败怎么标」，controller 负责「显示与生命周期」；同时把 `SetupRunner` 抽成接口（`android_setup_runner` 复用现状），桌面实现可独立单测。

### 4.2 安装来源取舍

| 方案 | 具体 | 优点 | 缺点 | 结论 |
| --- | --- | --- | --- | --- |
| **A. 官方产物 + 私有目录（当前路线）** | Adoptium JDK17 zip、Google cmdline-tools zip + sdkmanager、Flutter 官方 Windows zip、MinGit zip；全部解到 `<home>/jdk|android-sdk|flutter|git` | 无管理员权限、不污染 PATH/注册表、版本可控、离线可缓存、与现有 `DesktopToolchain` 一致；CI 已证明可编译 | 需要 5 个下载源；国内需镜像；体积大（约 2.5~3 GB） | ✅ **推荐主路径** |
| B. 复用系统已装环境 | 探测 `JAVA_HOME`/`ANDROID_HOME`/`where git|flutter|adb`，满足最低版本则「采用」 | 省下载、装得快、用户已有环境不重复 | 版本不可控（JDK 8/21、老 SDK、老 Flutter）；PATH 一改就坏；无法断言「就绪」；Gradle/AGP 漂移 | ⚠️ **只作 adopt 降级**（git、adb、JDK 可 adopt；SDK/Flutter 建议私有） |
| C. 自建 `.tar.xz` 工具链（Android catalog） | 复用 `ToolchainCatalog` 的发行仓 | 与 Android 同一套版本/摘要协议 | **物理上不可行**：仓库产物是 bionic aarch64 交叉编译（`README.md:61,79`；`docs/runtime-environment.md:19`；`toolchain_catalog.dart:48-114`），Windows x64 无法执行；且 Windows 解 xz 多一层依赖 | ❌ 不做 |
| D. 系统包管理器（winget/choco/vcpkg） | 调 `winget install ...` | 一条命令 | 需要管理员/交互/UAC；版本与安装位置不可控；无法私有化；不可断言/离线 | ❌ 不做 |

补充事实：`docs/runtime-environment.md:19` 与 `README.zh-CN.md:79` 已经明确「宿主工具必须适配 bionic aarch64，桌面 Linux 工具不能替代」，所以 Windows 必须走官方 x86_64 产物，**这条边界要在文档里写清楚，避免后来者试图复用 Android 的 catalog 资产**。

### 4.3 下载与解压：要不要 `archive`？

**结论：不引入生产依赖 `archive`；继续用 Windows 自带 `tar.exe`（bsdtar）为主、PowerShell 单命令兜底。**

理由（按重要性）：

1. **Windows 10 1803+ 自带 `tar.exe`**（libarchive/bsdtar），支持 `.zip` 且路径处理比 `Expand-Archive` 好；CI 的 `windows-latest`（Server 2022）一定具备。现有实现已经这么干（`desktop_toolchain.dart:401-419`），被验证过「能解出 JDK/Flutter」——CI 构建本身不验证安装，但代码路径与 commit 记录（`89a71f9`/`1d1e632`）表明这是有意选择。
2. **`archive` 解 1GB 级 zip 不是它的强项**：需要 `InputFileStream` 逐条解，CPU/内存成本高；而 Windows 上「权限位」语义不存在，`archive` 的可移植优势在这里用不上。
3. **约束要求「不要依赖 PowerShell 写复杂逻辑」**：`Expand-Archive -LiteralPath ... -DestinationPath ... -Force` 和 `Get-FileHash` 都是**单条命令**，符合约束；把解压流程写成 PowerShell 脚本则违背约束。
4. **`archive` 唯一值得引入的地方是测试**：构造 zip fixture、断言「解压后目录结构/`.flit-complete` 落位」。建议放 `dev_dependencies`（不进产物），例如 `archive: ^4.0.0`。

必须补的健壮性（现在是 bug）：

```dart
// 现在：tar.exe 不存在时 ProcessException 未捕获 → 安装直接抛原始异常
void extract(String zip, String dest) { ... Process.runSync('tar.exe', ...) ... }

// 建议
Future<void> extract(String archive, String dest) async {
  Directory(dest).createSync(recursive: true);
  if (Platform.isWindows) {
    if (await _tryRun('tar.exe', ['-xf', archive, '-C', dest]) == 0) return;
    final ps = await _tryRun('powershell.exe', ['-NoProfile', '-Command',
        'Expand-Archive -LiteralPath "$archive" -DestinationPath "$dest" -Force']);
    if (ps != 0) throw ToolchainException('解压失败（tar/PowerShell 均失败）: $archive');
    return;
  }
  ...
}
```

摘要校验的现实路径（不新增依赖；下面三条来源已实测可用）：

| 来源 | 摘要可得性 | 建议 |
| --- | --- | --- |
| Flutter Windows zip | `releases_windows.json` 的每条 release 都带 `sha256`（本次实测拉取确认字段：`archive/channel/dart_sdk_arch/dart_sdk_version/hash/release_date/sha256/version`；现有代码只用了 `archive`+`hash`，`desktop_toolchain.dart:305-320` 未取 `sha256`） | 解析时一并返回 `(url, sha256, version)`，下载后强制校验 |
| Adoptium JDK | 别再用 `/v3/binary/.../eclipse` 重定向；改用 `https://api.adoptium.net/v3/assets/latest/17/hotspot?architecture=x64&image_type=jdk&os=windows&vendor=eclipse`，实测返回 `binary.package.{link,size,checksum}`（sha256）并可 pin 具体 build（如 `jdk-17.0.21+9`） | 一次元数据请求同时拿到「确切 URL + 大小 + sha256」，顺便解决「latest 每次装出不同 build」的问题 |
| cmdline-tools zip | Google 的直链 `commandlinetools-win-<build>_latest.zip` 没有随包公开摘要（未验证 repository XML 是否含它） | 代码里 pin `(url, sha256, build)` 常量（随 `cmdlineToolsBuild` 升级一起改），`certutil`/`Get-FileHash` 记录首次摘要做 TOFU；或者改为「只信 https + 结构校验（`bin/sdkmanager.bat` 存在）」并明确告知不做内容校验 |

### 4.4 复用系统已装环境（adopt 策略）

```dart
enum ToolchainSource { private, system }
class ToolchainStatus {
  final bool jdk; final bool androidSdk; final bool aapt2;
  final bool platform; final bool flutter; final bool git;
  final Map<String, ToolchainSource> origin; // 新：来源标注，UI 可显示「系统」
}
```

- **探测不依赖注册表**：`where java` / `where git` / `where flutter` / `where adb`（PATH 搜索，用 Dart 的 `Platform.environment['Path']` 自行拆分，`desktop_shell.dart:61-95` 已有实现；注意修掉 `_canRun` 的 `File('git.exe')` 死代码）。
- **采用规则（建议）**：
  - Git：系统 git ≥ 2.30 直接「采用」，MinGit 仅作兜底（体积小、风险低）。
  - JDK：系统 `JAVA_HOME` 指向的 java ≥ 17 → 采用；否则私有 Temurin 17（AGP 对 JDK 版本敏感，宁可用私有的）。
  - Android SDK：**只认私有目录**（`ANDROID_HOME` 指向系统 SDK 时版本/许可不可控，且会把 `~/.android` 缓存混进来）。
  - Flutter：**只认私有目录**（系统 Flutter 可能是任意 channel，`flutter --version` 行为不可控）。
- **不污染系统**：私有目录 + `childEnvironment`（`desktop_toolchain.dart:63-81`）已经满足；不写 `HKCU`，不改用户 PATH，不装服务。
- **UI 要能解释「就绪」**：`StageState.note` 显示 `来源: 系统 Git 2.45 / 私有 Temurin 17`，避免用户困惑“为什么又下了一份”。

### 4.5 与 Android 状态机 / `__STAGE__` 协议对齐

不改协议，只改生产者：

```dart
// 新文件 lib/features/environment/setup_event.dart
sealed class SetupEvent {}
class StageEvent extends SetupEvent { final String id; final String state; }        // → __STAGE__
class VersionEvent extends SetupEvent { final String id; final String version; }     // → __VER__
class LogEvent extends SetupEvent { final String line; }
class ProgressEvent extends SetupEvent { final String text; }                        // \r 原地刷新
```

`DesktopSetupRunner` 的实现要点：

```dart
class DesktopSetupRunner implements SetupRunnerApi {
  DesktopSetupRunner({required DesktopToolchain toolchain, required ToolchainInstaller installer});

  @override bool get needsBootstrap => false;          // 桌面没有 Termux bootstrap

  @override Future<void> prepare() async { /* 建目录，不写 .sh */ }

  @override Future<List<InstalledToolchain>> listInstalled() async { ... }

  /// 阶段计划：id 必须与 readyStageIds 完全一致（environment_controller.dart:40-70）
  List<String> get plan => const [
    'android_jdk', 'android_sdk', 'android_ndk', 'android_cmake', 'android_gradle',
    'flutter_tools', 'flutter_sdk', 'flutter_warmup',
  ];

  /// 返回事件流：controller 用 `await for` 消费，同时把 __STAGE__/__VER__ 文本喂给 _onPtyText
  Stream<SetupEvent> runStage(String id) async* { ... }

  /// 检测：与 status(structuralOnly:true) 共用，输出 8 个 marker
  List<({String id, bool ok, String? version, String? note})> check();
}
```

- `android_ndk / android_cmake / android_gradle`：`ok=true` + `note='按需安装'`（不撒谎：UI 能看出来）。
- `flutter_warmup`：真实阶段（跑 `flutter --version`），成功后 `__STAGE__flutter_warmup:DONE`，版本来自 `<flutter>/version`。
- controller 侧改动最小：`_runStageInTerminal` 桌面分支改成
  ```dart
  await for (final e in runner.runStage(id)) { emit(e); if (c.stopRequested) break; }
  ```
  其余 `_onPtyText`/`stages`/`allDone`/`_blockAfter` 全部复用。
- `EnvironmentStatus._inspectDesktop` 改成调用 `runner.check()`（同一函数），删除重复映射（§2.2-4）。

### 4.6 环境变量 / 镜像 / 代理

`ToolchainLayout.childEnvironment({Map<String,String> extra = const {}})`：

| 变量 | 值 | 依据 |
| --- | --- | --- |
| `JAVA_HOME` / `ANDROID_HOME` / `ANDROID_SDK_ROOT` / `PUB_CACHE` / `GRADLE_USER_HOME` | 私有目录 | 已有 `desktop_toolchain.dart:74-78` |
| `Path`（Windows）/ `PATH` | `jdk\bin; flutter\bin; sdk\platform-tools; sdk\cmdline-tools\latest\bin; git\cmd; <原 Path>` | 已有 `:66-79` |
| `PUB_HOSTED_URL` | `https://pub.flutter-io.cn`（与 Android 一致） | `setup_runner.dart:110` |
| `FLUTTER_STORAGE_BASE_URL` | `https://storage.flutter-io.cn`（可配） | `setup_runner.dart:111` |
| `http_proxy/https_proxy/...` | `AutoProxy.envVars()` 合并 | `auto_proxy.dart:76-85`；`pty_launcher.dart:80` 已合并，`DesktopShell.exec` 未合并（P1-8） |
| 不要注入 | `LD_LIBRARY_PATH`、`LD_PRELOAD`、`JDK_JAVA_OPTIONS`、`ADB_EMU=0`、`TMPDIR` | 这些是 Termux/bionic 专属（`setup_runner.dart:83-115`） |

---

## 5. 构建依赖：APK / Web，以及 termux 假设的分支点

### 5.1 `flutter build apk`（Windows 宿主）

| 需要 | 是否已有 | 说明 |
| --- | --- | --- |
| Flutter SDK（含 dart） | 桌面阶段 `flutter_sdk` | 必须**先预热**（P0-1） |
| JDK 17 | 桌面阶段 `android_jdk` | Gradle/AGP 需要；`JAVA_HOME` 进 childEnvironment ✓ |
| Android SDK：`platform-tools`、`platforms;android-36`、`build-tools;36.0.0`、`cmdline-tools` | 桌面阶段 `android_sdk` | `sdkmanager` 装（P0-5/P1-1） |
| aapt2 | **来自 build-tools**（Windows 用 `build-tools/<v>/aapt2.exe`，由 AGP 调） | 与 Android 的 `android.aapt2FromMavenOverride`（`android_gradle.sh:41-42`）是两码事；**Windows 不要设置该属性** |
| Gradle Wrapper | 项目自带 `gradlew.bat`；首次构建下载 Gradle 发行版 | 需要网络：`services.gradle.org`、`repo.maven.apache.org`、`dl.google.com`、`maven.google.com`；建议 `GRADLE_USER_HOME=<home>/gradle-home` ✓（`:78`）+ 代理 |
| NDK / CMake | **按需** | 仅当项目/插件含 native 代码；`flutter_pty` 是 FFI 插件（`ffi: ^2.0.1`，无 Gradle native）→ 普通项目不需要；需要时 `sdkmanager --install "ndk;<rev>" "cmake;<v>"` |
| 签名 | 用户项目由 `flutter create` 模板决定（默认 debug 签名）；本仓库自身用 `key.properties`（`android/app/build.gradle.kts:11-16,56-69`） | Windows 端**无需改**；若要发布正式包，需用户自备 keystore，属文档事项（P2） |
| 产物 | `build/app/outputs/flutter-apk/app-debug.apk` / `app-release.apk` | 路径跨平台一致 ✓（`project_actions.dart:20,29`） |

**结论**：只要 P0-1/P0-2 修掉，`flutter build apk` 这条路在 Windows 上是可行的；`--target-platform android-arm64` 是**产物 ABI**，与宿主 x64 无关，保留即可（若也想给 x86_64 模拟器用，另开 `android-x64` 变体，P2）。

### 5.2 `flutter build web`

| 需要 | 现状 | 缺口 |
| --- | --- | --- |
| Flutter SDK + web artifacts | 装完 Flutter 后首次 build 会下载 web SDK（走 `FLUTTER_STORAGE_BASE_URL`） | 国内需镜像（P1-8/9） |
| 项目有 `web/` 目录 | `flutter create --platforms web .` 只在 **web run** 里做（`web_runner.dart:87`，且是 POSIX 写法） | build 路径没有前置创建（P1-4） |
| pub get | `flutter build web` 自带 pub get（可 `--no-pub`） | ✓ |
| JDK/Android SDK | **不需要** | ✓（这点常被误解，文档要写清） |
| 产物 | `build/web/` | `ProjectBuild.web` 无 `artifactPath`（`project_actions.dart:32-38`）→ 构建完没有产物卡（P1-4） |

### 5.3 `AndroidBuildWrapper` 里的 termux/签名/产物假设 → 分支表

| 假设 | 位置 | Windows 处理 |
| --- | --- | --- |
| 前置检查通过 `bash android_components.sh` 做 | `android_build_wrapper.dart:185` | ❌ 必须换成 Dart 目录探测（P0-2） |
| 补装通过 `bash android_sdk.sh --release <url> <sha>` 做 | `:320-336` → `setup_runner.dart:144-184` | ❌ 换成 `sdkmanager`（P0-5） |
| platform 404 时用 `bash android_platform.sh` 回退 | `:263` | ❌ 换成 `sdkmanager --install platforms;android-<api>`（同一路径） |
| 构建命令前缀 `bash "$HOME/.flit/scripts/android_build.sh"` | `project_actions.dart:19,28,233` | ✅ console 归一化已剥掉（`console_session.dart:128`）；但**不要依赖这个巧合**，建议 `buildApkCommand(platform)` 显式分支 |
| `android.aapt2FromMavenOverride` + `android.builder.sdkDownload=false` | `android_gradle.sh:41-45` | ⛔ 桌面**绝不能**写（ARM64 专用）；桌面 gradle-home 独立，不会被污染（`desktop_toolchain.dart:41`） |
| `flutter run -d <serial>` 走 device 会话 | `project_actions.dart:233` | ⚠️ preflight 修好后可用（需 adb + 设备）；无线配对仍不可用（FlitDevice，P2-6） |
| 产物相对路径 `build/app/outputs/flutter-apk/*` | `:20,29` | ✅ 一致 |
| 签名由项目 `key.properties` 决定 | `android/app/build.gradle.kts:11-16,56-69`（本仓库）/ 用户项目模板 | ✅ Windows 不参与；release 包默认 debug 签名，可安装不可上架 |
| 诊断正则只认 `/ndk/` `/aapt2` | `android_build_wrapper.dart:474-478` | ⚠️ 增加 `[/\\]` 兼容（P2-16） |
| `_readRequirements/declaredComponents` 读 gradle 字面量 | `:153-172,352-382` | ✅ 纯 Dart，跨平台可用（可直接复用） |

---

## 6. 任务拆分建议

> 依赖顺序：T1 → T2 → T3 → T4；T5/T6 可在 T2 后并行；T7 收尾。每个任务只动自己 scope 的文件。

| 任务 | 内容 | 写入范围 | 验收 |
| --- | --- | --- | --- |
| **T1**（P0） | 平台 seam：`HostPlatform` + `setHostPlatform` + `Shell`/`EnvironmentStatus` 改用它；修 CI 测试基线（Android 分支测试显式 override） | `lib/core/host_platform.dart`(新)、`lib/services/shell.dart`、`lib/features/environment/environment_status.dart`、`test/support/*`、`test/environment_*_test.dart` | Windows 上 `flutter test test/environment_*_test.dart test/android_build_wrapper_test.dart` 全绿（用 android override）；CI 仍只阻断 local_fs，但新增子集绿 |
| **T2**（P0） | 工具链服务拆层：`layout/download/archive/sdk_manager/probe/installer` + 校验/进度/超时/镜像/系统 adopt；修 `_canRun` 死代码、`tar.exe` 回退、`.bat` 绕开 | `lib/services/desktop_toolchain.dart`、`lib/services/toolchain/*`(新)、`lib/services/github_mirror.dart`(只读引用) | 单测覆盖（§7）；Windows 上手动跑「删掉私有目录 → 一键安装」成功，`status()` 结构判据全 true |
| **T3**（P0） | `DesktopSetupRunner` + `SetupEvent` + controller 接线（`needsBootstrap`、warmup 阶段、`__VER__`、`EnvironmentStatus` 收敛、去重映射） | `lib/features/environment/desktop_setup_runner.dart`(新)、`setup_event.dart`(新)、`setup_runner.dart`(抽接口)、`environment_controller.dart`、`environment_status.dart` | 环境页 3 阶段/8 子任务全 DONE 且有版本号；断网/中断可重试；`allDone=true` 后首页可开工程 |
| **T4**（P0） | 构建前置桌面化：`DesktopComponentProbe` + `installComponent` + `console_command.dart` 抽纯函数 + APK/Web 命令平台分支 + Web 前置 `web/` | `lib/features/environment/android_component_probe.dart`(新)、`android_build_wrapper.dart`、`lib/services/console_command.dart`(新)、`console_session.dart`、`project_actions.dart`、`web_runner.dart` | Windows 上 `flutter build apk --debug` 与 `flutter build web` 从 UI 触发成功；缺组件弹窗→sdkmanager 补装→继续构建；Web 预览走浏览器 |
| **T5**（P1） | 组件管理桌面化：`listInstalled`/`uninstall`/`selectFlutter` + `net_probe.dart` + 组件页/网络检测接线 | `desktop_toolchain.dart`、`lib/services/net_probe.dart`(新)、`environment_controller.dart`、`widgets/*` | 组件页显示真实版本/体积/来源；可删除/切换；网络检测有 `__NET__` 结果 |
| **T6**（P1） | Git/ADB/代理/环境变量对齐 + 新建工程预检修复 + `BackgroundAccess` 桌面早退 | `git_repo.dart`、`desktop_shell.dart`、`desktop_toolchain.dart`、`create_project_page.dart`、`background_access.dart`、`workbench_page.dart` | Git 面板可用（status/diff/commit）；新建工程按钮可用；首次启动不弹后台权限说明 |
| **T7**（P2） | l10n、UI note、windows/ runner 入库、CI 阻断、文档（`docs/windows-environment.md`） | `environment_controller.dart`、`l10n/*`、`windows/`、`.github/workflows/windows-build.yml`、`docs/*` | CI 全量测试 0 失败（或明确 skip 列表）；Windows 产物可复现 |

---

## 7. 可断言的纯 Dart 单测清单

> 前提：所有测试都在 **Windows 宿主**上跑（或至少不依赖 flutter 可执行）。要点是把「会 spawn 进程 / 依赖平台常量」的逻辑抽成**纯函数 + 注入 seam**。

### 7.1 现有测试的阻塞点（先修才能写新测试）

- `isDesktopPlatform = !Platform.isAndroid`（`shell.dart:19`）→ 桌面宿主上所有 Android 分支测试走桌面分支：`environment_controller_test.dart:89` 的 `expect(environment.allDone, true)` 在 CI 上实际失败（日志确认）。
- 直接 spawn `bash` 的测试在 Windows 必失败：`catalog_install_test.dart:32,66,74`、`setup_runner_test.dart:33`、`project_files_test.dart:36`、`git_repo_test.dart:7`、`project_git_test.dart:60`、`terminal_appearance_test.dart:79`。
- 建议：`test/support/flit_plugins.dart` 增加 `setHostPlatform(HostPlatform.android)`；对「需要 bash」的测试加 `skip: !HostPlatform.supportsPosixShell`，或改用注入的 `ProcessRunner` fake。

### 7.2 待新增：纯 Dart 断言清单（按文件）

| 测试文件（建议） | 断言内容 | 纯化点（现有代码） |
| --- | --- | --- |
| `test/host_platform_test.dart` | `setHostPlatform(windows)` → `isDesktopPlatform==true`；`android` → false；恢复后无副作用 | 新 seam（T1） |
| `test/toolchain_layout_test.dart` | `ToolchainLayout(home:'C:\\FlitDesk')` 的 `jdkDir/flutterExe/gitExe/adbExe`；`childEnvironment(baseEnv: {...})` 断言 `JAVA_HOME/ANDROID_HOME/PUB_CACHE/GRADLE_USER_HOME`、`Path` 顺序与分隔符（`;` vs `:`）、不注入 `LD_*`/`TMPDIR` | `desktop_toolchain.dart:22-81`（抽成 `layout.dart`） |
| `test/toolchain_probe_test.dart` | 在临时目录里造 `jdk/release`+`jdk/bin/java.exe`、`flutter/bin/flutter.bat`+`bin/cache/dart-sdk/bin/dart.exe`+`bin/cache/flutter_tools.stamp`、`sdk/{platform-tools/adb.exe, platforms/android-36/android.jar, build-tools/36.0.0/{aapt2.exe,source.properties}}`、`git/cmd/git.exe` → `probe()` 全 true；删任一文件 → 对应 false；`source.properties` 的 `Pkg.Revision` 参与版本解析 | `desktop_toolchain.dart:85-104`（`status` 拆结构判据）；`component_checks.sh:5-7` 的 `package_revision` 逻辑 |
| `test/toolchain_probe_version_test.dart` | `pkgRevision('Pkg.Revision = 36.0.0')` → `'36.0.0'`；`JAVA_VERSION="17.0.11"`（jdk/release）→ `'17.0.11'`；`<flutter>/version` → `'3.47.8'`；空文件/异味 → null | `desktop_toolchain.dart:428-449`（`versionOf` 改成文件解析） |
| `test/download_test.dart` | 注入 `FakeHttp`（返回字节/3xx/HTML 错误页/超长挂起） → 断言：重定向跟随上限、`onProgress` 回调次数与百分比、`sha256` 不匹配时删除临时文件且不落位、断点续传 Range 头、`idleTimeout` 触发取消、缓存命中要求 sha 匹配（**破坏当前 >1MB 启发式**） | `desktop_toolchain.dart:338-397` |
| `test/archive_test.dart` | 注入 `ProcessRunner` fake：tar.exe 返回 0 → 一次调用；返回非 0 → 走 PowerShell 且参数是单条 `Expand-Archive`；抛 `ProcessException`（tar 不存在）→ 也走 PowerShell；两者失败 → 抛 `ToolchainException` 含提示 | `desktop_toolchain.dart:401-419` |
| `test/sdk_manager_test.dart` | `install(['build-tools;36.0.0','platforms;android-36'])` 生成 `java -classpath <jar> com.android.sdklib.tool.sdkmanager.SdkManagerCli --sdk_root=<sdk> ...` 参数数组（含空格路径保持单参数、不经 shell）；`acceptLicenses()` 写入的 `y` 数量与关闭 stdin；非 0 退出码→异常 | 新 `sdk_manager.dart`（替 `desktop_toolchain.dart:190-276`） |
| `test/toolchain_installer_test.dart` | 注入 fake download/extract/probe：全新 home → 依次 jdk/sdk/git/flutter；已存在且校验通过 → 跳过；校验失败 → 重下且不动已装目录；解压失败 → 保留旧版本；返回事件序列为 `stage(RUNNING) → log/progress → stage(DONE)` | `desktop_toolchain.dart:125-259`（拆 `installer.dart`） |
| `test/desktop_setup_runner_test.dart` | `needsBootstrap==false`；`plan` 与 `readyStageIds` 完全一致（防漏）；`check()` 输出的 8 个 id 恰好等于 `readyStageIds`；NDK/CMake/Gradle 标记 DONE 且带 `note`；warmup 阶段失败 → `FAILED` + 后续 `BLOCKED`（复用 `_blockAfter` 语义） | `environment_controller.dart:40-70,824-836`；新 runner |
| `test/setup_event_parity_test.dart` | 把 `DesktopSetupRunner.check()` 产出的 marker 文本喂给 `EnvironmentStatus.fromCheck(exitCode:0)` → `ready==true`；喂 `exitCode:1`/缺一个 id → `ready==false`（与 Android `__STAGE__` 语义零差异） | `environment_status.dart:32-46`（纯） |
| `test/android_component_probe_test.dart` | 造 SDK 目录 + gradle 文本：`compileSdk = 36` / `buildToolsVersion = "35.0.0"` / `ndkVersion "28.2.13676358"` / cmake block → `declaredComponents` 结果；`check(..., baseline:true)` 在只有 `build-tools/35.0.0` 时不再要求 36.0.0（对齐 `android_build_wrapper.dart:204-218` 的豁免逻辑）；`--device` 只查 platform-tools；Windows 反斜杠路径正常 | `android_build_wrapper.dart:352-382`（可复用）+ 新 probe |
| `test/console_command_test.dart` | `normalizeConsoleCommand(cmd, platform: android)` 原样；`windows`：`bash "…android_build.sh" flutter build apk` → `flutter build apk`；`mkdir -p 'X' && cd 'X' && flutter create …` → `if not exist "X" mkdir "X" & cd /d "X" && …`；`mkdir -p build && dart compile …`（无 cd）→ `if not exist "build" mkdir "build" & …`（修 P2-3）；单引号→双引号转义 | `console_session.dart:115-152`（抽 `console_command.dart`） |
| `test/build_command_test.dart` | `apkBuildCommand(platform: windows, release:false) == 'flutter build apk --debug --target-platform android-arm64 2>&1'`；`android` 保留 bash 前缀；`webRunCommand(platform: windows)` 不含 `[ ! -d web ]`/`stty`，含 `--web-port <p>`；`webBuildCommand` 含 `--release` | `project_actions.dart:13-53`、`web_runner.dart:86-92` |
| `test/git_command_test.dart` | `GitRepo.commandFor(args, root:'C:\\a b\\proj', platform:windows)` 用双引号、无 `LC_ALL=`/`GIT_SSH_COMMAND='…'`、`--literal-pathspecs` 保留；Android 版与本仓库现状逐字符相等（回归保护） | `git_repo.dart:50-52` |
| `test/posix_shim_test.dart` | 5 类惯用法的匹配/未匹配：`command -v adb`、`env -0`、`[ -e 'p' ]` / `[ -L 'p' ]`、`[ -f 'p' ] && echo RESOLVED`、`cat 'p' 2>/dev/null`、find 列表/文件树；未匹配返回 `null`（防止静默落回 cmd）；`command -v` 命中时用 `which()` 的绝对路径（修 P1-6） | `desktop_shell.dart:204-300`（抽 `posix_shim.dart`） |
| `test/toolchain_version_constants_test.dart` | `DesktopToolchain.defaultBuildTools == ToolchainCatalog.sdkVersion`；`defaultPlatform == 'android-${ToolchainCatalog.platformVersion}'`；`cmdlineToolsBuild` 非空且 URL 可解析（防漂移） | `desktop_toolchain.dart:34-36` vs `toolchain_catalog.dart:35-36` |
| `test/net_probe_test.dart` | 注入 fake HttpClient：200 → `__NET__name` 标记（HTTP 码与耗时）；超时/无响应 → `000`；镜像前缀存在时多一个目标 | `environment_controller.dart:301-320` + 新 `net_probe.dart` |
| `test/environment_status_desktop_test.dart` | `EnvironmentStatus.fromStageMarkers(...)`：全 DONE → ready；任一 MISSING → not ready；`checkFailed` 与 exitCode 的关系（对齐现有 `environment_status_test.dart` 的 Android 用例） | `environment_status.dart:22-46`（纯）+ 新映射 |
| `test/local_fs_test.dart`（已存在） | 继续作为 Windows 阻断基线（CI 已跑，10 tests） | `local_fs.dart` |

### 7.3 不需要 flutter 可执行的断言点（一句话版）

- **协议层**：`parseStageMarker/parseVersionMarker/parseNetMarker`、`EnvironmentStatus.fromCheck`、`InstalledToolchain.parse`、`declaredComponents`、`matchesAsset`、`parseSha256` —— 全是纯函数，Windows 上可直接断言（`environment_status_test.dart` 在 CI 上确实是通过的）。
- **命令层**：一旦把 `ConsoleSession._normalizeForDesktop`、`ProjectBuild` 命令、`GitRepo.command` 抽成「平台参数化纯函数」，就与 flutter 无关。
- **目录判据层**：`ToolchainProbe` 只依赖 `File/Directory/FileSystemEntity`（像 `local_fs_test` 那样建临时树），不 exec。
- **安装编排层**：把 `Downloader/Archive/SdkManager/Probe` 注入成 fake，验证「顺序、跳过、重试、落位、事件序列」，不触网。

---

## 8. 附录

### 8.1 CI 基线（GitHub Actions，2026-11-07）

- 工作流：`Windows Build`（`.github/workflows/windows-build.yml`），run **42348982433**，branch `main`，head `b02a4cc`，**success**（约 4m21s）。
- 环境：`runs-on: windows-latest`，Flutter **stable 3.47.9 x64**（`FLUTTER_ROOT=...stable-3.47.9-x64`）。
- 关键步骤结果：
  - `Unit tests (LocalFs，阻断)`：**10 tests passed**（日志 `🎉 10 tests passed.`）。
  - `Full test suite (仅记录)`：**231 tests passed, 96 failed**（`continue-on-error: true`，所以 step conclusion 显示 success）。
  - 失败分布（按文件，共 96）：`run_controls_test` 16、`editor_page_test` 15、`device_connection_test` 11、`device_connect_page_test` 11、`project_files_test` 9、`settings_pages_test` 6、`environment_controller_test` 5、`project_storage_test` 4、`web_preview_test` 3、`android_build_wrapper_test` 3、`project_actions_test` 2、`git_repo_test` 2、`catalog_install_test` 2，其余各 1（`setup_runner_test`、`github_mirror_test`、`terminal_log_test`、`project_git_test`、`git_panel_test`、`auto_connect_test`、`appearance_preferences_test`）。
  - 失败样例（对本文最有价值的两条）：
    - `environment_controller_test.dart:89` — `Expected: <true> / Actual: <false>`（桌面宿主走桌面分支，`allDone` 恒 false）。
    - `android_build_wrapper_test.dart: preflight asks once...` — 期望 `… '28.2.13676358'`，实际 `bash "…/android_ndk.sh" --release "…" "…" "28.2.13676358"`（命令拼装相关断言）。
- 结论：**「全量测试通过」这个前提目前不成立**，Windows 移植的任何方案都必须先决定「哪些测试在哪个平台跑」，否则回归无信号。

### 8.2 相关事实/文档

- Android 侧安装协议与判据：`docs/runtime-environment.md`（安装顺序 `:5-11`、发行获取 `:13-19`、版本目录 `:21-33`、构建前检查 `:61-68`、目录布局 `:70-86`）。
- 架构与状态归属：`docs/architecture.md`（`Shell` 等无状态边界保留门面；`EnvironmentController` 编排安装；`EnvironmentStatus` 是首页与设置页的同一判据）。
- bionic aarch64 边界：`README.md:61,79`、`README.zh-CN.md:61,79`、`docs/runtime-environment.md:19`。
- 现有 Windows 移植提交（用于理解设计意图）：`1d1e632`（纯 Dart 文件层/环境层/终端/cmd 命令归一化）、`564d9e0`（mkdir -p/cd/引号归一化）、`8162285`（WebView 降级）、`ceadff1`（打包 VC++ 运行库）、`38ac182`/`89a71f9`（LocalFs 测试 + 工具链文件）。

### 8.3 需要真机/Windows 主机复验的假设（本次无 dart/flutter，未能验证）

1. **首次 `flutter --version` 的真实耗时**（决定 warmup 超时；建议 15~30min 上限 + 可跳过）。
2. **`Process.run('flutter', [...])` 用裸名时 Windows 是否解析到 `flutter.bat`**（本文按「`.bat` 由系统 shell 启动、但裸名仍按 `.exe` 查找」推断为失败；需实机确认，这决定 P1-6 的严重度）。
3. **MinGit zip 的根目录结构**（代码假设解压后 `cmd/git.exe` 在根，`desktop_toolchain.dart:222-223`）；若实际有顶层目录，`gitExe` 路径要改。
4. **`tar.exe` 解 Flutter 1GB zip 的耗时/长路径表现**（`%LOCALAPPDATA%` 较深时是否触发 MAX_PATH）。
5. **`sdkmanager --licenses` 在 ConPTY/子进程 stdin 下的行为**（`desktop_toolchain.dart:261-276` 写 60 个 `y`）。
6. **`flutter_pty` 0.4.2 的 ConPTY 在 Windows 上 `cmd.exe /K` 的交互/尺寸/退出码**（`pty_launcher.dart:67-92`、`:108-119`）。
7. **`adb devices` 在 Windows 子进程的输出编码/换行**（`adb_ops.dart:116-122` 依赖 `List of devices attached` 字符串）。
8. **`Expand-Archive` 回退路径的可用性**（`desktop_toolchain.dart:407-415`）。
9. **Flutter 版本漂移**（CI 3.47.9 / catalog 3.47.8 / 桌面 latest）对构建产物与测试的影响。

---

*本报告只读分析，未修改 `lib/`、`assets/`、`pubspec`、workflow；唯一写入文件为本文件。*