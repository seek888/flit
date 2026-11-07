#!/data/data/com.seek888.flit/files/usr/bin/bash
# ARM64 主机策略独立于项目及 SDK/NDK 版本；由 Gradle init.d 在项目加载前生效。
. "$(dirname "$0")/lib.sh"
init_stage android_gradle

_props="$GRADLE_USER_HOME/gradle.properties"
_guard="$GRADLE_USER_HOME/init.d/flit-toolchain.gradle"

probe() {
  _configured=$(sed -n 's/^android\.aapt2FromMavenOverride=//p' "$_props" 2>/dev/null || true)
  if [ -n "$_configured" ] && tool_works "$_configured" version && [ -s "$_guard" ] && [ -f "$_props" ] &&
     grep -q '^android.builder.sdkDownload=false$' "$_props"; then
    st "$STAGE" DONE
  else
    st "$STAGE" PENDING
  fi
}

install() {
  _aapt2=''
  _existing=$(sed -n 's/^android\.aapt2FromMavenOverride=//p' "$_props" 2>/dev/null || true)
  for _candidate in "$_existing" "$ANDROID_HOME/build-tools/${SDK_VERSION:-}/aapt2"; do
    if [ -x "$_candidate" ] && timeout 10 "$_candidate" version >/dev/null 2>&1; then
      _aapt2=$_candidate
      break
    fi
  done
  while IFS= read -r _bt; do
    [ -z "$_aapt2" ] || break
    _candidate="$ANDROID_HOME/build-tools/$_bt/aapt2"
    if [ -x "$_candidate" ] && timeout 10 "$_candidate" version >/dev/null 2>&1; then
      _aapt2=$_candidate
      break
    fi
    warn "[gradle] 跳过无法执行的 AAPT2：$_candidate"
  done < <(ls -1 "$ANDROID_HOME/build-tools" 2>/dev/null | sort -Vr || true)
  [ -n "$_aapt2" ] ||
    die "[gradle] ✗ 缺少可运行的 ARM64 AAPT2，请先完成 2-2 Android SDK 安装"
  mkdir -p "$GRADLE_USER_HOME/init.d"
  touch "$_props"
  sed -i '/^android\.aapt2FromMavenOverride=/d; /^android\.builder\.sdkDownload=/d' "$_props"
  printf '\nandroid.aapt2FromMavenOverride=%s\nandroid.builder.sdkDownload=false\n' "$_aapt2" >> "$_props"
  if ! grep -q '^org\.gradle\.jvmargs=' "$_props"; then
    printf '\n%s\n' 'org.gradle.jvmargs=-Xmx4g' >> "$_props"
  fi
  cat > "$_guard" <<'GRADLE'
// Flit runs Android ARM64 host tools. Never let AGP install desktop Linux tools.
def properties = new Properties()
new File(gradle.gradleUserHomeDir, 'gradle.properties').withInputStream {
    properties.load(it)
}
def aapt2 = properties.getProperty('android.aapt2FromMavenOverride')
if (!aapt2 || !new File(aapt2).canExecute()) {
    throw new GradleException('Flit: AAPT2 unavailable. Install Android SDK from SDK & Toolchains.')
}
// User-home properties take precedence over project properties. Reject unsafe
// command-line overrides before settings/plugins can resolve any Android tools.
gradle.beforeSettings { settings ->
    if (settings.providers.gradleProperty('android.builder.sdkDownload').orNull != 'false' ||
        settings.providers.gradleProperty('android.aapt2FromMavenOverride').orNull != aapt2) {
        throw new GradleException('Flit: unsafe Android toolchain override. Remove SDK download / AAPT2 overrides from Gradle arguments.')
    }
}
logger.lifecycle('Flit: ARM64 AAPT2; SDK/NDK/CMake auto-download disabled. Install required versions from SDK & Toolchains.')
GRADLE
  info "[gradle] AAPT2 → $_aapt2"
  info '[gradle] 已禁止 AGP 自动下载 SDK / NDK / CMake；缺少版本时请安装对应的 ARM64 工具链'
}

stage_main "$@"
