#!/data/data/com.seek888.flit/files/usr/bin/bash
# Only architecture-independent Platform data may be installed from Google.
. "$(dirname "$0")/lib.sh"
init_stage android_platform
_api=${1:-}
[[ "$_api" =~ ^[0-9]+([.][0-9]+)?$ ]] || die '[platform] 无效的 API 版本'
_platform="$ANDROID_HOME/platforms/android-$_api"
if [ -s "$_platform/android.jar" ] && [ -s "$_platform/source.properties" ]; then
  ok "[platform] Android $_api 已安装"
  exit 0
fi
_manager="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
[ -f "$_manager" ] || die '[platform] 缺少 Command-line Tools，请先在开发环境中安装'
mkdir -p "$TMPDIR"
_answers=$(mktemp "$TMPDIR/flit-sdk-licenses.XXXXXX")
trap 'rm -f "$_answers"' EXIT
for ((i=0; i<100; i++)); do printf 'y\n'; done > "$_answers"
info "[platform] 从 Google 安装 platforms;android-${_api}…"
# An explicit package ID cannot request host Build Tools, NDK or CMake.
bash "$_manager" --sdk_root="$ANDROID_HOME" --install "platforms;android-$_api" < "$_answers" ||
  die "[platform] 官方下载失败，可在开发环境的 Android Platforms 中安装 API $_api 后重试"
[ -s "$_platform/android.jar" ] && [ -s "$_platform/source.properties" ] || die '[platform] 安装后 Platform 文件不完整'
mark_installed "$_platform" "sdkmanager:platforms;android-$_api"
ok "[platform] Android $_api 已安装"
