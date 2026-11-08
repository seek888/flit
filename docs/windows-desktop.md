# Windows 桌面版

Flit 原本是「在 Android 手机上开发 Flutter 应用」的工作台。这个 fork 把同一套
工作台搬到了 Windows 桌面：**在 Windows 上创建/打开 Flutter 工程、编辑代码、用
终端跑 Flutter/Dart 命令、管理 Git 并推送到 GitHub、打包出 Android APK 与 Web 产物**。

> 平台目录：仓库里同时有 `android/` 与 `windows/`（Flutter 3.47.8 模板 + Flit 定制）。
> Linux/macOS 桌面共用大部分桌面代码路径，但当前只对 Windows 做交付与验证。

## 1. 获取与安装

两种分发形态，功能相同：

| 形态 | 文件 | 说明 |
| --- | --- | --- |
| 安装版（推荐） | `FlitSetup-<版本>-x64.exe` | Inno Setup 打包，**per-user 安装**（`%LOCALAPPDATA%\Programs\Flit`），无需管理员权限；带开始菜单/桌面快捷方式与卸载项 |
| 便携版 | `flit-windows-x64-<版本>-<sha>.zip` | 解压后直接运行 `flit.exe` |

产物来自 GitHub Actions 的 **Windows Build** 工作流（推送到 `windows/**` 或手动
dispatch 触发），同时发布到 Releases（tag 形如 `win-v1.0.0-preview.2.<run>`）。
安装包内已带 VC++ 运行库 DLL，干净机器无需预装 Redistributable。

## 2. 首次启动：安装开发环境

Windows 版**不依赖**你预先安装 Flutter/Android SDK/JDK，也**不会**修改系统 PATH 或
注册表。所有工具链安装在应用私有目录：

```
%LOCALAPPDATA%\FlitDesk\
├── jdk\            Temurin 17 (x64)
├── android-sdk\    cmdline-tools / platform-tools / platforms / build-tools (+ 按需 NDK/CMake)
├── flutter\        官方 Flutter SDK (stable)
├── git\            MinGit（仅在系统没有 git 时安装）
├── gradle-home\    GRADLE_USER_HOME
├── pub-cache\      PUB_CACHE
├── projects\       工程目录
├── cache\          下载缓存
└── exports\        构建产物导出目录
```

进入 **开发环境** 页，点「一键安装」：

1. **基础环境**：桌面端没有 Termux bootstrap，这一步直接视为就绪。
2. **Android 工具链**：JDK 17 → cmdline-tools → platform-tools / platforms / build-tools
   （通过 `sdkmanager`，用 `java -classpath sdkmanager.jar` 调用，绕开 `.bat` 引号问题）
   → Gradle（由工程里的 `gradlew.bat` 首次构建时下载）。
3. **Flutter 工具链**：Git（MinGit 或系统 git）→ Flutter SDK → **预热**（首次
   `flutter --version` 会下载 Dart SDK/引擎工件，可能需要几分钟，这一步是真实阶段）。

- 下载会显示进度、校验摘要（Flutter 清单自带 SHA-256；Android SDK 包用镜像
  `repository2-3.xml` 里的 sha1；其余来源记录首次摘要做 TOFU），缓存包校验
  不通过会重下，半截包不会当成完整缓存。
- 系统里若已有 git，会优先「采用」系统 git（不重复安装）；JDK/Android SDK/Flutter
  固定用私有版本，保证版本可预期。
- NDK / CMake / Gradle 在桌面端标为「按需安装」：项目需要时由构建前的组件检查
  提示并用 `sdkmanager` 补齐。

### 2.1 下载源与国内镜像（默认即镜像，失败自动回退）

桌面端所有下载都在 `lib/services/toolchain/layout.dart` 一处配置，默认全部走
国内镜像，并保留「镜像失败 → 官方源」的回退链。日志第一行会打印本次实际使用的
下载源，排障先看它。

