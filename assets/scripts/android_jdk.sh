#!/data/data/com.seek888.flit/files/usr/bin/bash
# 子任务 2-1: OpenJDK 17(自家 APT 源; 软件源只在安装动作中配置)。
# 中断与重试: apt 更新/安装被打断会留下 half-configured 包 → apt_repair 先补;
# 装了一半的 java 可能存在但不可运行 → 判据是"能出版本", 不行就当未装重装。
. "$(dirname "$0")/lib.sh"
init_stage android_jdk

probe() {
  if [ ! -x "$JAVA_HOME/bin/java" ]; then
    st "$STAGE" PENDING
    return 0
  fi
  _f="$TMPDIR/jdk-probe.$$"
  mkdir -p "$TMPDIR"
  if timeout 5 "$JAVA_HOME/bin/java" -version 2>&1 | tee "$_f" >/dev/null; then
    st "$STAGE" DONE
    echo "__VER__$STAGE:$(awk -F'"' '/version/ { print $2; exit }' "$_f")"
  else
    st "$STAGE" FAILED
    bad "[jdk] Java 存在但无法运行，重试将重新安装"
  fi
  rm -f "$_f"
}

install() {
  if [ -x "$JAVA_HOME/bin/java" ] && timeout 10 "$JAVA_HOME/bin/java" -version >/dev/null 2>&1; then
    ok "[jdk] 已安装，跳过"
  else
    # java 文件在但起不来 = 上次装到一半: 包状态可能已是 ii, 不加 --reinstall apt 会说
    # "已是最新"什么都不做, 重试就死循环
    _flags=""
    [ -x "$JAVA_HOME/bin/java" ] && _flags="--reinstall" &&
      warn "[jdk] 现有 Java 无法运行，重新安装"
    info "[jdk] 正在安装 OpenJDK 17…"
    configure_apt
    apt_repair
    apt-get --error-on=any update ||
      die "[jdk] ✗ 软件源索引更新失败，请查看上方 HTTP、证书或连接错误"
    # shellcheck disable=SC2086
    apt-get install -y --no-install-recommends $_flags openjdk-17 ||
      die "[jdk] ✗ OpenJDK 安装失败，请查看上方 APT 的依赖、下载或配置错误"
  fi
  [ -x "$JAVA_HOME/bin/java" ] || die "[jdk] ✗ 安装后仍缺少 $JAVA_HOME/bin/java"
  mkdir -p "$TMPDIR"
  _f="$TMPDIR/jdk-version.$$"
  timeout 10 "$JAVA_HOME/bin/java" -version 2>&1 | tee "$_f" ||
    die "[jdk] ✗ Java 无法运行，请查看上方动态库或运行时错误"
  echo "__VER__$STAGE:$(awk -F'"' '/version/ { print $2; exit }' "$_f")"
  rm -f "$_f"
}

stage_main "$@"
