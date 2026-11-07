# 设备端开发环境

本仓库维护安装协议，不重复维护工具链构建配方。产物由 README 中列出的伴生仓库构建与发布。

## 安装顺序

1. 下载 bootstrap，校验 SHA-256，原生安装器按官方包布局部署基础环境。
2. 安装 OpenJDK、Android SDK、NDK、CMake，并配置 Gradle 使用 Android 宿主工具。
3. 安装 Git、GitHub CLI、Flutter SDK，执行预热和最终检测。

所有必要组件就绪才允许正常开发。一个子任务对应一个脚本，`--check` 探测和安装逻辑放在同一个文件，避免页面自行推断工具是否安装。脚本输出通过 PTY 原样展示，控制器只解析阶段标记和版本信息。

## 发行获取

应用仅在 `ToolchainCatalog` 中保留仓库、默认版本和资产命名规则，没有内置下载地址/摘要 JSON。安装时通过 GitHub Releases 的精确 tag 接口取得资产 URL、大小和 SHA-256；缺少有效摘要或 API 请求失败时显示错误，不跳过校验或猜测旧地址。

默认 SDK 为 `sdk-36.0.0/android-sdk.tar.xz`，包含 Build Tools 36.0.0 和 Platform 36。默认 Flutter、NDK、CMake 和 bootstrap 也通过各自固定 tag 查询。固定版本用于保持兼容，不使用 `/latest` 随发布顺序自动升级。

`SetupRunner` 在本地生成 `$HOME/.flit/env.sh`，只注入运行路径、默认版本和按仓库规则拼接的 APT 源。环境探测、打开终端和切换已安装版本不联网；安装地址和摘要通过命令参数传给脚本，不写回一份下载清单。bootstrap 和 APT 软件包必须适配 `/data/data/com.seek888.flit/files/usr`，宿主工具必须适配 Android bionic aarch64。SHA-256 不代表架构兼容。

## 版本目录

版本页按仓库分页获取 GitHub Releases。同一 SDK 仓的各组件共享列表请求，页面失败时可以显示本次会话内的上次成功结果；点击安装会重新查询对应 tag，以当前资产摘要为准。安装和初始化共用脚本。

| 组件 | tag | 资产 |
| --- | --- | --- |
| SDK 整包 | `sdk-<Build Tools版本>` | `android-sdk.tar.xz` |
| Build Tools | `sdk-<版本>` | `build-tools.tar.xz` |
| Platform | `platform-<API>` | `platforms.tar.xz` |
| Platform Tools | `sdk-<版本>` | `platform-tools.tar.xz` |
| Command-line Tools | `sdk-<版本>` | `cmdline-tools.tar.xz` |

Platform 和 Build Tools 独立选择，保留 `36.1`、`37.0` 等官方 API 编号。安装分包无需同时提供其他组件；完整的不同版本可以共存。单独选择 Platform Tools 或 Command-line Tools 时替换其固定目录；整包安装保留已有完整公共工具。额外安装 Build Tools 不改变当前可运行的 AAPT2；首次配置优先选择默认 Build Tools 的 AAPT2。

以下构建参数可覆盖仓库，值为 `owner/repository`：

| Dart define | 组件 |
| --- | --- |
| `FLIT_ANDROID_SDK_REPO` | Android SDK 及全部分包 |
| `FLIT_PACKAGES_REPO` | bootstrap / APT |
| `FLIT_NDK_REPO` | Android NDK |
| `FLIT_CMAKE_REPO` | CMake |
| `FLIT_FLUTTER_SDK_REPO` | Flutter SDK |

以上 GitHub 仓库的 API 请求与资产下载（含 APT 源）默认统一加国内加速前缀 `https://gh-proxy.com/`，可用 `FLIT_GH_PROXY` 覆盖：换代理传其前缀（以 `/` 结尾），直连传空值。镜像仅作传输层，SHA-256 校验仍以 GitHub API 返回的摘要为准。

默认基础环境完成判据包含默认 Build Tools、Platform、Platform Tools 和 Command-line Tools。NDK 使用包内 `Pkg.Revision`，CMake 校验实际执行版本。

组件结构与运行检测由 `component_checks.sh` 共用，安装器先在暂存目录验收，再写成功标记并落位；环境检测、已安装列表和构建前检查使用相同判据。继续初始化前重新读取状态，每个安装阶段后复查，检测异常会保留失败退出码。脚本更新采用原子替换；目录替换中断后保留并恢复旧版本备份。

Flutter 切换前验证 Dart 可运行，当前版本即使使用绝对路径链接也不能直接删除；切换成功后重启当前项目的语言服务。项目任务进行中不能从环境页安装、切换或删除共用工具链；环境正在修改时也不能启动新项目任务。


## 项目命令并行

右上角 Flutter/Dart 命令各自启动临时终端，输出和关闭操作独立于设备/Web 运行会话。已有运行可以保留并另开打包任务；分析（Flutter 使用 `--no-pub`）、doctor 和 pub outdated 可与其他任务并行。多个构建、依赖更新等写入任务之间仍串行，clean 和工具链安装保持独占；这些规则由 RunSessions 统一提供给菜单与执行入口。

独立终端仍共享项目的 build/ 与 .dart_tool/。打包和依赖更新期间，App 暂停热重载及重新启动编译，任务结束后恢复；Flutter/Gradle 自身的锁也可能让命令等待。普通交互终端中手动执行的命令不受 App 的任务协调控制。