| 组件 | 默认源（国内） | 回退 | 构建期覆盖（`--dart-define`） | 运行期覆盖（同名环境变量） |
| --- | --- | --- | --- | --- |
| Temurin JDK 17 | 清华 TUNA `mirrors.tuna.tsinghua.edu.cn/Adoptium`（目录镜像） | `api.adoptium.net` 官方 API（带 sha256/大小） | `FLIT_JDK_MIRROR_BASE`（空 = 只用官方） | 同左 |
| Android SDK（cmdline-tools + platform-tools / platforms / build-tools / NDK / CMake） | 腾讯云 `mirrors.cloud.tencent.com/AndroidSDK`（与官方 `repository2-3.xml` 同构，逐包 sha1） | `dl.google.com/android/repository` | `FLIT_ANDROID_SDK_BASE`（写官方地址 = 官方源；运行期空值会被忽略） | 同左 |
| Flutter SDK | `storage.flutter-io.cn`（清单自带 SHA-256，强校验） | `storage.googleapis.com` | `FLIT_FLUTTER_STORAGE_BASE_URL` | 同左 |
| pub 包 | `pub.flutter-io.cn` | `pub.dev` | `FLIT_PUB_HOSTED_URL` | 同左 |
| Git（MinGit） | GitHub 加速前缀，默认 `gh-proxy.com`，自动追加 `ghfast.top`、`ghproxy.net` 作候选 | 直连 `api.github.com` / `github.com` | `FLIT_GH_PROXY`（可写多个，逗号分隔；空 = 只直连） | 同左 |
| Gradle 发行版（构建 APK 时） | 腾讯云 `mirrors.cloud.tencent.com/gradle`（构建前按工程的 wrapper 版本预置到 `gradle-home`） | 阿里云 macports 镜像 → `services.gradle.org` | `FLIT_GRADLE_MIRROR_BASE` | 同左 |

要点：

- **运行期环境变量优先于编译期默认值**：不重新构建也能换源，例如
  `set FLIT_ANDROID_SDK_BASE=https://dl.google.com/android/repository`。
- Android SDK 的镜像不是「换个 URL 下载」那么简单：`sdkmanager` 通过
  `SDK_TEST_BASE_URL` 才知道仓库根，而且**只接受带尾斜杠的目录 URL**
  （写成别的形式时它会打印 `Warning: Ignoring invalid SDK_TEST_BASE_URL`
  并静默回退官方源，日志里会看到这条警告）。桌面端在子进程环境里注入
  `SDK_TEST_BASE_URL=<镜像根>/`，因此**包元数据、包本体和 sha1 校验都来自镜像**，
  与直接连 Google 等价。
- GitHub 前缀是可回退列表：某个公共代理被限流/下线时自动试下一个，最后直连兜底。
- 官方源仍然可用：用 `--official` 跑验证工具，或把上述变量设为官方地址/空值。

### 2.2 验证工具（真实网络自检）

`tool/verify_toolchain.dart` 会把工具链装进指定目录（默认系统临时目录），真实执行
`java -version` / `flutter --version` / `adb version` / `git --version` /
`sdkmanager --version`，最后打印结构判据和 `__STAGE__/__VER__` marker：

```powershell
dart tool/verify_toolchain.dart --home D:\flit-verify\home       # 全量，走国内镜像
dart tool/verify_toolchain.dart --stages jdk,sdk --official      # 只验官方源回退
dart tool/verify_toolchain.dart --home D:\flit-verify\home --clean
```

退出码 `0` 表示环境就绪；`1` 表示有阶段失败（日志里会写清是哪个源失败、回退到
哪个源又失败）。这个脚本只依赖 `dart:io`，可以直接 `dart` 运行，不需要先
`flutter pub get`。

## 3. 创建 / 打开工程

- **新建**：项目列表 → 新建，选择模板/语言/平台与包名。工程创建在
  `%LOCALAPPDATA%\FlitDesk\projects\<name>`；桌面端用参数数组直接调用
  `flutter create` / `dart create`，不再依赖 bash。
- **克隆**：填写仓库地址。桌面端用 `git clone`（参数数组 + `Process.run`），
  目标目录用 Dart 创建；SSH 地址（`git@github.com:...`）会自动转成 HTTPS 并提示
  （MinGit 不自带 `ssh.exe`）。
- **打开已有目录**：复制路径到项目列表的打开入口（路径允许 `C:\a\b` 或 `C:/a/b`）。

## 4. 编辑、终端与语言服务

- 编辑器：语法高亮与文件编辑可用。**Dart 语言服务（补全/诊断/签名帮助）在 Windows
  首版尚未接入**：`flit_lsp` 是 Android 原生通道，桌面端暂时显示「语言服务不可用」，
  编辑器降到纯编辑模式（后续版本会用本地 `dart language-server` 进程替代）。
- 终端：交互式终端用 Windows **ConPTY**（`flutter_pty`）跑 `cmd.exe`；一次性命令
  （构建、Git、pub 等）走参数数组进程，不做 shell 字符串拼接。为兼容历史命令，
  `lib/services/console_command.dart` 负责把 POSIX 形状的命令归一成 cmd 语法。
  注意：`flutter_pty` 0.4.2 的 Windows 实现按字节处理环境变量与工作目录，
  **用户目录/工程路径含中文时终端可能启动失败**——首版请把工具链与工程放在
  纯英文路径下（`%LOCALAPPDATA%\FlitDesk` 对英文用户名是安全的）。
