#!/data/data/com.seek888.flit/files/usr/bin/bash
# 补包/弹窗/一次重试由 Dart AndroidBuildWrapper 负责。
# shell 只在每次 APK 构建/设备运行前确保 ARM64 AAPT2 与禁止 AGP 自动下载的策略。
. "$(dirname "$0")/lib.sh"
[ "$#" -gt 0 ] || exit 2
bash "$(dirname "$0")/android_gradle.sh" || exit $?
# exec 保持 flutter run 的 PTY 输入和信号，不用 tee 管线影响热重载/停止。
exec "$@"
