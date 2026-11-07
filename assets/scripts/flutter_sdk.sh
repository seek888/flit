#!/data/data/com.seek888.flit/files/usr/bin/bash
# Flutter 按版本并存，current 是终端、构建与分析器的统一入口。
. "$(dirname "$0")/lib.sh"
init_stage flutter_sdk
FLUTTER_BASE="$FLIT_TOOLCHAINS/flutter"

probe() {
  if flutter_complete "$FLUTTER_BASE/current"; then
    st "$STAGE" DONE
    echo "__VER__$STAGE:$(basename "$(readlink "$FLUTTER_BASE/current")")"
  else
    st "$STAGE" PENDING
  fi
}

install() {
  if [ "${1:-}" != --release ] && flutter_complete "$FLUTTER_BASE/current"; then
    ok '[flutter] 当前版本已安装，跳过下载与解压'
    return
  fi
  [[ "$FLUTTER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+_-][a-zA-Z0-9._-]+)?$ ]] || die '[flutter] 无效的版本号'
  FLUTTER_DIR="$FLUTTER_BASE/$FLUTTER_VERSION"
  if ! flutter_complete "$FLUTTER_DIR"; then
    T=$(archive_path "$FLUTTER_SHA256")
    dl "$FLUTTER_SHA256" "$T" "${FLUTTER_URLS[@]}"
    _stage="$FLIT_TOOLCHAINS/.staging/flutter"
    rm -rf "$_stage"
    mkdir -p "$_stage"
    info "[flutter] 解压 Flutter ${FLUTTER_VERSION}…"
    tar -xJvf "$T" -C "$_stage" || die '[flutter] 解压失败'
    [ -x "$_stage/flutter/bin/flutter" ] && [ -x "$_stage/flutter/bin/cache/dart-sdk/bin/dart" ] ||
      die '[flutter] 安装包缺少 Flutter 或 Dart 命令'
    { grep -rlI '^#!/usr/bin/env \(ba\)\{0,1\}sh' "$_stage/flutter/bin" || [ "$?" -eq 1 ]; } |
    while IFS= read -r f; do
      info "[flutter] 配置脚本解释器：$f"
      sed -i '1s|^#!/usr/bin/env \(ba\)\{0,1\}sh.*|#!'"$PREFIX"'/bin/bash|' "$f"
    done
    info '[flutter] 检查 Dart…'
    timeout 15 "$_stage/flutter/bin/cache/dart-sdk/bin/dart" --version || die '[flutter] Dart 无法执行，保留当前版本'
    mark_installed "$_stage/flutter" "$FLUTTER_SHA256"
    publish_directory "$_stage/flutter" "$FLUTTER_DIR"
    rm -rf "$_stage"
    rm -f "$T"
  else
    ok "[flutter] $FLUTTER_VERSION 已安装，跳过下载与解压；如需替换，请先删除该版本"
  fi
  select_flutter "$FLUTTER_VERSION"
  echo "__VER__$STAGE:$FLUTTER_VERSION"
  ok "[flutter] 已切换到 $FLUTTER_VERSION"
}

stage_main "$@"