- 文件树：桌面端显示工程内全部文件（含 `.gitignore`/`.metadata` 等点文件），
  「共享存储」页签是 Android 专属，桌面隐藏；浏览根为 `%USERPROFILE%`。
- 快捷键与非触摸交互：编辑器内使用键盘；双指缩放是触摸专属，桌面请用设置里的字号。

## 5. Git 与 GitHub

- Git 面板：状态、暂存、提交、分支、拉取/推送。所有 Git 调用都走
  `git.exe` + 参数数组（`workingDirectory` 即工程根），不再拼 POSIX 命令串，
  因此中文路径、带空格路径、中文提交信息都能正常工作。
- 登录 GitHub（**个人访问令牌 PAT**）：
  1. 在 GitHub → Settings → Developer settings → Personal access tokens 生成令牌，
     勾选 `repo` 权限；
  2. Flit 里打开 **设置 → GitHub 账户**（或 Git 面板底部 / 克隆页）粘贴令牌；
  3. Flit 用 `GET https://api.github.com/user` 校验，然后写应用私有配置文件：
     `%LOCALAPPDATA%\FlitDesk\.flit\gitconfig`（只用于 Flit 的 Git 进程，
     `GIT_CONFIG_GLOBAL` 指向它，**不改你的全局 `~/.gitconfig`**）与
     `git-credentials`（`credential.helper=store` 指向该文件）。
  4. 之后私有仓库克隆、`git push` 都无需再次输入凭据。
- 令牌只保存在本机应用目录；退出登录会删除凭据。OAuth 设备流（浏览器授权码）
  代码已就绪但默认关闭：构建时提供 `--dart-define=FLIT_GH_CLIENT_ID=<OAuth App client id>`
  才会启用。

## 6. 打包构建：Android APK 与 Web

在编辑器顶栏的「任务」面板里：

| 构建项 | 命令（Windows） | 产物 |
| --- | --- | --- |
| APK（调试） | `flutter build apk --debug --target-platform android-arm64` | `build/app/outputs/flutter-apk/app-debug.apk` |
| APK（发布） | `flutter build apk --release --target-platform android-arm64` | `build/app/outputs/flutter-apk/app-release.apk` |
| Web（发布） | `flutter build web --release` | `build/web/index.html`（整目录） |

- 构建前会做**纯 Dart 组件检查**（等价 Android 版的 `android_components.sh`）：
  缺 `build-tools`/`platforms`/`platform-tools`/NDK/CMake 时给出确认框，并可用
  `sdkmanager` 自动补齐（不再执行 bash 脚本，Windows 上没有 WSL 也能用）。
- 构建前还会**预置工程所需的 Gradle 发行版**：读取工程里的
  `android/gradle/wrapper/gradle-wrapper.properties`，按 Gradle Wrapper 的规则
  （`<gradle-home>/wrapper/dists/<发行版名>/<base36(MD5(url))>/`）从国内镜像下载、
  解压并写入 `<发行版名>.zip.ok` 标记。这样 `gradlew` 直接命中缓存，不会去连
  `services.gradle.org`——国内网络下这是 `flutter build apk` 最常见的失败点。
  已经在缓存里的发行版会跳过（不联网）。
- Web 构建前若工程没有 `web/` 目录，Flit 会先在 Dart 侧执行
  `flutter create --platforms=web .`。
- 产物会显示成文件卡：APK 可「打开所在文件夹」「导出副本」；连接了设备时还可
  `adb install -r` 安装。Web 产物以 `build/web/index.html` 为入口展示，
  可打开文件夹或导出整个目录。
