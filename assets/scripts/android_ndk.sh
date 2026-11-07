#!/data/data/com.seek888.flit/files/usr/bin/bash
# Pkg.Revision 是安装目录名；SDK 通过软链接发现全部 ARM64 版本。
. "$(dirname "$0")/lib.sh"
init_stage android_ndk
NDK_DIR="$FLIT_TOOLCHAINS/ndk/$NDK_VERSION"

version() { sed -n 's/^Pkg\.Revision[[:space:]]*=[[:space:]]*//p' "$1/source.properties" | head -1 | tr -d ' \r'; }
complete() {
  installed_ok "$1" && component_usable ndk "$1" "$(basename "$1")"
}
probe() {
  if complete "$NDK_DIR" && [ "$(readlink "$ANDROID_HOME/ndk")" = ../ndk ]; then
    st "$STAGE" DONE
    echo "__VER__$STAGE:$(version "$NDK_DIR")"
  else
    st "$STAGE" PENDING
  fi
}
install() {
  link_android_tools
  if [ "${1:-}" != --release ] && complete "$NDK_DIR"; then
    ok '[ndk] 已安装，跳过'
    return
  fi
  if [ "${1:-}" = --release ]; then
    for dir in "$FLIT_TOOLCHAINS"/ndk/*; do
      if installed_ok "$dir" "$NDK_SHA256" && complete "$dir" &&
         { [ -z "${NDK_REQUIRED_REVISION:-}" ] || [ "$(version "$dir")" = "$NDK_REQUIRED_REVISION" ]; }; then
        ok "[ndk] $(basename "$dir") 已安装，跳过下载与解压"
        return
      fi
    done
  fi
  # 目录版本以包内 source.properties 为准，而不是 r28c 等发行标签。
  T=$(archive_path "$NDK_SHA256")
  dl "$NDK_SHA256" "$T" "${NDK_URLS[@]}"
  _stage="$FLIT_TOOLCHAINS/.staging/ndk"
  rm -rf "$_stage"
  mkdir -p "$_stage"
  info "[ndk] 解压（$(du -m "$T" | cut -f1) MB）…"
  tar -xJvf "$T" -C "$_stage" --strip-components=1 \
    --exclude='*/shader-tools/linux-x86_64*' \
    --exclude='*/toolchains/llvm/prebuilt/linux-x86_64*' || die '[ndk] 解压失败'
  [ -f "$_stage/source.properties" ] || die '[ndk] 缺少 source.properties'
  _revision=$(version "$_stage")
  [[ "$_revision" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '[ndk] 无效的 Pkg.Revision'
  [ "${1:-}" = --release ] || [ "$_revision" = "$NDK_VERSION" ] || die '[ndk] 默认包版本与配置不一致'
  # 自动修复必须满足项目的完整版本，r 标签相同也不能发布不匹配的包。
  [ -z "${NDK_REQUIRED_REVISION:-}" ] || [ "$_revision" = "$NDK_REQUIRED_REVISION" ] ||
    die "[ndk] 项目需要 ${NDK_REQUIRED_REVISION}，产物实际为 ${_revision}；未安装"
  info '[ndk] 检查 LLVM Clang…'
  timeout 10 "$_stage/toolchains/llvm/prebuilt/linux-arm64/bin/clang" --version || die '[ndk] LLVM Clang 无法执行'
  mkdir -p "$_stage/shader-tools" "$_stage/toolchains/llvm/prebuilt"
  ln -sfn linux-arm64 "$_stage/shader-tools/linux-x86_64"
  ln -sfn linux-arm64 "$_stage/toolchains/llvm/prebuilt/linux-x86_64"
  NDK_DIR="$FLIT_TOOLCHAINS/ndk/$_revision"
  if complete "$NDK_DIR"; then
    ok "[ndk] $_revision 已安装，保留现有版本"
    rm -rf "$_stage"
  else
    mark_installed "$_stage" "$NDK_SHA256"
    publish_directory "$_stage" "$NDK_DIR"
  fi
  rm -f "$T"
  echo "__VER__$STAGE:$_revision"
  ok "[ndk] ✓ $NDK_DIR"
}

stage_main "$@"
