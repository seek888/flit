#!/data/data/com.seek888.flit/files/usr/bin/bash
# 环境状态检查: 逐个子任务调 --check(各脚本的 probe, 零副作用)。
# "算不算装好"的判据与安装逻辑写在同一个脚本里, 这里不再维护第二套。
set -uo pipefail
umask 022
DIR="$(cd "$(dirname "$0")" && pwd)"
_failed=0
for _id in android_jdk android_sdk android_ndk android_cmake android_gradle \
           flutter_tools flutter_sdk flutter_warmup; do
  if bash "$DIR/$_id.sh" --check; then continue; fi
  _failed=1
  printf '__STAGE__%s:FAILED\n' "$_id"
  printf '\033[1;31m%s\033[0m\n' "[check] ✗ $_id 探测脚本异常退出"
done
exit "$_failed"