- 导出目录：`%LOCALAPPDATA%\FlitDesk\exports\<工程名>\`（文件名带时间戳）。
- Android 构建**不需要** Windows 上有 NDK/CMake，除非工程本身包含原生代码。

## 7. 设备与 ADB

- `adb devices` / `adb connect <host:port>` / `adb pair` 可用（来自私有
  `platform-tools`），终端里显示流式输出。
- Android 专属的「无线调试配对（NSD/通知）」在桌面端隐藏：请用 USB 或手动
  `adb pair` + `adb connect`。

## 8. 已知边界（Windows 首版）

- **SSH 克隆/推送**：MinGit 不含 `ssh.exe`，只支持 HTTPS（应用会自动把 GitHub
  SSH 地址转 HTTPS）。若想用 SSH，可在设置中用系统 Git（需自带 OpenSSH）。
- **内嵌 Web 预览**：Windows 没有 `webview_flutter` 实现，Web 预览改为启动本机
  dev server 并用系统浏览器打开。
- **文件选择对话框**：暂未引入原生文件选择器；导入/导出用路径输入 + 打开资源管理器。
- **窗口尺寸/位置记忆**：窗口默认 1280×800、最小 960×640（按 DPI 缩放），暂不记忆上次位置。
- **自更新**：「检查更新」可下载新版本产物，但暂不自动替换运行中的程序。
- **l10n**：部分桌面新增文案目前是中文硬编码（随版本逐步迁入 ARB）。
- **跳过预热**：离线导致 `flutter --version` 预热失败时，环境页暂没有「跳过预热」按钮
  （API 已提供 `EnvironmentController.skipWarmup()`），需要联网完成一次预热才能就绪。
- **Dart 语言服务 / LSP**：Windows 首版不可用（见第 4 节）。
- **Linux/macOS**：桌面代码路径共用，但当前未做交付验证；部分下载源按 Windows 资产。

## 9. 从源码构建（Windows）

需要 Flutter **3.47.8**、Visual Studio 2022/2026（含“使用 C++ 的桌面开发”）、
JDK 17 与 Android SDK（仅用于构建 Android 目标；构建 Flit 自身不需要）。

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release --dart-define=BUILD_SHA=<sha> --dart-define=FLIT_APP_REPO=seek888/flit
# 安装包（需 Inno Setup 6）：
iscc /DAppVersion=1.0.0-preview.2 /DBuildSha=abc1234 windows\installer\flit.iss
```

CI：`.github/workflows/windows-build.yml` 负责 `analyze → test → build windows →
便携 zip + 安装包 → Release`，并有一个 `desktop-build-smoke` job 在 Windows 上
用最小工程真跑 `flutter build web` 与 `flutter build apk`，证明宿主构建链可用。
Android APP 自身的发布仍在 `.github/workflows/android-release.yml`，两者互不影响。

## 9.5 验证状态（这个分支实际跑过什么）

### 9.5.1 CI（GitHub Actions，windows-latest）

| 项目 | 结果 | 说明 |
| --- | --- | --- |
| `flutter analyze`（Flutter 3.47.8） | ✅ 0 issue | 新增 desktop 代码与测试全部通过 |
| `flutter build windows --release` | ✅ | 产物含 `flit.exe`、`flutter_windows.dll`、`flutter_pty.dll`、运行库 DLL |
| Inno Setup 安装包 | ✅ | `FlitSetup-1.0.0-preview.2-x64.exe`（per-user，含中文向导）随 Release 发布 |
| Windows 宿主构建链冒烟 | ✅ | 在 windows-latest 上用最小 Flutter 工程真跑 `flutter build web --release` 与 `flutter build apk --debug`，产物存在 |
| Android APK 发布工作流 | ✅ 未改动 | `android-release.yml` 保持原样，只共享 Flutter 版本号 |
| 全量 `flutter test` | 414 passed / 17 failed / 3 skipped | 失败项是平台假设差异（非阻断）；见下 |

### 9.5.2 真机验证：国内网络从零安装 + 构建（2026-11-08）

环境：Windows 11（25H2）；`services.gradle.org`、`api.adoptium.net` 直连不可用，
Flutter/腾讯云/清华/阿里云镜像可达（典型国内家用网络）。

**① 一键安装（真实网络）** —— `dart tool/verify_toolchain.dart --home <目录>`

| 阶段 | 实际下载源 | 结果 |
| --- | --- | --- |
| JDK 17 | 清华 TUNA Adoptium 目录镜像 | ✅ Temurin 17.0.20.1（182 MB），`java -version` 正常 |
| Android SDK | 腾讯云 AndroidSDK 镜像（`SDK_TEST_BASE_URL` 重定向；元数据/包本体/sha1 都来自镜像） | ✅ cmdline-tools 13114758、platform-tools 37.0.1、platforms;android-36、build-tools;36.0.0；许可接受完成 |
| Git | 采用系统 Git（不重复下载 MinGit） | ✅ 2.51.1 |
| Flutter | `storage.flutter-io.cn` | ✅ 3.47.9（1.81 GB），SHA-256 与清单 `d8e2b597…` 一致 |
| 预热 | 同上镜像（Dart SDK / 引擎产物） | ✅ 3.47.9 |
| 结构判据 | — | ✅ 8 个 `__STAGE__` 全 DONE，环境判为就绪 |

