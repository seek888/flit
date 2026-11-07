#!/data/data/com.seek888.flit/files/usr/bin/bash
. "$(dirname "$0")/lib.sh"
init_stage toolchain_manager

validate_path() {
  [[ "$1" =~ ^(flutter|ndk|cmake|android-sdk/build-tools|android-sdk/cmdline-tools)/[0-9]+([.+_-][a-zA-Z0-9]+)*$|^android-sdk/platforms/android-[0-9]+([.][0-9]+)?$|^android-sdk/cmdline-tools/latest$|^android-sdk/platform-tools$ ]] || die '无效的工具链路径'
}

case "${1:-}" in
  --list)
    for dir in "$FLIT_TOOLCHAINS"/flutter/* "$FLIT_TOOLCHAINS"/ndk/* "$FLIT_TOOLCHAINS"/cmake/* \
      "$ANDROID_HOME"/platforms/* "$ANDROID_HOME"/build-tools/* \
      "$ANDROID_HOME"/cmdline-tools/* "$ANDROID_HOME"/platform-tools; do
      [ -d "$dir" ] && [ ! -L "$dir" ] || continue
      _active=0
      if [ "$dir" -ef "$FLIT_TOOLCHAINS/flutter/current" ]; then _active=1; fi
      _complete=0
      if installed_ok "$dir"; then
        case "$dir" in
          */flutter/*) if flutter_complete "$dir"; then _complete=1; fi ;;
          */ndk/*) if component_usable ndk "$dir" "$(basename "$dir")"; then _complete=1; fi ;;
          */cmake/*) if component_usable cmake "$dir" "$(basename "$dir")"; then _complete=1; fi ;;
          */platforms/*) if component_usable platforms "$dir"; then _complete=1; fi ;;
          */build-tools/*) if component_usable build-tools "$dir" "$(basename "$dir")"; then _complete=1; fi ;;
          */cmdline-tools/*) if component_usable cmdline-tools "$dir"; then _complete=1; fi ;;
          */platform-tools) if component_usable platform-tools "$dir"; then _complete=1; fi ;;
        esac
      fi
      _revision=$(sed -n 's/^Pkg\.Revision[[:space:]]*=[[:space:]]*//p' "$dir/source.properties" 2>/dev/null | head -1 | tr -d ' \r' || true)
      _sha=$(cat "$dir/.flit-complete" 2>/dev/null || true)
      printf '__TOOL__%s|%s|%s|%s|%s|%s\n' "${dir#"$FLIT_TOOLCHAINS/"}" "$(du -sk "$dir" | cut -f1)" "$_active" "$_complete" "$_revision" "$_sha"
    done
    ;;
  --select)
    validate_path "flutter/${2:-}"
    select_flutter "$2"
    ok "[flutter] 已切换到 $2"
    ;;
  --delete)
    validate_path "${2:-}"
    _path="$FLIT_TOOLCHAINS/$2"
    [ ! -L "$_path" ] || die '不能删除工具链链接'
    if [ "$_path" -ef "$FLIT_TOOLCHAINS/flutter/current" ]; then
      die '请先切换 Flutter 版本，再删除当前版本'
    fi
    rm -rf "$_path"
    ok "[toolchains] 已删除 $2"
    case "$2" in
      android-sdk/build-tools/*)
        if compgen -G "$ANDROID_HOME/build-tools/*/aapt2" > /dev/null; then
          bash "$(dirname "$0")/android_gradle.sh"
        else
          if [ -f "$GRADLE_USER_HOME/gradle.properties" ]; then
            sed -i '/^android\.aapt2FromMavenOverride=/d' "$GRADLE_USER_HOME/gradle.properties"
          fi
          warn '[gradle] 缺少 Build Tools，请安装后再构建项目'
        fi
        ;;
    esac
    ;;
  *) die '未知的工具链操作' ;;
esac
