<p align="center">
  <img src="assets/branding/logo.png" alt="Flit" width="112" height="112" />
  <a href="https://github.com/seek888/flit/actions/workflows/windows-build.yml"><img src="https://github.com/seek888/flit/actions/workflows/windows-build.yml/badge.svg" alt="Windows Build" /></a>
</p>

<h1 align="center">Flit</h1>

<p align="center">A Flutter development workspace for Android and Windows desktop.</p>

<p align="center">
  <a href="https://github.com/lycstar/flit/releases"><img src="https://img.shields.io/github/v/release/lycstar/flit?include_prereleases&amp;label=preview&amp;color=39BFEA" alt="Latest preview" /></a>
  <a href="https://github.com/lycstar/flit/actions/workflows/android-release.yml"><img src="https://github.com/lycstar/flit/actions/workflows/android-release.yml/badge.svg" alt="Android Release" /></a>
  <a href="https://github.com/lycstar/flit/stargazers"><img src="https://img.shields.io/github/stars/lycstar/flit?style=flat&amp;color=39BFEA" alt="GitHub stars" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-279CF0" alt="License: GPL-3.0" /></a>
  <img src="https://img.shields.io/badge/Android-7.0%2B-51D7EB" alt="Android 7.0 and above" />
</p>

<p align="center">
  <a href="https://github.com/lycstar/flit/releases">Download preview</a> ·
  <a href="docs/architecture.md">Architecture</a> ·
  <a href="https://github.com/lycstar/flit/issues">Report an issue</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

English · [简体中文](README.zh-CN.md)

Edit Dart code, build applications on the device, run them over wireless ADB, or preview Flutter Web in the editor.

Application ID: `com.seek888.flit` · Android 7.0+ · arm64-v8a

## Features

- Create, clone and open projects stored in the application’s project directory.
- Edit multiple files with syntax highlighting, completion, diagnostics and signature help from the official Dart analysis server.
- Run shell commands and inspect streaming build, setup and Git output in the integrated terminal.
- Build APKs, connect Android devices over wireless ADB, and use Flutter hot reload and hot restart.
- Preview Flutter Web inside the workspace; use code/preview switching on phones and a split view on wide screens.
- Stage, commit, manage branches, pull and push with Git; sign in to GitHub through its device authorization flow.
- Share files and access projects from the system Files app through Android’s Storage Access Framework.
- Use English or Simplified Chinese, or follow the system language from Settings.

## Start using Flit

