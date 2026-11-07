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

- 下载会显示进度、校验 SHA-256（Flutter manifest 提供摘要；其它来源用固定/记录摘要），
  缓存包校验不通过会重下。
- 国内网络：GitHub 相关下载自动走镜像前缀（与 Android 版一致的 `GithubMirror`），
  Flutter 走 `FLUTTER_STORAGE_BASE_URL`（默认 `storage.flutter-io.cn`），
  pub 走 `PUB_HOSTED_URL`。
- 系统里若已有 git，会优先「采用」系统 git（不重复安装）；JDK/Android SDK/Flutter
  固定用私有版本，保证版本可预期。
- NDK / CMake / Gradle 在桌面端标为「按需安装」：项目需要时由构建前的组件检查
  提示并用 `sdkmanager` 补齐。

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

## 10. 排障

| 症状 | 处理 |
| --- | --- |
| 环境页一直提示“未就绪” | 看环境页控制台输出：第一次安装需要下载约 2~3 GB；确认网络/镜像可达；「继续安装」会从断点续装 |
| `flutter build apk` 报缺少 build-tools/platforms | 按弹窗确认自动补齐，或在环境页重新执行 Android 工具链阶段 |
| Git push 要求输入凭据/401 | 重新粘贴 PAT（需 `repo` 权限）；确认系统时间正确；私有仓库需要 token 有对应组织授权 |
| 中文路径下终端无输出 | 说明 PTY 无法处理非 ASCII 环境，Flit 会降级为管道会话；可在终端设置里确认 |
| 安装包启动报缺少 `msvcp140.dll` | 安装版已内置运行库；若用便携版，安装 VC++ 2015-2022 x64 Redistributable |
| 杀软拦截 `flutter_pty.dll` | conpty 相关 DLL 会被个别杀软误报，加入信任或使用安装版 |

日志与诊断：环境安装输出保留在环境页/终端会话里；Git 与构建的输出在「任务」面板
的控制台中（可复制）。