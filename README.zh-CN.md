<p align="center">
  <img src="assets/branding/logo.png" alt="Flit" width="112" height="112" />
  <a href="https://github.com/seek888/flit/actions/workflows/windows-build.yml"><img src="https://github.com/seek888/flit/actions/workflows/windows-build.yml/badge.svg" alt="Windows Build" /></a>
</p>

<h1 align="center">Flit</h1>

<p align="center">在 Android 上编辑、构建和运行 Flutter 项目的开发工作区。</p>

<p align="center">
  <a href="https://github.com/lycstar/flit/releases"><img src="https://img.shields.io/github/v/release/lycstar/flit?include_prereleases&amp;label=preview&amp;color=39BFEA" alt="Latest preview" /></a>
  <a href="https://github.com/lycstar/flit/actions/workflows/android-release.yml"><img src="https://github.com/lycstar/flit/actions/workflows/android-release.yml/badge.svg" alt="Android Release" /></a>
  <a href="https://github.com/lycstar/flit/stargazers"><img src="https://img.shields.io/github/stars/lycstar/flit?style=flat&amp;color=39BFEA" alt="GitHub stars" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-279CF0" alt="License: GPL-3.0" /></a>
  <img src="https://img.shields.io/badge/Android-7.0%2B-51D7EB" alt="Android 7.0 and above" />
</p>

<p align="center">
  <a href="https://github.com/lycstar/flit/releases">下载预览版</a> ·
  <a href="docs/architecture.md">架构说明</a> ·
  <a href="https://github.com/lycstar/flit/issues">反馈问题</a> ·
  <a href="CONTRIBUTING.md">参与贡献</a>
</p>

[English](README.md) · 简体中文

Flit 支持编辑 Dart 代码、在设备上构建应用、通过无线 ADB 运行应用，以及在编辑器内预览 Flutter Web。

应用 ID：`com.seek888.flit` · Android 7.0+ · arm64-v8a

## 功能

- 创建、克隆和打开应用工程目录中的项目。
- 多文件编辑，支持语法高亮，以及官方 Dart 分析服务器提供的代码补全、诊断和签名提示。
- 在集成终端中执行 shell 命令，实时查看构建、环境安装和 Git 输出。
- 构建 APK，通过无线 ADB 连接 Android 设备，使用 Flutter 热重载与热重启。
- 在工作区内预览 Flutter Web；手机切换代码与预览，宽屏并排显示。
- 使用 Git 暂存、提交、管理分支、拉取和推送；通过设备授权流程登录 GitHub。
- 分享文件，并通过 Android 存储访问框架（SAF）在系统“文件”应用中访问工程。
- 支持简体中文和英文，可在设置中选择跟随系统或指定语言。

## 开始使用

