#!/data/data/com.seek888.flit/files/usr/bin/bash
# 子任务 2-4: CMake(aarch64 android 静态构建, bin 内置 ninja)。
# AGP 对 externalNativeBuild 默认请求 cmake;3.22.1(flutter_pty 等原生插件);
# 缺包时 AGP 会自动下载官方 Linux x86_64 版(设备上 Exec format error),
# 这里预置正确架构, AGP 检测到已安装即不再下载。
# 中断与重试：下载缓存按摘要区分，暂存解压并验证后才落位，保留其他版本。
. "$(dirname "$0")/lib.sh"
init_stage android_cmake

CMAKE_DIR="$FLIT_TOOLCHAINS/cmake/$CMAKE_VERSION"

version() {
  [ -x "$CMAKE_DIR/bin/cmake" ] &&
    timeout 10 "$CMAKE_DIR/bin/cmake" --version 2>/dev/null | awk 'NR==1 { print $3 }'
}

tools_work() {
  _actual=$(version) && [ "${_actual%-dirty}" = "$CMAKE_VERSION" ] &&
    timeout 10 "$CMAKE_DIR/bin/ninja" --version >/dev/null 2>&1
}

verify_tools() {
  info '[cmake] 检查 CMake…'
  if _output=$(timeout 10 "$CMAKE_DIR/bin/cmake" --version 2>&1); then
    printf '%s\n' "$_output"
  else
    _rc=$?
    printf '%s\n' "$_output"
    die "[cmake] ✗ CMake 无法执行（退出码 $_rc），请查看上方错误"
  fi
  _actual=$(printf '%s\n' "$_output" | awk 'NR==1 { print $3 }')
  # CMake 为经过 Android 移植补丁修改的源码自动追加 -dirty。
  # 仅移除此构建标记；其他版本及 rc 等后缀仍不得冒充要求的正式版本。
  [ "${_actual%-dirty}" = "$CMAKE_VERSION" ] ||
    die "[cmake] ✗ CMake 版本不匹配：需要 ${CMAKE_VERSION}，实际 $_actual"
  info '[cmake] 检查 Ninja…'
  if _output=$(timeout 10 "$CMAKE_DIR/bin/ninja" --version 2>&1); then
    printf '%s\n' "$_output"
  else
    _rc=$?
    printf '%s\n' "$_output"
    die "[cmake] ✗ Ninja 无法执行（退出码 $_rc），请查看上方错误"
  fi
}

probe() {
  if installed_ok "$CMAKE_DIR" && component_usable cmake "$CMAKE_DIR" "$CMAKE_VERSION" && [ "$(readlink "$ANDROID_HOME/cmake")" = ../cmake ]; then
    st "$STAGE" DONE
    echo "__VER__$STAGE:$(version)"
  else
    st "$STAGE" PENDING
  fi
}

install() {
  [[ "$CMAKE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '[cmake] ✗ 无效的版本号'
  CMAKE_DIR="$FLIT_TOOLCHAINS/cmake/$CMAKE_VERSION"
  link_android_tools
  if installed_ok "$CMAKE_DIR" && tools_work; then
    printf 'Pkg.Revision=%s\n' "$CMAKE_VERSION" > "$CMAKE_DIR/source.properties"
    ok "[cmake] 已安装，跳过"
    return 0
  fi
  T=$(archive_path "$CMAKE_SHA256")
  dl "$CMAKE_SHA256" "$T" ${CMAKE_URLS[@]+"${CMAKE_URLS[@]}"}

  info "[cmake] 解压（$(du -m "$T" | cut -f1) MB）…"
  _target="$CMAKE_DIR"
  _stage="$FLIT_TOOLCHAINS/.staging/cmake"
  rm -rf "$_stage"
  mkdir -p "$_stage"
  CMAKE_DIR="$_stage/$CMAKE_VERSION"
  tar -xJvf "$T" -C "$_stage" || {
    die "[cmake] ✗ 解压失败，请查看上方 tar 错误"
  }
  [ -x "$CMAKE_DIR/bin/cmake" ] || die "[cmake] ✗ 解压后缺少 cmake"
  [ -x "$CMAKE_DIR/bin/ninja" ] || die "[cmake] ✗ 解压后缺少 ninja"
  verify_tools
  # 自家构建包没有 source.properties, 补一份供 AGP 按 Pkg.Revision 识别
  printf 'Pkg.Revision=%s\n' "$CMAKE_VERSION" > "$CMAKE_DIR/source.properties"

  mark_installed "$CMAKE_DIR" "$CMAKE_SHA256"
  publish_directory "$CMAKE_DIR" "$_target"
  CMAKE_DIR="$_target"
  rm -rf "$_stage"
  rm -f "$T"
  echo "__VER__$STAGE:$(version)"
  ok "[cmake] ✓ $CMAKE_DIR"
}

stage_main "$@"