## 构建组件检查与补装

`AndroidBuildWrapper` 统一管理应用中的 APK 构建和 Android 设备运行。构建前保存项目，检查 Java、可运行的 AAPT2，以及常用 Gradle 入口文件中明确声明的 compileSdk、buildToolsVersion、ndkVersion 和 CMake version。设备运行额外检查 Platform Tools。变量、Flutter 默认值、插件和多模块动态配置不靠扫描推算，而由真实构建的明确缺包诊断补充。

缺失组件统一弹窗确认后安装，安装输出进入独立控制台，安装后复查 SDK 路径并继续构建。失败诊断支持 Platform、Build Tools、NDK、CMake；AAPT2 和 ADB 的明确不可用错误也可修复。一次构建最多恢复一次。取消、关闭项目/会话、安装失败或启动其他任务后，旧流程不会继续重试。环境页和构建修复共享安装互斥。

地址和 SHA-256 继续从 GitHub Release API 按 tag 获取。NDK 根据完整版本定位候选 r 标签（例如 28.2.13676358 → ndk-r28c），安装器在发布前必须核对包内 Pkg.Revision；不匹配就拒绝安装，不能冒充版本。Platform 优先安装 platform-<API> 分包，只有该 Release 明确返回 404 时才允许通过官方 sdkmanager 下载该 Platform；缺少 cmdline-tools 时一并列入确认。网络错误不会触发回退，其他宿主工具没有官方 x86_64 回退。

`android_components.sh` 只做本地探测；`android_build.sh` 只负责构建前刷新 ARM64 AAPT2 override 与 sdkDownload=false，然后 exec 原命令，保留 flutter run 的热重载输入和停止信号。所有提示、下载编排、诊断与重试策略都在 Dart wrapper，普通终端命令不弹窗或自动重试。未知错误保留原始输出；Java 等基础环境问题引导回开发环境页修复。许可证未接受、自定义工具链路径无效会给出对应提示，不通过重复安装冒充修复；预览版和扩展 API 不会被截成稳定版本下载。

全部 SDK 归入 `$HOME/toolchains`，沿用 Android SDK 标准组件布局：

```text
toolchains/
├── flutter/
│   ├── <版本>/
│   └── current → <当前版本>
├── ndk/<Pkg.Revision>/
├── cmake/<版本>/
└── android-sdk/
    ├── platforms/android-<API>/
    ├── build-tools/<版本>/
    ├── platform-tools/
    ├── cmdline-tools/latest/
    ├── ndk → ../ndk
    └── cmake → ../cmake
```

Flutter 的 `current` 是终端、分析器、构建脚本的统一入口。NDK/CMake 不设置全局“当前版本”，项目声明的版本通过 SDK 内的链接定位；不再注入固定的 `ANDROID_NDK_HOME`。SDK 根目录固定，下载其他 SDK 发行包只补充组件，不改变 NDK/CMake 关系。

开发环境页按组件展示安装状态，进入详情管理本地版本、路径、占用空间、修复和下载。SDK 整包只用于初始化，不作为独立组件重复展示；Platform Tools 与 Command-line Tools 使用共用目录，只提供默认 SDK 的配套包，并在替换前确认。初始化完成后默认折叠阶段详情。支持离线切换 Flutter、删除版本、从发行目录下载。切换和删除前须关闭项目，工作台终端会停止。当前 Flutter 版本须先切换后才能删除。删除 Build Tools 会重新选择可用 AAPT2；全部删除时，环境检查会阻止继续开发。基础 NDK/CMake 仍为初始化必需版本。

远程目录在打开组件详情时首次请求，按应用会话缓存结果（包括空列表和失败），合并并发请求；滚动、页面重建和重新进入页面不会重新请求，显式刷新才重新获取。安装仍按精确 tag 重新解析下载信息。已安装版本从可下载列表排除；NDK 与共用工具通过本地 `.flit-complete` 摘要识别来源，不把 SDK tag 当作工具版本。每次进入环境页重新检测本地目录，以纳入项目构建时补装的组件。已安装目录检测失败时保留上次结果、展示未知状态并禁用写操作，不冒充未安装。

下载以 SHA-256 区分缓存，已校验的归档可在解压失败后复用。先在同一文件系统的暂存目录解压并验证，再写入版本目录。完整的版本目录保持原样；如需替换须主动删除。固定路径的公共工具分包支持显式更新。默认初始化保留已选 Flutter，其他旧版本也不会自动删除。不迁移旧目录布局，使用新布局需重新安装开发环境。Android SDK 的发行包记录只用于判断组件是否已齐备，删除组件后会自动失效。

显式设为空字符串的目录不发出请求；页面会区分未配置、请求失败和无匹配版本。只配置经过兼容性验证的仓库；匿名下载不支持私有资产，不能把个人令牌写进应用。安装目录和资产名模式见 `ToolchainCatalog.components`。

## 发布验证

调整默认版本前核验远程资产、SHA-256、归档结构、NDK `source.properties` 与目录版本、应用前缀和动态库依赖。然后在干净的 arm64 Android 设备上验证初始化、新建/克隆、依赖解析、分析服务、APK 构建、ADB 安装运行、热重载及 Web 预览。

自动测试与本地 APK 编译覆盖应用代码及安装协议，不能替代这些设备端验证。