1. Download an APK from [Releases](https://github.com/lycstar/flit/releases) and install it on an arm64 Android device.
2. Complete **Development environment** setup. All required components must be ready before creating or building projects. Installation output remains visible in the terminal.

   ![neofetch in the Flit terminal, showing the Android environment](docs/juejin/assets/flit-neofetch.png)

3. Create or clone a project, or open a directory from the project list.
4. Select Web preview or connect an Android device. Run, inspect the output, and use reload/restart while editing.

| Flutter Web debugging | Flutter Android debugging |
| --- | --- |
| <img src="docs/juejin/assets/flit-web-debug.jpg" width="340" alt="Flutter Web app running in Flit, Debug badge on the page, Dart VM Service in the terminal below" /> | <img src="docs/juejin/assets/flit-hot-reload.gif" width="340" alt="Editing code and hot reloading in Flit" /> |

Wireless pairing on the same device requires Android 11+ and wireless debugging enabled in Developer options. Manual host/port connection is available for an already configured ADB endpoint. Pairing history is not proof of a current connection: Flit checks the device state reported by ADB.

Projects live in the app’s private `files/home/projects` directory. **Uninstalling Flit or clearing its data deletes those projects.** Back them up with Git or copy them through **Files → Flit Projects**. GitHub authentication is optional; local development does not require an account.

## Windows desktop

This fork also runs as a **Windows desktop** workspace. In Flit on Windows you can create
or clone a Flutter project, edit it with analysis-server support, run Flutter/Dart/Git/ADB
commands from the integrated terminal, manage Git and push to GitHub, and build **Android
APKs** and **Web artifacts**.

Download `FlitSetup-<version>-x64.exe` (per-user installer, no administrator rights) or the
portable `flit-windows-x64-*.zip` from Releases. The desktop toolchain — Temurin JDK 17,
Android SDK, Flutter and MinGit — is installed into `%LOCALAPPDATA%\FlitDesk` on first run
and does not modify the system PATH or registry. GitHub sign-in uses a personal access token
that is kept in an app-private git configuration, so private clones and pushes work
non-interactively.

See [docs/windows-desktop.md](docs/windows-desktop.md) for installation, environment setup,
GitHub PAT sign-in, build commands and known limitations.

## How it works

The key to running the Flutter build chain on a phone is telling apart what can be reused as-is and what must be recompiled: Gradle, `d8`, `apksigner` and flutter_tools are JVM/Dart VM bytecode, and `android.jar` plus engine artifacts are pure data — those are portable by nature. `aapt2`, `aidl`, `zipalign`, the Dart VM, `gen_snapshot` and clang are native ELF host tools that must execute on the device; upstream only ships x86_64 glibc builds, so they are cross-compiled against bionic. The port happens in three layers: a self-built Termux userland (bootstrap and APT packages) provides shell and package management; Android SDK/NDK/CMake host tools are cross-compiled while official data and metadata are kept untouched; Flutter/Dart host tools are cross-compiled and combined with the official Android engine artifacts. Gradle and AGP are reused unchanged, with `android.aapt2FromMavenOverride` pointing at the on-device ARM64 AAPT2 and SDK auto-downloads disabled so AGP cannot pull desktop binaries.

A full write-up (Chinese): [如何在 Android 设备上构建 Flutter 应用：Flit 的工具链移植实践](docs/juejin/article.md).

```mermaid
flowchart LR
    UI[Flutter workspace] --> State[Provider scopes and controllers]
    State --> PTY[PTY console sessions]
    State --> LSP[Dart language service transport]
    PTY --> Tools[On-device Flutter / Dart / Git / ADB]
    LSP --> Analyzer[Dart analysis server]
    Tools --> Build[Gradle / Android SDK / NDK / JDK]
    Build --> APK[APK]
    APK --> Device[ADB installation and launch]
    Tools --> Server[Flutter Web development server]
    Server --> Preview[Embedded WebView]
```

The APK contains the editor, native bridges and setup scripts. Setup downloads the development environment separately: bootstrap userland, OpenJDK, Android SDK/NDK and a Flutter SDK built for **Android bionic aarch64**. Desktop Linux tools cannot replace these executables.

### Build chain components on the device

| Component | Role in the build | How it is provided |
| --- | --- | --- |
| Terminal / userland | Shell, package manager and process environment | Termux bootstrap and APT packages rebuilt for Flit's private prefix |
| OpenJDK | Runs Gradle and Java tools | Cross-compiled from the official Termux package recipe, installed via APT |
| Gradle / AGP | Coordinates the Android build | Official Java/JVM distribution, run by OpenJDK |
| Android SDK | Platform, Build Tools and packaging tools | Host tools cross-compiled, platform data reused |
| NDK / CMake / Ninja | Compiles native plugins | LLVM and CMake/Ninja cross-compiled, then assembled into the NDK |
| Flutter SDK | Compiles Dart, provides analysis and run tools | Host tools cross-compiled, Android engine artifacts reused |
| Git, GitHub CLI and other tools | Required by Flutter and in-app features | Cross-compiled from the official Termux package recipe, installed via APT |

Once setup completes, `flutter doctor -v` recognizes Flutter, the Android toolchain and OpenJDK on the phone:

| Components | flutter doctor -v |
| --- | --- |
| <img src="docs/juejin/assets/flit-environment-ready.jpg" width="340" alt="Flit development environment page, environment ready" /> | <img src="docs/juejin/assets/flit-flutter-doctor.jpg" width="340" alt="flutter doctor -v in the Flit terminal, Flutter 3.47.8 and the Android toolchain pass" /> |

## Build from source

Use Flutter **3.47.8**, JDK **17**, Android SDK and NDK **28.2.13676358**. Gradle Wrapper is included. `flutter pub get` resolves the local native plugins as well as hosted dependencies.

```sh
flutter pub get
flutter analyze
flutter test
python3 -m unittest discover -s test -p '*test.py'
flutter build apk --debug --target-platform android-arm64
```

The release workflow runs manually. Configure `KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD` as repository Secrets for signed releases. Local signing uses an ignored `android/key.properties` file; without release signing configuration, local builds use a debug key.

## Runtime distributions

The application keeps only repository and default-version rules; installation resolves download assets and SHA-256 digests from GitHub Releases by tag. No download manifest is bundled. Bootstrap and APT packages must be compiled for `/data/data/com.seek888.flit/files/usr`. Changing a URL or application ID does not relocate another application’s binaries. This fork changes the application ID: binaries from the upstream [lycstar/flit](https://github.com/lycstar/flit) companion repositories are compiled for the old prefix, so installing the on-device environment requires rebuilding the companion toolchains for the new prefix.

| Companion repository | Responsibility |
| --- | --- |
| [flit-termux-packages](https://github.com/lycstar/flit-termux-packages) | Flit bootstrap and APT packages |
| [llvm-custom](https://github.com/lycstar/llvm-custom) | Android bionic LLVM host tools |
| [android-sdk-custom](https://github.com/lycstar/android-sdk-custom) | Android SDK host tools |
| [android-ndk-custom](https://github.com/lycstar/android-ndk-custom) | Android NDK for Android hosts |
| [cmake-custom](https://github.com/lycstar/cmake-custom) | CMake and Ninja for Android ARM64 hosts |
| [flutter-sdk-custom](https://github.com/lycstar/flutter-sdk-custom) | Flutter and Dart SDK distribution |

Toolchain build recipes belong in those repositories. This repository contains only the application’s installation scripts and version-selection rules. See [runtime configuration](docs/runtime-environment.md) for version catalogs and validation requirements.

Distribution tags use component prefixes and complete versions: `sdk-36.0.0` (Build Tools), `ndk-r27d`, `llvm-r27d`, `cmake-3.22.1` and `flutter-3.47.8`. NDK revisions such as r27 and r27d are separate releases. SDK releases use `sdk-<Build Tools version>` tags and contain one matching Platform; independent Platforms use `platform-<API>` tags. Build Tools **34.0.0, 35.0.0, 36.0.0 and 37.0.0** are available, with 36.0.0 initialized by default; additional NDK (**r25b, r26b, r27**) and CMake (**3.22.1, 3.31.6**) builds exist in the same catalog. Versions appear in the catalog only after their builds publish successfully.

## Structure

| Directory | Responsibility |
| --- | --- |
| `lib/main.dart`, `lib/app.dart` | Compose application services and configure the app |
| `lib/core/` | Provider scope, theme and shared layout |
| `lib/features/` | Projects, workspace, editor, terminal, environment, device, Git and settings |
| `lib/services/` | Stateless process/file boundaries and system integration |
| `plugins/` | Five focused Android native plugins |
| `assets/` | Installation scripts, icons and fonts |
| `test/` | Controller, widget, protocol and installation-script tests |
| `docs/` | Architecture, runtime configuration and interaction rules |
| `third_party/` | Vendored sources and their licenses |

Read [architecture](docs/architecture.md), [session ownership](docs/session-model.md), [device connection](docs/device-connection.md) and [contribution guidelines](CONTRIBUTING.md) before changing shared flows.

## Limitations

- Android target SDK is fixed at 28 because development tools execute from app-private storage; distribution is intended for sideloading.
- On-device builds use ARM64 host tools. AGP auto-downloads of SDK/NDK/CMake are disabled; install the versions required by the project before building. Toolchain versions coexist, and changing them requires closing the active project.
- Complete toolchain setup and network access for initial artifacts/dependencies are required. Project caches and build outputs consume additional storage.
- One project is active at a time. Returning to the project list keeps its tasks alive; closing or switching the project saves documents and stops its processes.
- An Android process kill does not restore terminal processes or unsaved in-memory sessions. A foreground service helps keep active work alive but cannot guarantee survival.
- Automated tests and APK compilation do not establish device compatibility for every toolchain version; validate setup, build, installation and reload on a real arm64 device before releasing.

## Credits and license

Flit is licensed under [GNU GPL v3.0](LICENSE). Third-party code, fonts and downloaded tools retain their respective licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Built with [Flutter](https://github.com/flutter/flutter), [Termux packages](https://github.com/termux/termux-packages) and xterm.dart. Toolchain work draws on [mumumusuc/termux-flutter](https://github.com/mumumusuc/termux-flutter), [HomuHomu833](https://github.com/HomuHomu833), [lzhiyong/android-sdk-tools](https://github.com/lzhiyong/android-sdk-tools) and [Android Code Studio](https://github.com/AndroidCSOfficial/android-code-studio).