`flutter doctor -v`（使用该私有工具链的环境变量执行）：Android toolchain ✅
（Platform android-36 / build-tools 36.0.0 / licenses accepted）、Visual Studio ✅、
Network resources ✅。

**② APK 构建（含 Gradle 发行版镜像）**

| 项目 | 结果 | 说明 |
| --- | --- | --- |
| Gradle 9.3.1 发行版 | ✅ | 直连 `services.gradle.org` 失败；构建前预置从腾讯云 gradle 镜像下载 234 MB，按 wrapper 规则落到 `gradle-home/wrapper/dists/…`（含 `.zip.ok`），`gradlew --version` 命中缓存 |
| `flutter build apk --debug --target-platform android-arm64` | ✅ | 首轮 660 s（AGP 依赖 + AGP 自动补 NDK r28c），增量 45 s；产物 `app-debug.apk` 77 MB |

**③ 代码质量**

| 项目 | 结果 |
| --- | --- |
| `flutter analyze`（Flutter 3.47.9） | ✅ 0 issue |
| 全量 `flutter test` | 442 passed / 3 skipped / 10 failed；这 10 项与**未改动的基线 HEAD 完全相同**（Windows 上缺 bash、平台假设差异），非回归 |
| 新增单测 | `toolchain_mirror_test`、`download_first_test`、`md5_test`、`gradle_wrapper_test`，以及 Flutter 新版布局的探测用例 |

验证过程顺带修掉的真实问题（都会导致「装完仍判未就绪」或「构建直接失败」）：

1. `SDK_TEST_BASE_URL` 只接受**带尾斜杠的目录 URL**；写成 `…/{url}` 会被静默忽略并回退
   `dl.google.com`（日志里是 `Warning: Ignoring invalid SDK_TEST_BASE_URL`）。
2. Flutter 3.47 起移除了 `<flutter>/version`（`omit-legacy-version-file` 特性），版本在
   `bin/cache/flutter.version.json`；旧判据把已安装 SDK 判成 MISSING。
3. `cmdline-tools` 的 classpath jar 是 `lib/sdkmanager-classpath.jar`（不是 `sdkmanager.jar`），
   旧判据会让 Android SDK 阶段永远「未就绪」。
4. Gradle Wrapper 缓存目录名是 `base36(MD5(distributionUrl))`，且必须有 `<发行版 zip>.ok`
   标记；缺任何一项，`gradlew` 都会重新下载。

**仍未在真机上验证过的**：

- 从 Flit **UI** 点按钮触发的完整链路（本次用 `tool/verify_toolchain.dart` 与命令行复现了
  同样的安装/构建步骤，UI 只多一层状态展示）。
- 终端 ConPTY 的交互体验、中文路径限制（见第 4 节）。
- 安装包在普通用户机器上的安装/卸载体验、SmartScreen 提示。

建议按「安装版 → 开发环境一键安装 → 新建工程 → 提交到 GitHub → 构建 APK/Web」
的顺序在真机上走一遍，再把问题反馈到 Issues。

## 10. 排障

| 症状 | 处理 |
| --- | --- |
| 环境页一直提示“未就绪” | 看环境页控制台输出：第一次安装需要下载约 2~3 GB；确认网络/镜像可达；「继续安装」会从断点续装 |
| `flutter build apk` 报缺少 build-tools/platforms | 按弹窗确认自动补齐，或在环境页重新执行 Android 工具链阶段 |
| `Gradle task assembleDebug failed` / 日志里 `ConnectException` 指向 `services.gradle.org` | 构建前的 Gradle 发行版预置没命中缓存：确认 `FLIT_GRADLE_MIRROR_BASE`（默认腾讯云 gradle 镜像）可达；镜像缺该版本时会把工程里的 `distributionUrl` 当最后一个候选直连。手动排查可看 `%LOCALAPPDATA%\FlitDesk\gradle-home\wrapper\dists\` |
| Git push 要求输入凭据/401 | 重新粘贴 PAT（需 `repo` 权限）；确认系统时间正确；私有仓库需要 token 有对应组织授权 |
| 中文路径下终端无输出 | 说明 PTY 无法处理非 ASCII 环境，Flit 会降级为管道会话；可在终端设置里确认 |
| 安装包启动报缺少 `msvcp140.dll` | 安装版已内置运行库；若用便携版，安装 VC++ 2015-2022 x64 Redistributable |
| 杀软拦截 `flutter_pty.dll` | conpty 相关 DLL 会被个别杀软误报，加入信任或使用安装版 |

日志与诊断：环境安装输出保留在环境页/终端会话里；Git 与构建的输出在「任务」面板
的控制台中（可复制）。