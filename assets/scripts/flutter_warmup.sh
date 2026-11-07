#!/data/data/com.seek888.flit/files/usr/bin/bash
# 子任务 3-3: 预热——首次 flutter --version 会构建 flutter_tools 快照并拉取
# Dart SDK / 引擎组件(需要网络), 之后的新建/运行才不会卡在"首次初始化"。
# 中断与重试: flutter 自己用 bin/cache 的 stamp 文件管下载完整性, 半截下载下次重拉,
# 这里不额外加标记; 失败只重跑本步, 不会牵连 3-1 重装。
# probe 只看结构不执行 flutter(执行会触发下载 = 副作用)。
. "$(dirname "$0")/lib.sh"
init_stage flutter_warmup

FLUTTER_DIR="$FLIT_TOOLCHAINS/flutter/current"

probe() {
  if flutter_complete "$FLUTTER_DIR" &&
     [ -s "$FLUTTER_DIR/bin/cache/flutter_tools.stamp" ] &&
     [ -s "$FLUTTER_DIR/bin/cache/flutter_tools.snapshot" ]; then
    st "$STAGE" DONE
    if [ -f "$FLUTTER_DIR/version" ]; then echo "__VER__$STAGE:$(cat "$FLUTTER_DIR/version")"; fi
  else
    st "$STAGE" PENDING
  fi
}

install() {
  [ -x "$FLUTTER_DIR/bin/flutter" ] || die "[flutter] ✗ 缺少 Flutter SDK，请先完成 3-1"
  mkdir -p "$TMPDIR"
  cd "$HOME"
  info "[flutter] 正在初始化工具链（首次运行可能下载 Dart SDK 与引擎组件，需要网络）…"
  info "[flutter] \$ flutter --version"
  _f="$TMPDIR/flutter-version.$$"
  # 保留完整输出, 让用户看到每一步下载; 失败不被 tee 吞掉
  "$FLUTTER_DIR/bin/flutter" --version 2>&1 | tee "$_f" ||
    die "[flutter] ✗ 工具链初始化失败，请查看上方运行输出"
  __fv=$(awk '/^Flutter [0-9]/ { print $2; exit }' "$_f")
  rm -f "$_f"
  [ -n "$__fv" ] || die "[flutter] ✗ Flutter 未返回有效版本号"
  echo "__VER__$STAGE:$__fv"
  ok "[flutter] ✓ 工具链就绪 $__fv"
}

stage_main "$@"
