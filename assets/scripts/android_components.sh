#!/data/data/com.seek888.flit/files/usr/bin/bash
# 只读探测：协议输出给 AndroidBuildWrapper，不下载、不接受许可证、不改项目。
. "$(dirname "$0")/lib.sh"
missing() { printf '__MISSING__%s:%s\n' "$1" "${2:-}"; }
check_component() {
  local component=$1 version=${2:-} root
  case "$component" in
    platforms) root="$ANDROID_HOME/platforms/android-$version" ;;
    build-tools|ndk|cmake) root="$ANDROID_HOME/$component/$version" ;;
    platform-tools) root="$ANDROID_HOME/platform-tools" ;;
    cmdline-tools) root="$ANDROID_HOME/cmdline-tools/latest" ;;
    *) die "未知 Android 组件：$component" ;;
  esac
  component_usable "$component" "$root" "$version" || missing "$component" "$version"
}
for requirement in "$@"; do
  case "$requirement" in
    --baseline)
      tool_works "$JAVA_HOME/bin/java" -version || die 'Java 无法运行，请在开发环境页修复 JDK'
      # 基础环境需要一套可用 AAPT2；不强制项目下载默认 Platform/NDK/CMake。
      found=false
      for tool in "$ANDROID_HOME"/build-tools/*/aapt2; do
        if tool_works "$tool" version; then found=true; break; fi
      done
      "$found" || missing build-tools "${SDK_VERSION:-36.0.0}"
      ;;
    --device) check_component platform-tools ;;
    *)
      [[ "$requirement" =~ ^(platforms|build-tools|ndk|cmake|platform-tools|cmdline-tools):[0-9.]*$ ]] || die '无效的组件检查参数'
      check_component "${requirement%%:*}" "${requirement#*:}"
      ;;
  esac
done
# 缺失由标记表达；非零只用于探测自身失败，不能把检查失败当作环境正常。
exit 0