1. 从 [Releases](https://github.com/lycstar/flit/releases) 下载 APK，安装到 arm64 Android 设备。
2. 完成**开发环境**配置。创建或构建项目之前，所有必要组件必须就绪。安装输出会持续显示在终端中。

   ![在 Flit 终端中运行 neofetch，显示 Android 环境](docs/juejin/assets/flit-neofetch.png)

3. 创建或克隆项目，也可以从项目列表打开目录。
4. 选择 Web 预览或连接 Android 设备，运行项目、查看输出，并在编辑时使用热重载或热重启。

| Flutter Web 调试 | Flutter android调试 |
| --- | --- |
| <img src="docs/juejin/assets/flit-web-debug.jpg" width="340" alt="Flit 内运行 Flutter Web 应用，页面显示 Debug 标记，下方终端显示 Dart VM Service" /> | <img src="docs/juejin/assets/flit-hot-reload.gif" width="340" alt="在 Flit 中修改代码并热重载" /> |

本机无线配对需要 Android 11 及以上，并在开发者选项中启用无线调试。对于已配置的 ADB 端点，可手动输入主机和端口连接。配对记录不代表当前已连接：Flit 以 ADB 返回的设备状态为准。

工程保存在应用私有的 `files/home/projects` 目录中。**卸载 Flit 或清除应用数据会删除这些工程。** 请使用 Git 备份，或通过**文件 → Flit 工程**复制。GitHub 登录是可选功能，本地开发不需要账户。

## Windows 桌面版

这个 fork 同时提供 **Windows 桌面版**：在 Windows 上创建/克隆 Flutter 工程、借助分析服务器编辑代码、
在集成终端里运行 Flutter/Dart/Git/ADB 命令、管理 Git 并推送到 GitHub，以及打包出 **Android APK** 与 **Web 产物**。

从 Releases 下载 `FlitSetup-<版本>-x64.exe`（per-user 安装包，无需管理员权限）或便携版
`flit-windows-x64-*.zip`。桌面工具链（Temurin JDK 17、Android SDK、Flutter、MinGit）在首次使用时
安装到 `%LOCALAPPDATA%\FlitDesk`，不修改系统 PATH 与注册表。GitHub 登录使用个人访问令牌（PAT），
凭据保存在应用私有 git 配置里，之后私有仓库克隆与推送无需再次输入。

桌面工具链的下载**默认全部走国内镜像**：Temurin JDK 17 走清华 TUNA 的 Adoptium 目录镜像、
Android SDK（cmdline-tools 与各组件包）走腾讯云 AndroidSDK 镜像、Flutter 与 pub 走
`flutter-io.cn`、GitHub 产物走加速前缀（多个公共代理自动回退）。任一镜像不可用会自动回退官方源，
因此国内网络与直连环境都能装。换源方式（环境变量/`--dart-define`）与验证工具
`tool/verify_toolchain.dart` 见
[下载源与国内镜像](docs/windows-desktop.md#21-下载源与国内镜像默认即镜像失败自动回退)。

安装、环境配置、PAT 登录、构建命令与已知限制见 [docs/windows-desktop.md](docs/windows-desktop.md)。

## 工作原理

在手机上跑通 Flutter 构建链的关键，是分清构建环节里什么可直接复用、什么必须重新编译：Gradle、`d8`、`apksigner` 和 flutter_tools 是 JVM/Dart VM 上的字节码，`android.jar` 与引擎产物是纯数据——这些天然可移植；`aapt2`、`aidl`、`zipalign`、Dart VM、`gen_snapshot` 和 clang 是必须在本机执行的原生 ELF，官方只提供 x86_64 glibc 版本，需要以 bionic 为目标交叉编译。移植按三层展开：自建 Termux 用户空间（bootstrap 与 APT 包）提供 shell 和包管理；交叉编译 Android SDK/NDK/CMake 宿主工具，官方数据与元信息原样保留；交叉编译 Flutter/Dart 宿主工具并复用官方 Android 引擎产物。Gradle 与 AGP 原样复用，通过 `android.aapt2FromMavenOverride` 指向本机 ARM64 AAPT2 并关闭 SDK 自动下载，避免 AGP 拉回桌面版二进制。

完整过程见文章：[如何在 Android 设备上构建 Flutter 应用：Flit 的工具链移植实践](docs/juejin/article.md)。

```mermaid
flowchart LR
    UI[Flutter 工作区] --> State[Provider 作用域与控制器]
    State --> PTY[PTY 控制台会话]
    State --> LSP[Dart 语言服务传输]
    PTY --> Tools[设备端 Flutter / Dart / Git / ADB]
    LSP --> Analyzer[Dart 分析服务器]
    Tools --> Build[Gradle / Android SDK / NDK / JDK]
    Build --> APK[APK]
    APK --> Device[通过 ADB 安装与启动]
    Tools --> Server[Flutter Web 开发服务器]
    Server --> Preview[内嵌 WebView]
```

APK 包含编辑器、原生桥接和安装脚本。开发环境在初始化时单独下载，包括 bootstrap 基础用户环境、OpenJDK、Android SDK/NDK，以及为 **Android bionic aarch64** 构建的 Flutter SDK。桌面 Linux 工具不能替代这些可执行文件。

### 设备端构建链各组件

| 组件 | 在构建中的作用 | 处理方式 |
| --- | --- | --- |
| 终端 / 用户空间 | 提供 shell、包管理器和进程环境 | 为 Flit 私有前缀重建 Termux bootstrap 和 APT 包 |
| OpenJDK | 运行 Gradle 和 Java 工具 | 沿用 Termux 官方包配方交叉编译，通过 APT 安装 |
| Gradle / AGP | 协调 Android 构建和依赖 | 复用官方 Java/JVM 发行版，由 OpenJDK 运行 |
| Android SDK | 提供 Platform、Build Tools 和打包工具 | 交叉编译宿主工具，复用平台资源 |
| NDK / CMake / Ninja | 编译原生插件 | 交叉编译 LLVM 和 CMake/Ninja，再组装 NDK |
| Flutter SDK | 编译 Dart、提供分析和运行工具 | 交叉编译宿主工具，复用 Android 引擎产物 |
| Git、GitHub CLI 等额外工具 | Flutter 工具和应用内功能需要 | 沿用 Termux 官方包配方交叉编译，通过 APT 安装 |

环境就绪后，`flutter doctor -v` 可以在手机上完整识别 Flutter、Android 工具链与 OpenJDK：

| 组件列表 | flutter doctor -v |
| --- | --- |
| <img src="docs/juejin/assets/flit-environment-ready.jpg" width="340" alt="Flit 开发环境页，环境已就绪" /> | <img src="docs/juejin/assets/flit-flutter-doctor.jpg" width="340" alt="Flit 终端中运行 flutter doctor -v，Flutter 3.47.8 和 Android 工具链检查通过" /> |

## 从源码构建

使用 Flutter **3.47.8**、JDK **17**、Android SDK 和 NDK **28.2.13676358**。仓库包含 Gradle Wrapper。`flutter pub get` 会解析本地原生插件及托管依赖。

```sh
flutter pub get
flutter analyze
flutter test
python3 -m unittest discover -s test -p '*test.py'
flutter build apk --debug --target-platform android-arm64
```

发布工作流通过手动触发运行。签名发布需要在仓库 Secrets 中配置 `KEYSTORE_BASE64`、`ANDROID_STORE_PASSWORD`、`ANDROID_KEY_ALIAS` 和 `ANDROID_KEY_PASSWORD`。本地签名使用不纳入版本控制的 `android/key.properties`；未配置发布签名时，本地构建使用调试密钥。

## 运行环境分发

应用只保留仓库和默认版本，安装时按 tag 从 GitHub API 获取下载资产与 SHA-256，不内置下载清单。bootstrap 和 APT 软件包必须针对 `/data/data/com.seek888.flit/files/usr` 编译。修改下载地址或应用 ID，不能迁移为其他应用编译的二进制文件中的路径。本 fork 已修改应用 ID：上游 [lycstar/flit](https://github.com/lycstar/flit) 配套仓库的二进制按旧前缀编译，在应用内安装开发环境需自行按新前缀重建配套工具链。

| 配套仓库 | 职责 |
| --- | --- |
| [flit-termux-packages](https://github.com/lycstar/flit-termux-packages) | Flit bootstrap 与 APT 软件包 |
| [llvm-custom](https://github.com/lycstar/llvm-custom) | Android bionic LLVM 宿主工具 |
| [android-sdk-custom](https://github.com/lycstar/android-sdk-custom) | Android SDK 宿主工具 |
| [android-ndk-custom](https://github.com/lycstar/android-ndk-custom) | 面向 Android 宿主的 Android NDK |
| [cmake-custom](https://github.com/lycstar/cmake-custom) | 面向 Android ARM64 宿主的 CMake 与 Ninja |
| [flutter-sdk-custom](https://github.com/lycstar/flutter-sdk-custom) | Flutter 与 Dart SDK 分发 |

工具链构建脚本由这些仓库维护。本仓库维护应用安装脚本和版本选择规则。版本目录与验证要求见[运行环境配置](docs/runtime-environment.md)。

工具链 Tag 统一使用组件前缀与完整版本：`sdk-36.0.0`（Build Tools）、`ndk-r27d`、`llvm-r27d`、`cmake-3.22.1`、`flutter-3.47.8`。NDK 的 r27 与 r27d 属于不同修订版，独立发布。SDK 使用 `sdk-<Build Tools版本>` 发布，整包只带对应的一个 Platform；`platform-<API>` 提供独立平台分包。当前 Build Tools 提供 **34.0.0、35.0.0、36.0.0、37.0.0**，App 默认初始化 36.0.0；NDK 另有 **r25b、r26b、r27** 历史版本，CMake 提供 **3.22.1 与 3.31.6**。版本构建发布成功后才会出现在版本目录中，可选范围以目录为准。

应用的 APK 构建和 Android 设备运行由独立 `AndroidBuildWrapper` 检查缺失组件，确认后安装并最多重试一次；覆盖 Platform、Build Tools、NDK、CMake/Ninja 和设备运行所需的 Platform Tools。宿主工具保持 ARM64 适配包，AGP 通用自动下载保持关闭。

## 目录结构

| 目录 | 职责 |
| --- | --- |
| `lib/main.dart`、`lib/app.dart` | 组合应用服务并配置应用 |
| `lib/core/` | Provider 作用域、主题与共享布局 |
| `lib/features/` | 项目、工作区、编辑器、终端、环境、设备、Git 与设置 |
| `lib/services/` | 无状态的进程与文件边界、系统集成 |
| `plugins/` | 五个职责明确的 Android 原生插件 |
| `assets/` | 安装脚本、图标与字体 |
| `test/` | 控制器、组件、协议与安装脚本测试 |
| `docs/` | 架构、运行环境配置与交互规则 |
| `third_party/` | 随仓库维护的第三方源码及其许可证 |

修改共享流程前，请阅读[架构说明](docs/architecture.md)、[会话所有权](docs/session-model.md)、[设备连接](docs/device-connection.md)及[贡献指南](CONTRIBUTING.md)。

## 使用限制

- Android target SDK 固定为 28，以便从应用私有目录执行开发工具；应用通过侧载分发。
- 设备端构建使用 ARM64 宿主工具，禁止 AGP 自动下载 SDK/NDK/CMake；构建前须安装项目要求的版本。工具链按版本共存，更改前须关闭活动项目。
- 必须完成整个工具链安装，首次下载工具及依赖需要网络。项目缓存和构建产物还会占用额外存储空间。
- 同一时间保留一个活动项目。返回项目列表会保留任务；关闭或切换项目会保存文档并停止所属进程。
- Android 进程被终止后，不会恢复终端进程或尚未落盘的内存会话。前台服务有助于维持活动任务，但无法保证进程持续存活。
- 自动测试与 APK 编译无法证明每个工具链版本的设备兼容性。发布前需在真实 arm64 设备上验证环境安装、构建、应用安装及热重载。

## 致谢与许可证

Flit 使用 [GNU GPL v3.0](LICENSE) 许可证。第三方代码、字体和下载工具保留各自的许可证，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

项目基于 [Flutter](https://github.com/flutter/flutter)、[Termux packages](https://github.com/termux/termux-packages) 和 xterm.dart。工具链工作参考了 [mumumusuc/termux-flutter](https://github.com/mumumusuc/termux-flutter)、[HomuHomu833](https://github.com/HomuHomu833)、[lzhiyong/android-sdk-tools](https://github.com/lzhiyong/android-sdk-tools) 及 [Android Code Studio](https://github.com/AndroidCSOfficial/android-code-studio)。
