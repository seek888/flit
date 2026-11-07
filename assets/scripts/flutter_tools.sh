#!/data/data/com.seek888.flit/files/usr/bin/bash
# 子任务 3-2: Git 与 gh(GitHub CLI)。Flutter 工具强制依赖 Git; gh 提供 Device Flow
# 登录与 git 凭据助手, 私库克隆/推送靠它非交互完成。
# 中断与重试: 缺哪个装哪个(git 装好、gh 断网失败时重试只装 gh);
# apt 被打断留下的 half-configured 包由 apt_repair 先补。
. "$(dirname "$0")/lib.sh"
init_stage flutter_tools

_missing_tools() {
  _m=""
  command -v git >/dev/null 2>&1 || _m="$_m git"
  command -v gh >/dev/null 2>&1 || _m="$_m gh"
  printf '%s' "$_m"
}

version() {
  echo "git $(git --version 2>/dev/null | awk '{print $3}' | head -1) · gh $(gh --version 2>/dev/null | awk 'NR==1{print $3}')"
}

probe() {
  _m=$(_missing_tools)
  if [ -z "$_m" ]; then
    st "$STAGE" DONE
    echo "__VER__$STAGE:$(version)"
  else
    st "$STAGE" PENDING
    info "[tools] 缺少:$_m"
  fi
}

install() {
  _m=$(_missing_tools)
  if [ -z "$_m" ]; then
    ok "[tools] Git 与 gh 已安装，跳过"
    return 0
  fi
  info "[tools] 正在安装:${_m}…"
  configure_apt
  apt_repair
  apt-get --error-on=any update ||
    die "[tools] ✗ 软件源索引更新失败，请查看上方 APT 输出"
  # shellcheck disable=SC2086
  apt-get install -y --no-install-recommends $_m ||
    die "[tools] ✗ 安装失败，请查看 APT 输出中的具体错误"
  _m=$(_missing_tools)
  [ -z "$_m" ] || die "[tools] ✗ 安装后仍缺少:$_m"
  echo "__VER__$STAGE:$(version)"
  ok "[tools] ✓ git · gh"
}

stage_main "$@"
