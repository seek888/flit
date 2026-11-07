#!/data/data/com.seek888.flit/files/usr/bin/bash
# 固定 SDK 根目录，平台和 Build Tools 按版本累加；NDK/CMake 独立管理。
. "$(dirname "$0")/lib.sh"
init_stage android_sdk
: "${SDK_COMPONENT:=android-sdk}"
: "${SDK_COMPONENT_VERSION:=}"

component_complete() {
  local path=$1
  installed_ok "$ANDROID_HOME/$path" || return 1
  local kind=${path%%/*} expected=${path##*/}
  component_usable "$kind" "$ANDROID_HOME/$path" "$expected"
}
version() {
  ls -1 "$ANDROID_HOME/platforms" 2>/dev/null | sort -V | tail -1 || true
}
probe() {
  local platform=0 tools=0
  [ -n "${SDK_VERSION:-}" ] && [ -n "${SDK_PLATFORM_VERSION:-}" ] ||
    die '[sdk] 缺少当前版本配置，请重新初始化开发环境'
  if component_complete "platforms/android-$SDK_PLATFORM_VERSION"; then platform=1; fi
  if component_complete "build-tools/$SDK_VERSION" && component_complete platform-tools &&
     component_complete cmdline-tools/latest; then tools=1; fi
  if [ "$platform$tools" = 11 ] && [ "$(readlink "$ANDROID_HOME/ndk")" = ../ndk ] &&
     [ "$(readlink "$ANDROID_HOME/cmake")" = ../cmake ]; then
    st "$STAGE" DONE
    echo "__VER__$STAGE:$(version)"
  else
    st "$STAGE" PENDING
  fi
}
install() {
  case "$SDK_COMPONENT" in
    android-sdk|build-tools|platforms|platform-tools|cmdline-tools) ;;
    *) die '[sdk] 未知组件类型' ;;
  esac
  if [ -n "$SDK_COMPONENT_VERSION" ]; then
    [[ "$SDK_COMPONENT_VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]] || die '[sdk] 无效的组件版本'
  fi
  link_android_tools
  _receipt="$ANDROID_HOME/.flit-bundles/$SDK_SHA256"
  if [ -s "$_receipt" ]; then
    _complete=1
    while IFS= read -r _path; do
      component_complete "$_path" || _complete=0
      case "$SDK_COMPONENT" in
        platform-tools|cmdline-tools) installed_ok "$ANDROID_HOME/$_path" "$SDK_SHA256" || _complete=0 ;;
      esac
    done < "$_receipt"
    if [ -n "$SDK_COMPONENT_VERSION" ]; then
      case "$SDK_COMPONENT" in
        android-sdk|build-tools) _expected="build-tools/$SDK_COMPONENT_VERSION" ;;
        platforms) _expected="platforms/android-$SDK_COMPONENT_VERSION" ;;
        platform-tools) _expected=platform-tools ;;
        cmdline-tools) _expected=cmdline-tools/latest ;;
      esac
      grep -Fxq "$_expected" "$_receipt" || _complete=0
    fi
    if [ "$_complete" = 1 ]; then ok '[sdk] 该发行包的组件已安装，跳过'; return; fi
  fi
  T=$(archive_path "$SDK_SHA256")
  dl "$SDK_SHA256" "$T" "${SDK_URLS[@]}"
  _stage="$FLIT_TOOLCHAINS/.staging/android-sdk"
  rm -rf "$_stage"
  mkdir -p "$_stage"
  info "[sdk] 解压（$(du -m "$T" | cut -f1) MB）…"
  tar -xJvf "$T" -C "$_stage" || die '[sdk] 解压失败，已保留当前 SDK'
  _sdk="$_stage/android-sdk"
  [ -d "$_sdk" ] || die '[sdk] 安装包缺少 android-sdk 根目录'
  case "$SDK_COMPONENT" in
    android-sdk)
      [ -d "$_sdk/platforms" ] && [ -d "$_sdk/build-tools" ] || die '[sdk] 整包缺少 platforms 或 build-tools'
      if [ -n "$SDK_COMPONENT_VERSION" ]; then
        [ -d "$_sdk/build-tools/$SDK_COMPONENT_VERSION" ] || die '[sdk] Build Tools 与请求版本不一致'
        [ -d "$_sdk/platform-tools" ] && [ -d "$_sdk/cmdline-tools" ] || die '[sdk] 整包缺少配套工具'
      fi ;;
    build-tools) [ -d "$_sdk/build-tools/$SDK_COMPONENT_VERSION" ] || die '[sdk] 缺少请求的 Build Tools' ;;
    platforms) [ -d "$_sdk/platforms/android-$SDK_COMPONENT_VERSION" ] || die '[sdk] 缺少请求的 Platform' ;;
    *) [ -d "$_sdk/$SDK_COMPONENT" ] || die '[sdk] 缺少请求的工具分包' ;;
  esac
  if [ "$SDK_COMPONENT" != android-sdk ]; then
    for dir in "$_sdk"/*; do
      case "$(basename "$dir")" in "$SDK_COMPONENT"|licenses) ;; *) die '[sdk] 分包含有未请求的组件' ;; esac
    done
  fi
  # 先验证全部组件，再写入正式目录。
  for dir in "$_sdk"/build-tools/*; do
    [ -d "$dir" ] || continue
    if [ "$SDK_COMPONENT" = build-tools ]; then
      [ "$(basename "$dir")" = "$SDK_COMPONENT_VERSION" ] || die '[sdk] 分包含有未请求的 Build Tools 版本'
    fi
    if [ -n "$SDK_COMPONENT_VERSION" ]; then
      _revision=$(sed -n 's/^Pkg\.Revision[[:space:]]*=[[:space:]]*//p' "$dir/source.properties" | head -1 | tr -d ' \r')
      [ "$_revision" = "$(basename "$dir")" ] || die '[sdk] Build Tools 元数据版本不一致'
      [ -x "$dir/aidl" ] && [ -x "$dir/zipalign" ] && [ -f "$dir/d8" ] && [ -f "$dir/apksigner" ] || die '[sdk] Build Tools 不完整'
    fi
    component_usable build-tools "$dir" "$(basename "$dir")" || die '[sdk] Build Tools 不完整或无法运行，保留当前 SDK'
  done
  for dir in "$_sdk"/platforms/*; do
    [ -d "$dir" ] || continue
    if [ "$SDK_COMPONENT" = platforms ]; then
      [ "$(basename "$dir")" = "android-$SDK_COMPONENT_VERSION" ] && [ -s "$dir/source.properties" ] || die '[sdk] Platform 分包版本或元数据不正确'
    fi
    component_usable platforms "$dir" || die '[sdk] Platform 不完整，保留当前 SDK'
  done
  if [ -d "$_sdk/platform-tools" ]; then
    timeout 10 "$_sdk/platform-tools/adb" version || die '[sdk] ADB 无法执行，保留当前 SDK'
  fi
  # 自建归档的扁平 cmdline-tools 规范化为官方的 cmdline-tools/latest。
  if [ -d "$_sdk/cmdline-tools/bin" ]; then
    mv "$_sdk/cmdline-tools" "$_stage/command-line"
    mkdir -p "$_sdk/cmdline-tools"
    mv "$_stage/command-line" "$_sdk/cmdline-tools/latest"
  fi
  for dir in "$_sdk"/cmdline-tools/*; do
    [ ! -d "$dir" ] || component_usable cmdline-tools "$dir" || die '[sdk] Command-line Tools 不完整'
  done
  : > "$_stage/receipt"
  for category in platforms build-tools cmdline-tools; do
    for dir in "$_sdk/$category"/*; do
      [ -d "$dir" ] || continue
      _path="$category/$(basename "$dir")"
      if component_complete "$_path" &&
         { [ "$SDK_COMPONENT" != cmdline-tools ] || installed_ok "$ANDROID_HOME/$_path" "$SDK_SHA256"; }; then
        ok "[sdk] 保留已安装组件 $_path"
      else
        mark_installed "$dir" "$SDK_SHA256"
        publish_directory "$dir" "$ANDROID_HOME/$_path"
      fi
      echo "$_path" >> "$_stage/receipt"
    done
  done
  if [ -d "$_sdk/platform-tools" ]; then
    if ! component_complete platform-tools ||
       { [ "$SDK_COMPONENT" = platform-tools ] && ! installed_ok "$ANDROID_HOME/platform-tools" "$SDK_SHA256"; }; then
      mark_installed "$_sdk/platform-tools" "$SDK_SHA256"
      publish_directory "$_sdk/platform-tools" "$ANDROID_HOME/platform-tools"
    fi
    echo platform-tools >> "$_stage/receipt"
  fi
  # licenses 不参与版本选择；SDK 包中的 ndk/cmake 不得覆盖统一链接。
  if [ -d "$_sdk/licenses" ]; then
    mkdir -p "$ANDROID_HOME/licenses"
    cp -a "$_sdk/licenses/." "$ANDROID_HOME/licenses/"
  fi
  mkdir -p "$(dirname "$_receipt")"
  mv "$_stage/receipt" "$_receipt"
  rm -rf "$_stage"
  rm -f "$T"
  echo "__VER__$STAGE:$(version)"
  ok "[sdk] ✓ $ANDROID_HOME"
}

stage_main "$@"
