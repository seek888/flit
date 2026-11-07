#!/data/data/com.seek888.flit/files/usr/bin/bash
# 网络检测: 三个目标各管一件事
#   Google(generate_204) = 全球出网能力(自动代理开关的直观指示灯)
#   GitHub               = 工具链源直连(git/apt pool 所在)
#   百度                 = 国内基线(Google 挂而百度通 = 网络活着只是出不去)
# 任何 HTTP 应答都算通路存在, 超时/无应答才算不通;
# 结果以 __NET__ 标记输出供 app 解析展示
set -u

C_G='\033[1;32m'; C_R='\033[1;31m'; C_C='\033[36m'; C_0='\033[0m'

probe() {
  local name=$1 url=$2 out code t
  printf "${C_C}%s${C_0}\n" "[网络] ${name}：$url"
  out=$(curl -o /dev/null -sS -m 8 -w '%{http_code}|%{time_total}' "$url")
  code=${out%%|*}
  t=${out##*|}
  if [[ -n "$code" && "$code" != "000" ]]; then
    printf '__NET__%s:%s|%s\n' "$name" "$code" "$t"
    printf "${C_G}✓ $name 响应已收到（HTTP ${code}，${t}s）${C_0}\n"
  else
    printf '__NET__%s:000|%s\n' "$name" "$t"
    printf "${C_R}✗ $name 请求失败（超时或未收到响应）${C_0}\n"
  fi
}

if ! command -v curl >/dev/null 2>&1; then
  printf "${C_R}✗ 未找到 curl，无法执行网络检测${C_0}\n"
  exit 0
fi

printf "${C_C}[网络] 正在检测（每个目标最多等待 8 秒）…${C_0}\n"
probe "Google" "https://www.google.com/generate_204"
probe "GitHub" "https://github.com"
probe "百度" "https://www.baidu.com"
