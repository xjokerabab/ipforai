#!/bin/sh
# ipforai 终端守门员（分段流式网络与分流检测）
# 官方入口：https://ipforai.cc/sh
#
# 快捷（会直接执行远端脚本，请先确认信任来源）：
#   curl -fsSL https://ipforai.cc/sh | sh
#   curl -fsSL https://ipforai.cc/sh | sh -s -- 8.8.8.8
#   curl -fsSL https://ipforai.cc/sh | sh -s -- -4
#   curl -fsSL https://ipforai.cc/sh | sh -s -- -6
#   curl -fsSL https://ipforai.cc/sh | sh -s -- -y
#   curl -fsSL https://ipforai.cc/sh | sh -s -- -d
#   curl -fsSL https://ipforai.cc/sh | sh -s -- -s
#   curl -fsSL https://ipforai.cc/sh | sh -s -- -j
#
# 建议先审阅再执行（更安全）：
#   curl -fsSL https://ipforai.cc/sh -o /tmp/ipforai-check.sh
#   less /tmp/ipforai-check.sh
#   sh /tmp/ipforai-check.sh
#   sh /tmp/ipforai-check.sh -y
#   sh /tmp/ipforai-check.sh 8.8.8.8
#
# 承诺与边界：
#   - 只读检测：不写本机配置、不安装软件、不需要 API key
#   - 会创建临时目录存放探测结果，进程结束时删除
#   - 分段流式输出：每测完一段立即显示，不卡屏
#   - 出口画像、出口 IP 基础分与网页共用后端 API；脚本不本地改写评分规则
#   - 指定 IP 时只查询该 IP 的画像与出口 IP 基础分，不把本机链路结果当成该 IP 的连通性
#   - 纯 POSIX sh，运行时只依赖 curl；结果描述网络环境，不代表账号结论
#
# 版本号以 SCRIPT_VERSION 为准（/sh 响应头 X-IP-for-AI-Check-Version 同源）。

set -u

API_BASE="${IPFORAI_API:-https://ipforai.cc}"
V4_BASE="${IPFORAI_V4_PROBE:-https://v4-probe.ipforai.cc}"
WEB_BASE="${IPFORAI_WEB:-https://ipforai.cc}"
if [ -n "${IPFORAI_API:-}" ] && [ -z "${IPFORAI_WEB:-}" ]; then
  case "$API_BASE" in
    http://127.0.0.1:* ) WEB_BASE="http://127.0.0.1:33000" ;;
    http://localhost:* ) WEB_BASE="http://localhost:33000" ;;
  esac
fi
NET_TIMEOUT=8
SCRIPT_VERSION="v3.8"
CHECK_STARTED_AT=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '未知')
CHECK_STARTED_EPOCH=$(date +%s 2>/dev/null || echo '')
LOCAL_ZONE=$(date +%Z 2>/dev/null || echo '未知')
LOCAL_UTC_OFFSET=$(date +%z 2>/dev/null || echo '')

# ---------- 参数 ----------

ASSUME_YES=0
DETAIL=0
PRINT_MD=0
SHARE_MODE=auto
OUT_MODE=full
STACK_FORCE=""
TARGET_IP=""
TEST_IP="${IPFORAI_TEST_IP:-}"

for arg in "$@"; do
  case "$arg" in
    -4|--ipv4) STACK_FORCE="-4" ;;
    -6|--ipv6) STACK_FORCE="-6" ;;
    -y|--yes) ASSUME_YES=1 ;;
    -d|--detail) DETAIL=1 ;;
    -m|--markdown) PRINT_MD=1 ;;
    -r|--share) SHARE_MODE=yes ;;
    --no-share) SHARE_MODE=no ;;
    -s|--summary) [ "$OUT_MODE" != json ] && OUT_MODE=summary ;;
    -j|--json) OUT_MODE=json; ASSUME_YES=1 ;;
    -h|--help)
      printf 'ipforai 终端守门员  %s\n' "$SCRIPT_VERSION"
      printf '官方入口：https://ipforai.cc/sh\n\n'
      printf '用法：\n'
      printf '  curl -fsSL https://ipforai.cc/sh | sh -s -- [IP] [-4|-6] [-y] [-d] [-s] [-m] [-j] [-r|--no-share]\n'
      printf '  sh /tmp/ipforai-check.sh [IP] [-4|-6] [-y] [-d] [-s] [-m] [-j]   # 先下载审阅后再执行\n\n'
      printf '参数：\n'
      printf '  IP          仅查询该 IP 的画像与出口 IP 基础分（不含本机链路 / 分流 / 遥测）\n'
      printf '  -4          仅按 IPv4 出口与连通性检测\n'
      printf '  -6          仅按 IPv6 出口与连通性检测\n'
      printf '  -y          跳过确认直接执行\n'
      printf '  -d          展开扩展 AI 工具分流表与 HTTP 状态详情\n'
      printf '  -s          一屏摘要（出口、四家 AI 可达性、基础分、待处理项）\n'
      printf '  -m          额外输出可贴进论坛的 Markdown 体检表\n'
      printf '  -r          生成在线脱敏分享短链（默认非 JSON 模式自动生成）\n'
      printf '  --no-share  本次运行不生成在线分享短链\n'
      printf '  -j          输出 JSON 到 stdout（隐含 -y，无颜色，供脚本集成）\n\n'
      printf '环境变量：\n'
      printf '  IPFORAI_TEST_IP   本地 API 只返回回环地址时使用的测试出口\n'
      printf '  IPFORAI_NO_SHARE  设为 1 时关闭在线短链生成\n\n'
      printf '说明：只读检测；分段流式输出；在线短链仅上传已打码 IP 摘要；结果不代表账号结论。\n'
      exit 0
      ;;
    -*) printf '未知选项：%s\n' "$arg" >&2; exit 2 ;;
    *) TARGET_IP="$arg" ;;
  esac
done

# ---------- 配色 ----------

if [ "$OUT_MODE" != json ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  R=$(printf '\033[0m');   B=$(printf '\033[1m')
  TITLE=$(printf '\033[1;96m'); DIM=$(printf '\033[2m')
  GRN=$(printf '\033[92m'); YEL=$(printf '\033[93m')
  RED=$(printf '\033[91m')
else
  R=''; B=''; TITLE=''; DIM=''; GRN=''; YEL=''; RED=''
fi

# ---------- 工具函数 ----------

json_scope() { printf '%s' "$1" | sed -n "s/.*\"$2\":{\([^}]*\)}.*/\1/p"; }
json_str() { printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"; }
json_num() { printf '%s' "$1" | sed -n "s/.*\"$2\":[[:space:]]*\(-\{0,1\}[0-9][0-9]*\(\.[0-9]*\)\{0,1\}\).*/\1/p"; }

json_list() {
  printf '%s' "$1" | sed -n "s/.*\"$2\":\[\([^]]*\)\].*/\1/p" \
    | tr ',' '\n' | sed -n 's/^"\(.*\)"$/\1/p'
}

extract_products() {
  printf '%s' "$1" \
    | sed -n 's/.*"products":\[\(.*\)\],"summary".*/\1/p' \
    | sed 's/},{/}@{/g' | tr '@' '\n'
}

fetch() { curl -fsS -m "$NET_TIMEOUT" "$1" 2>/dev/null; }

json_esc() {
  { printf '%s' "$1" | LC_ALL=C tr '\r\t\n' '   ' | LC_ALL=C tr -d '\000-\037\177'; printf '\n'; } \
    | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'
}

jstr() {
  if [ -z "$1" ]; then
    printf 'null'
  else
    printf '"%s"' "$(json_esc "$1")"
  fi
}

jnum() {
  case "$1" in
    ''|-) printf 'null' ;;
    -*)
      case "${1#-}" in
        *[!0-9]*) printf 'null' ;;
        *) printf '%s' "$1" ;;
      esac
      ;;
    *[!0-9]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

fmt_int() {
  printf '%s' "$1" | awk '{
    s = $0; out = "";
    while (length(s) > 3) {
      out = "," substr(s, length(s) - 2) out;
      s = substr(s, 1, length(s) - 3);
    }
    printf "%s%s", s, out;
  }'
}

fail_exit() {
  case "$OUT_MODE" in
    full)
      printf '  %s%s%s\n\n' "$YEL" "$1" "$R"
      ;;
    summary)
      printf '  %s%s%s\n\n' "$YEL" "$1" "$R" >&3
      ;;
    json)
      printf '{"tool":"ipforai-check","version":"%s","error":"%s"}\n' \
        "$(json_esc "$SCRIPT_VERSION")" "$(json_esc "$1")" >&3
      ;;
  esac
  exit 1
}

# 需要用户处理的问题统一记到文件，末尾 [07] 汇总（各段多在管道子 shell 里，变量带不出来）
add_advice() { printf '%s\n' "$1" >> "$TMP/advice"; }

is_loopback_ip() {
  case "$1" in
    127.*|::1|0:0:0:0:0:0:0:1) return 0 ;;
    *) return 1 ;;
  esac
}

is_fake_ip() {
  case "$1" in
    198.18.*|198.19.*|fc00:*|fd00:*) return 0 ;;
    *) return 1 ;;
  esac
}

valid_ip() {
  case "$1" in
    *.*) printf '%s' "$1" | awk -F. 'NF != 4 { exit 1 } { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1 }' ;;
    *:*) printf '%s' "$1" | grep -Eq '^[0-9A-Fa-f:]+$' ;;
    *) return 1 ;;
  esac
}

mask_ip_sh() {
  case "$1" in
    '') printf '' ;;
    *•••*) printf '%s' "$1" ;;
    *.*.*.*) printf '%s.•••.•••.%s' "${1%%.*}" "${1##*.}" ;;
    *:*:*)
      printf '%s' "$1" | awk '
        {
          s = $0;
          if (index(s, "::") > 0) {
            split(s, parts, "::");
            n1 = parts[1] ? split(parts[1], h, ":") : 0;
            n2 = parts[2] ? split(parts[2], t, ":") : 0;
            miss = 8 - n1 - n2;
            idx = 0;
            for (i = 1; i <= n1; i++) g[++idx] = h[i];
            for (i = 1; i <= miss; i++) g[++idx] = "0";
            for (i = 1; i <= n2; i++) g[++idx] = t[i];
          } else {
            split(s, g, ":");
          }
          g1 = g[1]; gsub(/^0+/, "", g1); if (g1 == "") g1 = "0";
          g2 = g[2]; gsub(/^0+/, "", g2); if (g2 == "") g2 = "0";
          printf "%s:%s:••••", tolower(g1), tolower(g2);
        }
      '
      ;;
    *) printf '%s' "$1" ;;
  esac
}

# UTF-8 显示宽度补白
PAD=''
set_pad() {
  sp_b=$(printf '%s' "$1" | wc -c | tr -d ' ')
  sp_w=$(printf '%s' "$1" | LC_ALL=C tr -dc '\340-\357' | wc -c | tr -d ' ')
  sp_n=$(( $2 - sp_b + sp_w ))
  PAD=''
  while [ "$sp_n" -gt 0 ]; do PAD="$PAD "; sp_n=$(( sp_n - 1 )); done
}

network_tone() {
  case "$1:$2" in
    datacenter_proxy:*|residential_proxy:*|vpn_proxy:*|tor_exit:*|public_proxy:*|web_proxy:*|privacy_network:*|enterprise_proxy:*|proxy_likely:*) printf '%s' "$RED" ;;
    *:fixed_broadband|*:business_broadband|*:mobile_carrier|*:satellite) printf '%s' "$GRN" ;;
    datacenter_likely:*|network_infrastructure:*|search_engine_crawler:*|ai_crawler:*|*:public_cloud|*:cdn) printf '%s' "$YEL" ;;
    *) printf '%s' "$DIM" ;;
  esac
}

route_tone() {
  case "$1" in
    native_likely) printf '%s' "$GRN" ;;
    anycast_likely|anycast_unverified|geo_mismatch) printf '%s' "$YEL" ;;
    *) printf '%s' "$DIM" ;;
  esac
}

risk_tone() {
  case "$1" in
    clean|low) printf '%s' "$GRN" ;;
    medium) printf '%s' "$YEL" ;;
    high) printf '%s' "$RED" ;;
    *) printf '%s' "$DIM" ;;
  esac
}

ownership_tone() {
  case "$1" in
    dual_isp) printf '%s' "$GRN" ;;
    single_isp_hosting|hosting) printf '%s' "$YEL" ;;
    *) printf '%s' "$DIM" ;;
  esac
}

# 查询本机系统 DNS 解析结果（严格限时，绝不调用无超时的阻塞工具）
resolve_local_dns() {
  rld_host="$1"
  rld_ip=''
  if command -v dscacheutil >/dev/null 2>&1; then
    rld_ip=$(dscacheutil -q host -a name "$rld_host" 2>/dev/null | awk '/^(ip_address|ipv6_address):/{print $2; exit}')
  elif command -v getent >/dev/null 2>&1; then
    rld_ip=$(getent ahosts "$rld_host" 2>/dev/null | awk '{print $1; exit}')
  elif command -v dig >/dev/null 2>&1; then
    rld_ip=$(dig +short +time=2 +tries=1 "$rld_host" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
  fi
  printf '%s' "$rld_ip"
}

# 在终端 (TTY) 上显示动态加载动画，直到后台任务结束；非 TTY 下静默等待
spin_wait() {
  sw_msg="$1"
  shift
  if [ -t 1 ]; then
    sw_i=0
    while :; do
      sw_alive=0
      for sw_pid in "$@"; do
        [ -n "$sw_pid" ] && kill -0 "$sw_pid" 2>/dev/null && { sw_alive=1; break; }
      done
      [ "$sw_alive" -eq 0 ] && break
      case $(( sw_i % 10 )) in
        0) sw_ch='⠋' ;; 1) sw_ch='⠙' ;; 2) sw_ch='⠹' ;; 3) sw_ch='⠸' ;; 4) sw_ch='⠼' ;;
        5) sw_ch='⠴' ;; 6) sw_ch='⠦' ;; 7) sw_ch='⠧' ;; 8) sw_ch='⠇' ;; 9) sw_ch='⠏' ;;
      esac
      printf '\r  %s%s %s...%s' "$DIM" "$sw_ch" "$sw_msg" "$R"
      sw_i=$(( sw_i + 1 ))
      sleep 0.1 2>/dev/null || sleep 1
    done
    printf '\r\033[2K'
  fi
  for sw_pid in "$@"; do
    [ -n "$sw_pid" ] && wait "$sw_pid" 2>/dev/null || true
  done
}

# 识别常见 AI 域名的官方 / 官方接入 CDN 网段（用于区分正常解析与 DNS 污染）
dns_official_tag() {
  dot_host="$1"; dot_ip="$2"
  case "$dot_host" in
    claude.ai|api.anthropic.com)
      case "$dot_ip" in
        160.79.104.*|160.79.105.*|2607:6bc0:*) printf '官方 IP (Anthropic)' ;;
        104.1[6-9].*|104.2[0-9].*|104.3[0-1].*|172.6[4-9].*|172.7[0-1].*|162.15[8-9].*|2606:4700:*|2a06:98c[0-7]:*|2400:cb00:*|2803:f800:*|2405:b500:*|2405:8100:*|2c0f:f248:*) printf '官方接入 (Cloudflare)' ;;
      esac ;;
    chatgpt.com|grok.com)
      case "$dot_ip" in
        104.1[6-9].*|104.2[0-9].*|104.3[0-1].*|172.6[4-9].*|172.7[0-1].*|162.15[8-9].*|2606:4700:*|2a06:98c[0-7]:*|2400:cb00:*|2803:f800:*|2405:b500:*|2405:8100:*|2c0f:f248:*) printf '官方接入 (Cloudflare)' ;;
      esac ;;
    gemini.google.com)
      case "$dot_ip" in
        142.25[0-1].*|172.217.*|172.253.*|216.58.*|74.125.*|2404:6800:*|2607:f8b0:*|2a00:1450:*|2800:3f0:*) printf '官方接入 (Google)' ;;
      esac ;;
    api.statsig.com)
      case "$dot_ip" in
        34.*|35.*|2600:1901:*) printf '官方接入 (Google Cloud)' ;;
        104.1[6-9].*|104.2[0-9].*|104.3[0-1].*|172.6[4-9].*|172.7[0-1].*|162.15[8-9].*|2606:4700:*|2a06:98c[0-7]:*|2400:cb00:*|2803:f800:*|2405:b500:*|2405:8100:*|2c0f:f248:*) printf '官方接入 (Cloudflare)' ;;
      esac ;;
  esac
}

# ---------- 确认 ----------

if [ "$ASSUME_YES" -eq 0 ] && [ -e /dev/tty ] && [ -t 2 ]; then
  printf '%sipforai 终端守门员（只读 · 分段实时输出）%s\n' "$TITLE" "$R"
  if [ -n "$TARGET_IP" ]; then
    printf '%s将查询指定 IP 的公开画像与出口 IP 基础分；不修改本机配置，不需要 API key。%s\n' "$DIM" "$R"
  else
    printf '%s将分段检测：出口画像 → 网页/API 分流与耗时 → 双栈/IPv6 泄漏/DNS → 遥测域名 → TLS/TCP 延迟差 → 出口 IP 基础分 → 处理建议。%s\n' "$DIM" "$R"
    printf '%s不修改本机配置，不需要 API key；临时文件在结束后删除。%s\n' "$DIM" "$R"
  fi
  printf '按 Enter 继续 · Ctrl-C 取消 '
  read -r _ignored < /dev/tty 2>/dev/null || true
  printf '\n'
fi

TMP=$(mktemp -d 2>/dev/null) || { printf '无法创建临时目录\n' >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
trap '[ -t 1 ] && printf "\r\033[2K"; rm -rf "$TMP"; exit 130' INT TERM

if [ "$OUT_MODE" != full ]; then
  [ "$OUT_MODE" = summary ] && printf '  正在检测（约 15–30 秒）…\n'
  exec 3>&1 1>/dev/null
fi

# ---------- 头部立即输出 ----------

OS_NAME=$(uname -s 2>/dev/null || echo unknown)
OS_REL=$(uname -r 2>/dev/null || echo '')
OS_ARCH=$(uname -m 2>/dev/null || echo '')
CURL_VER=$(curl --version 2>/dev/null | head -n 1 | cut -d' ' -f2)
OS_LABEL="$OS_NAME $OS_REL"
DEFAULT_INTERFACE=''

case "$OS_NAME" in
  Darwin)
    MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null || echo '')
    [ -n "$MACOS_VERSION" ] && OS_LABEL="macOS $MACOS_VERSION"
    DEFAULT_INTERFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
    ;;
  Linux)
    LINUX_NAME=$(awk -F= '$1 == "PRETTY_NAME" { gsub(/"/, "", $2); print $2; exit }' /etc/os-release 2>/dev/null)
    [ -n "$LINUX_NAME" ] && OS_LABEL="$LINUX_NAME"
    ;;
esac

PROXY_SET="${https_proxy:-${HTTPS_PROXY:-${all_proxy:-${ALL_PROXY:-}}}}"
NO_PROXY_SET="${no_proxy:-${NO_PROXY:-}}"
CURL_STACK=""
if [ -n "$STACK_FORCE" ] && [ -z "$PROXY_SET" ]; then
  CURL_STACK="$STACK_FORCE"
fi

printf '\n  %sipforai 终端守门员%s  %s%s%s\n' "$TITLE" "$R" "$DIM" "$SCRIPT_VERSION" "$R"
printf '  %s%s%s\n' "$DIM" '────────────────────────────────────────────────────────' "$R"
printf '  %s报告时间%s  %s · %s%s\n' "$DIM" "$R" "$CHECK_STARTED_AT" "$LOCAL_ZONE" "${LOCAL_UTC_OFFSET:+ (UTC$LOCAL_UTC_OFFSET)}"
printf '  %s系统环境%s  %s · %s · curl %s\n' "$DIM" "$R" "$OS_LABEL" "$OS_ARCH" "${CURL_VER:-?}"
if [ -n "$PROXY_SET" ]; then
  printf '  %s代理变量%s  %s已设置 HTTPS_PROXY / ALL_PROXY（已脱敏）%s\n' "$DIM" "$R" "$GRN" "$R"
  [ -n "$STACK_FORCE" ] && printf '  %s协议栈%s    %s代理环境变量模式下 -4/-6 仅作用于本机到代理，出口地址族由代理决定%s\n' "$DIM" "$R" "$YEL" "$R"
else
  printf '  %s代理变量%s  未设置代理环境变量（若开 TUN 透明代理则由系统接管）\n' "$DIM" "$R"
fi
[ "$DETAIL" -eq 1 ] && [ -n "$NO_PROXY_SET" ] && printf '  %sNO_PROXY%s  %s\n' "$DIM" "$R" "$NO_PROXY_SET"

# NO_PROXY 里含 AI 域名（或 *）时，读代理变量的程序访问这些域名也会直连
if [ -n "$PROXY_SET" ] && [ -n "$NO_PROXY_SET" ]; then
  NO_PROXY_HIT=$(printf '%s' "$NO_PROXY_SET" | tr ',' '\n' | tr '[:upper:]' '[:lower:]' | awk '
    function ends(s, t) { return length(s) > length(t) && substr(s, length(s) - length(t) + 1) == t }
    BEGIN { n = split("anthropic.com claude.ai claude.com claudeusercontent.com openai.com chatgpt.com sora.com googleapis.com gemini.google.com aistudio.google.com clients6.google.com deepmind.google notebooklm.google bard.google.com makersuite.google.com accounts.google.com apis.google.com ogs.google.com recaptcha.net x.ai grok.com cursor.com cursor.sh cursorapi.com githubcopilot.com windsurf.com codeium.com statsig.com statsigapi.net oaistatsig.com featuregates.org growthbook.io datadoghq.com sentry.io mixpanel.com hcaptcha.com workos.com auth0.com", d, " ") }
    {
      e = $0; gsub(/[[:space:]]/, "", e); sub(/^\*?\./, "", e);
      if (e == "") next;
      if (e == "*") { print "*"; exit }
      for (i = 1; i <= n; i++) {
        if (e == d[i] || ends(e, "." d[i]) || ends(d[i], "." e)) { print e; next }
      }
    }' | tr '\n' ' ' | sed 's/ $//')
  if [ -n "$NO_PROXY_HIT" ]; then
    printf '  %sNO_PROXY%s  %s! 包含 %s，相关 AI 请求会绕过代理%s\n' "$DIM" "$R" "$RED" "$NO_PROXY_HIT" "$R"
    add_advice "NO_PROXY 包含 $NO_PROXY_HIT → 从 NO_PROXY 中移除 AI 相关域名"
  fi
fi

# API 地址被改写时，请求实际经第三方中转，出口与本报告检测的路径不同
for base_var in ANTHROPIC_BASE_URL OPENAI_BASE_URL GOOGLE_GEMINI_BASE_URL; do
  eval "base_val=\${$base_var:-}"
  [ -z "$base_val" ] && continue
  base_host=$(printf '%s' "$base_val" | sed -e 's|^[A-Za-z][A-Za-z0-9+.-]*://||' -e 's|[/?#].*||' -e 's|.*@||' -e 's|:[0-9]*$||')
  case "$base_host" in
    api.anthropic.com|api.openai.com|generativelanguage.googleapis.com) ;;
    *)
      printf '  %sAPI 地址%s  %s! %s 指向 %s（非官方地址）%s\n' "$DIM" "$R" "$YEL" "$base_var" "$base_host" "$R"
      add_advice "$base_var 指向 $base_host，API 请求经中转 → 确认该服务可信；要直连官方请取消此变量"
      ;;
  esac
done
[ "$DETAIL" -eq 1 ] && [ -n "$DEFAULT_INTERFACE" ] && printf '  %s默认网卡%s  %s\n' "$DIM" "$R" "$DEFAULT_INTERFACE"

# ==============================================================================
# 阶段 1：出口总览与时区（测完立刻输出）
# ==============================================================================

printf '\n  %s[01] 出口总览与时区%s\n' "$TITLE" "$R"

IP4=''; IP6=''; DEFAULT_STACK=''
if [ -z "$TARGET_IP" ]; then
  if [ "$STACK_FORCE" = "-6" ]; then
    ( curl $CURL_STACK -fsS -m "$NET_TIMEOUT" "$API_BASE/api/ip-profile/echo" > "$TMP/echo_main" 2>/dev/null ) & p_em=$!
    spin_wait "正在识别 IPv6 公网出口" "$p_em"
    MAIN_JSON=$(cat "$TMP/echo_main" 2>/dev/null)
    MAIN_IP=$(json_str "$MAIN_JSON" ip)
    MAIN_FAM=$(json_str "$MAIN_JSON" addressFamily)
    if [ "$MAIN_FAM" = "ipv6" ]; then
      IP6="$MAIN_IP"
      DEFAULT_STACK='ipv6'
    elif [ -n "$PROXY_SET" ] && [ -n "$MAIN_IP" ]; then
      IP4="$MAIN_IP"
      DEFAULT_STACK='ipv4'
    else
      DEFAULT_STACK='ipv6'
    fi
  elif [ "$STACK_FORCE" = "-4" ]; then
    ( fetch "$V4_BASE/api/ip-profile/echo" > "$TMP/echo4" 2>/dev/null ) & p_e4=$!
    spin_wait "正在识别 IPv4 公网出口" "$p_e4"
    IP4=$(json_str "$(cat "$TMP/echo4" 2>/dev/null)" ip)
    if [ -z "$IP4" ]; then
      MAIN_JSON=$(curl $CURL_STACK -fsS -m "$NET_TIMEOUT" "$API_BASE/api/ip-profile/echo" 2>/dev/null || echo '')
      MAIN_IP=$(json_str "$MAIN_JSON" ip)
      MAIN_FAM=$(json_str "$MAIN_JSON" addressFamily)
      [ "$MAIN_FAM" = "ipv4" ] && IP4="$MAIN_IP"
    fi
    DEFAULT_STACK='ipv4'
  else
    ( fetch "$V4_BASE/api/ip-profile/echo" > "$TMP/echo4" 2>/dev/null ) & p_e4=$!
    ( fetch "$API_BASE/api/ip-profile/echo" > "$TMP/echo_main" 2>/dev/null ) & p_em=$!
    spin_wait "正在识别公网出口" "$p_e4" "$p_em"

    IP4=$(json_str "$(cat "$TMP/echo4" 2>/dev/null)" ip)
    MAIN_JSON=$(cat "$TMP/echo_main" 2>/dev/null)
    MAIN_IP=$(json_str "$MAIN_JSON" ip)
    MAIN_FAM=$(json_str "$MAIN_JSON" addressFamily)
    DEFAULT_STACK="$MAIN_FAM"

    if [ "$MAIN_FAM" = "ipv6" ]; then
      IP6="$MAIN_IP"
    elif [ -z "$IP4" ]; then
      IP4="$MAIN_IP"
    fi
  fi
fi

if [ -n "$IP4" ] && is_loopback_ip "$IP4"; then IP4=''; fi
if [ -n "$IP6" ] && is_loopback_ip "$IP6"; then IP6=''; fi

if [ -z "$TARGET_IP" ] && [ -z "$IP4" ] && [ -z "$IP6" ]; then
  if [ -n "$TEST_IP" ]; then
    TARGET_IP="$TEST_IP"
  else
    fail_exit '未能识别公网出口（收到回环地址或探测未返回有效 IP）。'
  fi
fi

if [ -n "$TARGET_IP" ]; then
  case "$TARGET_IP" in
    *:*) IP6="$TARGET_IP"; IP4='' ;;
    *)   IP4="$TARGET_IP"; IP6='' ;;
  esac
fi

DUAL_STACK_PROBE=0
if [ -z "$TARGET_IP" ] && [ -z "$PROXY_SET" ] && [ -z "$STACK_FORCE" ] && [ -n "$IP4" ] && [ -n "$IP6" ]; then
  DUAL_STACK_PROBE=1
fi

is_local_exit_ip() {
  [ -n "$1" ] && { [ "$1" = "$IP4" ] || [ "$1" = "$IP6" ]; }
}

p_pv4=''; p_pv6=''; p_stat=''
if [ -n "$IP4" ]; then ( fetch "$API_BASE/api/ip-profile?ip=$IP4" > "$TMP/p_v4" 2>/dev/null ) & p_pv4=$!; fi
if [ -n "$IP6" ]; then ( fetch "$API_BASE/api/ip-profile?ip=$IP6" > "$TMP/p_v6" 2>/dev/null ) & p_pv6=$!; fi
( curl -fsS -m 3 -X POST "$API_BASE/api/page-views/sh" > "$TMP/sh_stats" 2>/dev/null || true ) & p_stat=$!
spin_wait "正在查询出口画像" "$p_pv4" "$p_pv6"

if [ ! -s "$TMP/p_v4" ] && [ ! -s "$TMP/p_v6" ]; then
  fail_exit '未能获取 IP 画像，请稍后重试。'
fi

profile_of() {
  if [ "$1" = "$IP6" ] && [ -s "$TMP/p_v6" ]; then
    cat "$TMP/p_v6"
  elif [ "$1" = "$IP4" ] && [ -s "$TMP/p_v4" ]; then
    cat "$TMP/p_v4"
  fi
}

SYS_TZ=''
if [ -r /etc/timezone ]; then
  SYS_TZ=$(cat /etc/timezone 2>/dev/null)
elif [ -L /etc/localtime ]; then
  SYS_TZ=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
fi
[ -z "$SYS_TZ" ] && SYS_TZ="${TZ:-}"
UTC_OFF=$(date +%z 2>/dev/null)

PRIMARY_IP="${IP4:-$IP6}"
PRIMARY=$(profile_of "$PRIMARY_IP")
PGEO=$(json_scope "$PRIMARY" geo)
IP_TZ=$(json_str "$PGEO" timezone)

print_card() {
  card_fam="$1"; card_ip="$2"
  card_json=$(profile_of "$card_ip")
  [ -z "$card_json" ] && return

  card_geo=$(json_scope "$card_json" geo)
  card_country=$(json_str "$card_geo" countryNameZh)
  [ -z "$card_country" ] && card_country=$(json_str "$card_geo" countryName)
  card_region=$(json_str "$card_geo" regionNameZh)
  card_city=$(json_str "$card_geo" cityNameZh)
  # 有中文省州名时不再拼英文城市名，避免「东京都 Tokyo」这种中英混排
  if [ -z "$card_region" ]; then
    card_region=$(json_str "$card_geo" region)
    [ -z "$card_city" ] && card_city=$(json_str "$card_geo" city)
  fi

  card_asn_o=$(json_scope "$card_json" asn)
  card_asn=$(json_num "$card_asn_o" asn)
  card_asname=$(json_str "$card_asn_o" asName)

  card_type=$(json_str "$(json_scope "$card_json" networkProfile)" ipTypeLabel)
  card_type_key=$(json_str "$(json_scope "$card_json" networkProfile)" ipType)
  card_access_key=$(json_str "$(json_scope "$card_json" accessProfile)" accessType)
  card_access=$(json_str "$(json_scope "$card_json" accessProfile)" accessTypeLabel)
  card_route=$(json_str "$(json_scope "$card_json" routingProfile)" routeTypeLabel)
  card_route_key=$(json_str "$(json_scope "$card_json" routingProfile)" routeType)
  card_dual_key=$(json_str "$card_json" dualIspStatus)
  card_dual=$(json_str "$card_json" dualIspLabel)
  card_subnet_o=$(json_scope "$card_json" subnetEntity)
  card_subnet_name=$(json_str "$card_subnet_o" name)
  card_subnet_prefix=$(json_str "$card_subnet_o" prefix)
  card_risk_o=$(json_scope "$card_json" riskProfile)
  card_risk=$(json_str "$card_risk_o" riskLevelLabel)
  card_risk_key=$(json_str "$card_risk_o" riskLevel)
  [ -z "$card_risk" ] && card_risk=$(json_str "$card_risk_o" proxyTypeLabel)

  card_loc="$card_country"
  [ -n "$card_region" ] && card_loc="$card_loc $card_region"
  case "$card_region" in
    "$card_city"*) ;;
    *) [ -n "$card_city" ] && card_loc="$card_loc $card_city" ;;
  esac

  printf '\n  %s%-5s%s %s%s%s\n' "$DIM" "$card_fam" "$R" "$B" "$card_ip" "$R"
  printf '        %s · AS%s %s\n' "$card_loc" "${card_asn:-?}" "${card_asname:-未知}"
  if [ -n "$card_access" ] && [ "$card_access_key" != "unknown" ]; then
    printf '        网络：%s%s%s · 接入：%s · 路由：%s%s%s · 风险：%s%s%s\n' \
      "$(network_tone "$card_type_key" "$card_access_key")" "$card_type" "$R" \
      "$card_access" \
      "$(route_tone "$card_route_key")" "$card_route" "$R" \
      "$(risk_tone "$card_risk_key")" "${card_risk:-未知}" "$R"
  else
    printf '        网络：%s%s%s · 路由：%s%s%s · 风险：%s%s%s\n' \
      "$(network_tone "$card_type_key" "$card_access_key")" "$card_type" "$R" \
      "$(route_tone "$card_route_key")" "$card_route" "$R" \
      "$(risk_tone "$card_risk_key")" "${card_risk:-未知}" "$R"
  fi
  if [ -n "$card_dual" ]; then
    if [ "$card_dual_key" = "single_isp_hosting" ] && [ -n "$card_subnet_name" ]; then
      printf '        归属：%s%s%s（%s%s）\n' \
        "$(ownership_tone "$card_dual_key")" "$card_dual" "$R" \
        "$card_subnet_name" "${card_subnet_prefix:+ · $card_subnet_prefix}"
    else
      printf '        归属：%s%s%s\n' \
        "$(ownership_tone "$card_dual_key")" "$card_dual" "$R"
    fi
  fi
}

if [ -n "$TARGET_IP" ]; then
  printf '  %s指定 IP 画像%s · 本机时区 %s (UTC%s) · 目标时区 %s\n' "$DIM" "$R" "${SYS_TZ:-未知}" "${UTC_OFF:-?}" "${IP_TZ:-未知}"
else
  if [ -n "$IP4" ] && [ -n "$IP6" ]; then
    if [ "$DEFAULT_STACK" = "ipv6" ]; then
      printf '  %s双栈出口%s（IPv4 + IPv6 · 默认优先 IPv6）' "$DIM" "$R"
    elif [ "$DEFAULT_STACK" = "ipv4" ]; then
      printf '  %s双栈出口%s（IPv4 + IPv6 · 默认优先 IPv4）' "$DIM" "$R"
    else
      printf '  %s双栈出口%s（IPv4 + IPv6）' "$DIM" "$R"
    fi
  elif [ "$CURL_STACK" = "-4" ] && [ -n "$IP4" ]; then
    printf '  %s单栈出口%s（仅 IPv4）' "$DIM" "$R"
  elif [ "$CURL_STACK" = "-6" ] && [ -n "$IP6" ]; then
    printf '  %s单栈出口%s（仅 IPv6）' "$DIM" "$R"
  elif [ -n "$PROXY_SET" ] && [ -n "$STACK_FORCE" ]; then
    printf '  %s单栈出口%s（代理模式，出口地址族由节点决定）' "$DIM" "$R"
  else
    printf '  %s单栈出口%s' "$DIM" "$R"
  fi
  if [ -n "$SYS_TZ" ] && [ -n "$IP_TZ" ]; then
    if [ "$SYS_TZ" = "$IP_TZ" ]; then
      printf ' · %s✓ 时区一致 (%s)%s\n' "$GRN" "$SYS_TZ" "$R"
    else
      printf ' · %s! 时区差异（本机 %s ≠ 出口 %s）%s\n' "$YEL" "$SYS_TZ" "$IP_TZ" "$R"
      add_advice "系统时区 $SYS_TZ 与出口 $IP_TZ 不一致 → 将系统时区改为 $IP_TZ"
    fi
  else
    printf ' · 本机时区 %s (UTC%s)\n' "${SYS_TZ:-未知}" "${UTC_OFF:-?}"
  fi
fi
[ -n "$IP4" ] && print_card IPv4 "$IP4"
[ -n "$IP6" ] && print_card IPv6 "$IP6"

# ---------- 公共清单与探测函数 ----------

core_ai_lines() {
  cat <<'LINES'
claude|Claude|claude.ai|api.anthropic.com|https://api.anthropic.com/v1/messages|405
chatgpt|ChatGPT|chatgpt.com|api.openai.com|https://api.openai.com/v1/models|401
gemini|Gemini|||https://generativelanguage.googleapis.com/v1beta/models|403
grok|Grok|grok.com|api.x.ai|https://api.x.ai/v1/models|401
LINES
}

domestic_probes() {
  cat <<'DOM'
tencent|腾讯系|tencent|
alibaba|阿里系|alibaba|
bytedance|字节系|header|https://perfops.byte-test.com/500b-bench.jpg
DOM
}

telemetry_groups() {
  cat <<'TGRP'
claude|Claude 遥测与鉴权
openai|ChatGPT / OpenAI
google|Gemini / Google
grok|Grok / xAI
coding|AI 编程工具
shared|通用鉴权与验证
TGRP
}

telemetry_targets() {
  cat <<'TELEM'
claude_growthbook|Claude 开关 (GrowthBook)|cdn.growthbook.io|no|/|claude
claude_console|Claude 控制台|platform.claude.com|yes|/cdn-cgi/trace|claude
claude_sandbox|Claude 沙箱资源|claudeusercontent.com|yes|/cdn-cgi/trace|claude
datadog_logs|Claude Code 日志 (Datadog)|http-intake.logs.us5.datadoghq.com|no|/|claude
datadog_browser|Claude 网页遥测 (Datadog)|browser-intake-us5-datadoghq.com|no|/|claude
openai_auth|OpenAI 登录鉴权|auth.openai.com|yes|/cdn-cgi/trace|openai
openai_ab|ChatGPT 遥测 (AB)|ab.chatgpt.com|yes|/cdn-cgi/trace|openai
openai_statsig_events|ChatGPT 埋点 (Statsig)|api.oaistatsig.com|yes|/cdn-cgi/trace|openai
openai_statsig_cdn|ChatGPT 开关 (Statsig)|statsigcdn.openai.com|yes|/cdn-cgi/trace|openai
openai_statsig_api|Statsig 异常上报|statsigapi.net|no|/|openai
openai_static|ChatGPT 静态资源|cdn.oaistatic.com|yes|/cdn-cgi/trace|openai
google_oauth|Google / Gemini 鉴权|oauth2.googleapis.com|no|/|google
google_accounts|Google 账号登录|accounts.google.com|no|/|google
google_clearcut|Google 遥测 (Clearcut)|play.googleapis.com|no|/|google
google_firebase_log|Google 前端日志 (Firebase)|firebaselogging-pa.googleapis.com|no|/|google
google_waa|Google 环境校验 (WAA)|waa-pa.clients6.google.com|no|/|google
gemini_cli|Gemini CLI (Code Assist)|cloudcode-pa.googleapis.com|no|/|google
gemini_app|Gemini App 接口|robinfrontend-pa.googleapis.com|no|/|google
gemini_labs|Google AI Labs 沙箱|aisandbox-pa.googleapis.com|no|/|google
gemini_studio|AI Studio RPC 接口|alkalimakersuite-pa.clients6.google.com|no|/|google
grok_auth|Grok / xAI 登录鉴权|accounts.x.ai|yes|/cdn-cgi/trace|grok
grok_cli_auth|Grok CLI 登录鉴权|auth.x.ai|yes|/cdn-cgi/trace|grok
grok_mixpanel|Grok CLI 埋点 (Mixpanel)|api.mixpanel.com|no|/|grok
cursor_api|Cursor 主接口|api2.cursor.sh|no|/|coding
cursor_tab|Cursor Tab 补全|api3.cursor.sh|yes|/cdn-cgi/trace|coding
cursor_auth|Cursor 登录鉴权|authenticate.cursor.sh|yes|/cdn-cgi/trace|coding
cursor_market|Cursor 扩展市场 API|marketplace.cursorapi.com|yes|/cdn-cgi/trace|coding
copilot_telemetry|GitHub Copilot 遥测|telemetry.individual.githubcopilot.com|no|/|coding
copilot_client_telemetry|Copilot 客户端遥测|copilot-telemetry.githubusercontent.com|no|/|coding
copilot_exp|Copilot 实验开关|default.exp-tas.com|no|/|coding
sentry_ingest|异常上报 (Sentry)|o33249.ingest.us.sentry.io|no|/|shared
auth0_sso|通用登录鉴权 (Auth0)|auth0.com|yes|/cdn-cgi/trace|shared
workos_sso|企业单点登录 (WorkOS)|workos.com|yes|/cdn-cgi/trace|shared
cf_turnstile|人机验证 (Turnstile)|challenges.cloudflare.com|yes|/cdn-cgi/trace|shared
arkose_captcha|人机验证 (Arkose)|client-api.arkoselabs.com|no|/|shared
google_recaptcha|人机验证 (reCAPTCHA)|recaptcha.net|no|/|shared
hcaptcha|人机验证 (hCaptcha)|js.hcaptcha.com|yes|/cdn-cgi/trace|shared
TELEM
}

extra_ai_routes() {
  cat <<'EXTRA'
sora|Sora|cloudflare|sora.com
cursor|Cursor|cloudflare|marketplace.cursorapi.com
copilot|GitHub Copilot|http|api.githubcopilot.com
windsurf|Windsurf|http|server.codeium.com
perplexity|Perplexity|cloudflare|www.perplexity.ai
midjourney|Midjourney|cloudflare|midjourney.com
openrouter|OpenRouter|cloudflare|openrouter.ai
poe|Poe|cloudflare|poe.com
suno|Suno|cloudflare|suno.com
replicate|Replicate|cloudflare|replicate.com
bolt|Bolt|cloudflare|bolt.new
lovable|Lovable|cloudflare|lovable.dev
character_ai|Character AI|cloudflare|character.ai
leonardo|Leonardo AI|cloudflare|leonardo.ai
pi|Pi|cloudflare|pi.ai
phind|Phind|cloudflare|www.phind.com
pixverse|PixVerse|cloudflare|pixverse.ai
synthesia|Synthesia|cloudflare|www.synthesia.io
genspark|Genspark|cloudflare|www.genspark.ai
EXTRA
}

probe_cf_trace() {
  pct_domain="$1"; pct_out="$2"
  pct_res=$(curl $CURL_STACK -sS -m "$NET_TIMEOUT" -o "$pct_out.body" -w '%{http_code}|%{time_total}|%{remote_ip}' "https://$pct_domain/cdn-cgi/trace" 2>/dev/null)
  IFS='|' read -r pct_code pct_time pct_rem <<EOF
$pct_res
EOF
  pct_ip=''; pct_colo=''
  if [ "$pct_code" -ge 200 ] 2>/dev/null && [ "$pct_code" -lt 300 ] 2>/dev/null; then
    pct_ip=$(sed -n 's/^ip=//p' "$pct_out.body" | head -n 1)
    pct_colo=$(sed -n 's/^colo=//p' "$pct_out.body" | head -n 1)
    valid_ip "$pct_ip" || pct_ip=''
  fi
  pct_ms=$(awk -v s="$pct_time" 'BEGIN { if (s ~ /^[0-9]+([.][0-9]+)?$/) printf "%.0fms", s * 1000 }')
  printf '%s|%s|%s|%s|%s\n' "$pct_code" "$pct_ip" "$pct_colo" "$pct_ms" "$pct_rem" > "$pct_out"
}

probe_http_reach() {
  phr_domain="$1"; phr_out="$2"
  phr_res=$(curl $CURL_STACK -s -m "$NET_TIMEOUT" -o /dev/null -w '%{http_code}|%{time_total}|%{remote_ip}' "https://$phr_domain/" 2>/dev/null)
  IFS='|' read -r phr_code phr_time phr_rem <<EOF
$phr_res
EOF
  phr_ms=$(awk -v s="$phr_time" 'BEGIN { if (s ~ /^[0-9]+([.][0-9]+)?$/) printf "%.0fms", s * 1000 }')
  printf '%s|||%s|%s\n' "$phr_code" "$phr_ms" "$phr_rem" > "$phr_out"
}

probe_api_stack() {
  pas_flag="$1"; pas_url="$2"; pas_expect="$3"; pas_out="$4"
  pas_res=$(curl "$pas_flag" -s -m "$NET_TIMEOUT" -o /dev/null -w '%{http_code}|%{time_starttransfer}' "$pas_url" 2>/dev/null)
  IFS='|' read -r pas_code pas_time <<EOF
$pas_res
EOF
  pas_ms=$(awk -v s="$pas_time" 'BEGIN { if (s ~ /^[0-9]+([.][0-9]+)?$/ && s > 0) printf "%.0fms", s * 1000 }')
  if [ "$pas_code" = "$pas_expect" ]; then
    pas_st='ok'
  elif [ "$pas_code" = "000" ] || [ -z "$pas_code" ]; then
    pas_st='fail'
  else
    pas_st='review'
  fi
  printf '%s|%s|%s\n' "$pas_st" "$pas_code" "$pas_ms" > "$pas_out"
}

# 核心服务探测：同时记录 DNS / TCP / TLS / TTFB 四段毫秒耗时
probe_core_line() {
  pcl_id="$1"; pcl_web="$2"; pcl_api_host="$3"; pcl_api_url="$4"; pcl_expect="$5"
  [ -n "$pcl_web" ] && probe_cf_trace "$pcl_web" "$TMP/core_web_$pcl_id" &
  [ -n "$pcl_api_host" ] && probe_cf_trace "$pcl_api_host" "$TMP/core_api_tr_$pcl_id" &
  if [ "$DUAL_STACK_PROBE" -eq 1 ]; then
    probe_api_stack -4 "$pcl_api_url" "$pcl_expect" "$TMP/core_api_v4_$pcl_id" &
    probe_api_stack -6 "$pcl_api_url" "$pcl_expect" "$TMP/core_api_v6_$pcl_id" &
  fi
  (
    pcl_res=$(curl $CURL_STACK -s -m "$NET_TIMEOUT" -o /dev/null \
      -w '%{http_code}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{remote_ip}' \
      "$pcl_api_url" 2>/dev/null)
    IFS='|' read -r pcl_code t_dns t_tcp t_tls t_ttfb pcl_rem <<EOF
$pcl_res
EOF
    # 经代理时 DNS / TCP 由代理完成，本机只能测到「建连 + TLS」整体，单独给一份代理口径
    timing_str=$(awk -v d="$t_dns" -v c="$t_tcp" -v a="$t_tls" -v s="$t_ttfb" 'BEGIN {
      if (s ~ /^[0-9]+([.][0-9]+)?$/ && s > 0) {
        dm = d * 1000;
        cm = (c > d ? (c - d) * 1000 : 0);
        am = (a > c ? (a - c) * 1000 : 0);
        sm = (s > a ? (s - a) * 1000 : 0);
        printf "DNS %.0f · TCP %.0f · TLS %.0f · TTFB %.0fms|%.0fms|经代理建连 %.0f · TTFB %.0fms", dm, cm, am, sm, s * 1000, a * 1000, sm;
      } else {
        printf "||";
      }
    }')
    IFS='|' read -r pcl_breakdown pcl_ms pcl_proxy_bd <<EOF
$timing_str
EOF
    if [ "$pcl_code" = "$pcl_expect" ]; then
      pcl_st='ok'
    elif [ "$pcl_code" = "000" ] || [ -z "$pcl_code" ]; then
      pcl_st='fail'
    else
      pcl_st='review'
    fi
    if is_loopback_ip "$pcl_rem" || is_fake_ip "$pcl_rem"; then pcl_breakdown="$pcl_proxy_bd"; fi
    printf '%s|%s|%s|%s|%s\n' "$pcl_st" "$pcl_code" "$pcl_ms" "$pcl_rem" "$pcl_breakdown" > "$TMP/core_api_$pcl_id"
  ) &
  wait
}

probe_domestic() {
  pd_id="$1"; pd_mode="$2"; pd_target="$3"
  pd_ip=''; pd_time=''; pd_code=''
  case "$pd_mode" in
    header)
      pd_res=$(curl -sS -m "$NET_TIMEOUT" -D "$TMP/dom_$pd_id" -o /dev/null -w '%{http_code}|%{time_total}' "$pd_target" 2>/dev/null)
      IFS='|' read -r pd_code pd_time <<EOF
$pd_res
EOF
      [ "$pd_code" -ge 200 ] 2>/dev/null && [ "$pd_code" -lt 300 ] 2>/dev/null && pd_ip=$(tr -d '\r' < "$TMP/dom_$pd_id" | tr '[:upper:]' '[:lower:]' | sed -n -e 's/^x-request-ip:[[:space:]]*//p' -e 's/^x-response-cinfo:.*\([0-9][0-9a-f:.]*\).*/\1/p' | head -n 1)
      ;;
    alibaba)
      pd_url="https://$(date +%s)$$.dns-detect.alicdn.com/api/detect/DescribeDNSLookup?cb=ipforai"
      pd_res=$(curl -sS -m "$NET_TIMEOUT" -o "$TMP/dom_$pd_id" -w '%{http_code}|%{time_total}' "$pd_url" 2>/dev/null)
      IFS='|' read -r pd_code pd_time <<EOF
$pd_res
EOF
      [ "$pd_code" -ge 200 ] 2>/dev/null && [ "$pd_code" -lt 300 ] 2>/dev/null && pd_ip=$(sed -n 's/.*"localIp":"\([^"]*\)".*/\1/p' "$TMP/dom_$pd_id")
      ;;
    tencent)
      pd_res=$(curl -sS -m "$NET_TIMEOUT" -o "$TMP/dom_$pd_id" -w '%{http_code}|%{time_total}' "https://vv.video.qq.com/checktime?otype=json&_=$(date +%s)$$" 2>/dev/null)
      IFS='|' read -r pd_code pd_time <<EOF
$pd_res
EOF
      [ "$pd_code" -ge 200 ] 2>/dev/null && [ "$pd_code" -lt 300 ] 2>/dev/null && pd_ip=$(sed -n 's/.*"ip":"\([^"]*\)".*/\1/p' "$TMP/dom_$pd_id")
      ;;
  esac
  valid_ip "$pd_ip" || pd_ip=''
  pd_ms=$(awk -v s="$pd_time" 'BEGIN { if (s ~ /^[0-9]+([.][0-9]+)?$/) printf "%.0fms", s * 1000 }')
  printf '%s|%s\n' "$pd_ip" "$pd_ms" > "$TMP/dom_res_$pd_id"
}

probe_telemetry() {
  pt_id="$1"; pt_host="$2"; pt_cf="$3"; pt_path="$4"
  pt_ip=''; pt_colo=''; pt_code=''; pt_time=''; pt_rem=''
  if [ "$pt_cf" = "yes" ]; then
    pt_res=$(curl $CURL_STACK -sS -m "$NET_TIMEOUT" -o "$TMP/tel_$pt_id.body" -w '%{http_code}|%{time_total}|%{remote_ip}' "https://$pt_host$pt_path" 2>/dev/null)
    IFS='|' read -r pt_code pt_time pt_rem <<EOF
$pt_res
EOF
    if [ "$pt_code" -ge 200 ] 2>/dev/null && [ "$pt_code" -lt 300 ] 2>/dev/null; then
      pt_ip=$(sed -n 's/^ip=//p' "$TMP/tel_$pt_id.body" | head -n 1)
      pt_colo=$(sed -n 's/^colo=//p' "$TMP/tel_$pt_id.body" | head -n 1)
      valid_ip "$pt_ip" || pt_ip=''
    fi
  else
    pt_res=$(curl $CURL_STACK -s -m "$NET_TIMEOUT" -o /dev/null -w '%{http_code}|%{time_total}|%{remote_ip}' "https://$pt_host$pt_path" 2>/dev/null)
    IFS='|' read -r pt_code pt_time pt_rem <<EOF
$pt_res
EOF
  fi
  pt_ms=$(awk -v s="$pt_time" 'BEGIN { if (s ~ /^[0-9]+([.][0-9]+)?$/) printf "%.0fms", s * 1000 }')
  printf '%s|%s|%s|%s|%s\n' "$pt_code" "$pt_ip" "$pt_colo" "$pt_ms" "$pt_rem" > "$TMP/tel_res_$pt_id"
}

probe_tls_cert() {
  ptc_id="$1"; ptc_host="$2"
  curl $CURL_STACK -sS -vI -m "$NET_TIMEOUT" "https://$ptc_host/" -o /dev/null > /dev/null 2> "$TMP/tls_$ptc_id" || true
  ptc_ver=$(grep -iE 'SSL connection using|TLSv1\.[23]' "$TMP/tls_$ptc_id" 2>/dev/null | head -n 1 | sed -n 's/.*\(TLSv1\.[0-9]\).*/\1/p')
  ptc_issuer=$(grep -i 'issuer:' "$TMP/tls_$ptc_id" 2>/dev/null | head -n 1 | sed 's/.*issuer:[[:space:]]*//')
  ptc_cn=$(printf '%s' "$ptc_issuer" | sed -n 's/.*O=\([^;,]*\).*/\1/p')
  [ -z "$ptc_cn" ] && ptc_cn=$(printf '%s' "$ptc_issuer" | sed -n 's/.*CN=\([^;,]*\).*/\1/p')
  [ -z "$ptc_cn" ] && ptc_cn="$ptc_issuer"
  printf '%s|%s\n' "$ptc_ver" "$ptc_cn" > "$TMP/tls_res_$ptc_id"
}

probe_forced_stack() {
  pfs_flag="$1"; pfs_domain="$2"; pfs_out="$3"
  pfs_res=$(curl -sS "$pfs_flag" -m 5 -o "$pfs_out.body" -w '%{http_code}|%{time_total}' "https://$pfs_domain/cdn-cgi/trace" 2>/dev/null)
  IFS='|' read -r pfs_code pfs_time <<EOF
$pfs_res
EOF
  pfs_ip=''
  if [ "$pfs_code" -ge 200 ] 2>/dev/null && [ "$pfs_code" -lt 300 ] 2>/dev/null; then
    pfs_ip=$(sed -n 's/^ip=//p' "$pfs_out.body" | head -n 1)
    valid_ip "$pfs_ip" || pfs_ip=''
  fi
  pfs_ms=$(awk -v s="$pfs_time" 'BEGIN { if (s ~ /^[0-9]+([.][0-9]+)?$/) printf "%.0fms", s * 1000 }')
  printf '%s|%s\n' "$pfs_ip" "$pfs_ms" > "$pfs_out"
}

build_official() {
  bo_out="${2:-$TMP/official}"
  extract_products "$1" > "$TMP/products"
  : > "$bo_out"
  while read -r bo_line || [ -n "$bo_line" ]; do
    bo_sid=$(json_str "$bo_line" serviceId)
    [ -z "$bo_sid" ] && continue
    printf '%s|%s|%s\n' "$bo_sid" \
      "$(json_str "$bo_line" regionPolicyStatus)" \
      "$(json_str "$bo_line" regionPolicyLabel)" >> "$bo_out"
  done < "$TMP/products"
}

OFF_STATE=''; OFF_NOTE=''
official_of() {
  of_file="${2:-$TMP/official}"
  of_all=0; of_no=0; of_un=0
  [ -f "$of_file" ] && while IFS='|' read -r of_sid of_st _of_l; do
    [ "$of_sid" = "$1" ] || continue
    of_all=$(( of_all + 1 ))
    case "$of_st" in
      not_supported) of_no=$(( of_no + 1 )) ;;
      unknown)       of_un=$(( of_un + 1 )) ;;
    esac
  done < "$of_file"

  if [ "$of_all" -eq 0 ]; then
    OFF_STATE='none'; OFF_NOTE=''
  elif [ "$of_no" -eq "$of_all" ]; then
    OFF_STATE='blocked'; OFF_NOTE='官方不支持'
  elif [ "$of_no" -gt 0 ]; then
    OFF_STATE='partial'; OFF_NOTE='部分准入'
  elif [ "$of_un" -eq "$of_all" ]; then
    OFF_STATE='unsure'; OFF_NOTE=''
  else
    OFF_STATE='open'; OFF_NOTE=''
  fi
}

# ==============================================================================
# 本机全量流式分阶段检测
# ==============================================================================

if [ -n "$TARGET_IP" ]; then
  SCORE_IP="$PRIMARY_IP"
  SCORE_JSON="$PRIMARY"
  [ -z "$SCORE_JSON" ] && SCORE_JSON=$(fetch "$API_BASE/api/ip-profile?ip=$SCORE_IP")
  build_official "$PRIMARY"
  SCORE_SECTION='[02]'
else
  # ---------- 阶段 2：四家 AI 网页 & API 分流对照 + 分段耗时 ----------
  printf '\n  %s[02] 四家 AI 网页 & API 分流与分段耗时%s\n' "$TITLE" "$R"

  core_ai_lines | { while IFS='|' read -r c_id c_name c_web c_api_h c_api_u c_exp; do
    probe_core_line "$c_id" "$c_web" "$c_api_h" "$c_api_u" "$c_exp" &
  done; wait; } & p_core=$!

  domestic_probes | { while IFS='|' read -r d_id d_name d_mode d_target; do
    probe_domestic "$d_id" "$d_mode" "$d_target" &
  done; wait; } & p_dom=$!

  spin_wait "正在探测四家 AI 网页 & API 分流" "$p_core" "$p_dom"

  DOMESTIC_IP=''
  for d_id in tencent alibaba bytedance; do
    [ -f "$TMP/dom_res_$d_id" ] || continue
    IFS='|' read -r d_ip _d_ms < "$TMP/dom_res_$d_id"
    if [ -n "$d_ip" ]; then DOMESTIC_IP="$d_ip"; break; fi
  done

  : > "$TMP/ai_exits"
  for c_id in claude chatgpt grok; do
    if [ -f "$TMP/core_web_$c_id" ]; then
      IFS='|' read -r _c w_ip _col _ms _rem < "$TMP/core_web_$c_id"
      [ -n "$w_ip" ] && echo "$w_ip" >> "$TMP/ai_exits"
    fi
    if [ -f "$TMP/core_api_tr_$c_id" ]; then
      IFS='|' read -r _c a_ip _col _ms _rem < "$TMP/core_api_tr_$c_id"
      [ -n "$a_ip" ] && echo "$a_ip" >> "$TMP/ai_exits"
    fi
  done

  AI_EXIT=$(sort "$TMP/ai_exits" 2>/dev/null | uniq -c | sort -rn | head -n 1 | awk '{print $2}')
  SCORE_IP="${AI_EXIT:-$PRIMARY_IP}"
  SCORE_JSON=$(profile_of "$SCORE_IP")
  [ -z "$SCORE_JSON" ] && SCORE_JSON=$(fetch "$API_BASE/api/ip-profile?ip=$SCORE_IP")
  [ -z "$SCORE_JSON" ] && SCORE_JSON="$PRIMARY"
  build_official "$SCORE_JSON"
  if [ "$DUAL_STACK_PROBE" -eq 1 ]; then
    [ -s "$TMP/p_v4" ] && build_official "$(cat "$TMP/p_v4")" "$TMP/official_v4"
    [ -s "$TMP/p_v6" ] && build_official "$(cat "$TMP/p_v6")" "$TMP/official_v6"
  fi
  AI_CC=$(json_str "$(json_scope "$SCORE_JSON" geo)" countryCode)

  HAS_SPLIT_ROUTING=0
  if [ -n "$DOMESTIC_IP" ] && [ -n "$AI_EXIT" ] && [ "$DOMESTIC_IP" != "$AI_EXIT" ]; then
    if ! { is_local_exit_ip "$DOMESTIC_IP" && is_local_exit_ip "$AI_EXIT"; }; then
      HAS_SPLIT_ROUTING=1
    fi
  fi

  if [ -n "$DOMESTIC_IP" ]; then
    if [ "$HAS_SPLIT_ROUTING" -eq 1 ]; then
      printf '  %s国内基线%s  %s  %s✓ 已与 AI 出口分流%s\n\n' "$DIM" "$R" "$DOMESTIC_IP" "$GRN" "$R"
    elif is_local_exit_ip "$DOMESTIC_IP" && is_local_exit_ip "$AI_EXIT" && [ "$DOMESTIC_IP" != "$AI_EXIT" ]; then
      case "$DOMESTIC_IP" in *:*) dom_fam='IPv6' ;; *) dom_fam='IPv4' ;; esac
      case "$AI_EXIT" in *:*) ai_fam='IPv6' ;; *) ai_fam='IPv4' ;; esac
      printf '  %s国内基线%s  %s  %s同机不同栈（国内走 %s，AI 走 %s，未分流）%s\n\n' "$DIM" "$R" "$DOMESTIC_IP" "$DIM" "$dom_fam" "$ai_fam" "$R"
    else
      printf '  %s国内基线%s  %s  %s! 与 AI 出口相同（未分流或全局代理）%s\n\n' "$DIM" "$R" "$DOMESTIC_IP" "$YEL" "$R"
    fi
  else
    printf '  %s国内基线%s  未读到\n\n' "$DIM" "$R"
  fi

  format_stack_cell() {
    fsc_st="$1"; fsc_code="$2"; fsc_ms="$3"; fsc_off_st="$4"; fsc_off_note="$5"
    case "$fsc_st" in
      ok)     fsc_txt="${GRN}✓ 可达${R}${fsc_ms:+ · $fsc_ms}" ;;
      review) fsc_txt="${YEL}! HTTP ${fsc_code:-?}${R}${fsc_ms:+ · $fsc_ms}" ;;
      *)      fsc_txt="${RED}× 失败${R}" ;;
    esac
    if [ "$fsc_off_st" = "blocked" ]; then
      fsc_txt="$fsc_txt ${RED}($fsc_off_note)${R}"
    elif [ "$fsc_off_st" = "partial" ]; then
      fsc_txt="$fsc_txt ${YEL}($fsc_off_note)${R}"
    fi
    printf '%s' "$fsc_txt"
  }

  core_ai_lines | while IFS='|' read -r c_id c_name c_web c_api_h c_api_u c_exp; do
    w_ip=''; w_colo=''; w_ms=''
    a_ip=''; a_colo=''; a_ms=''
    api_st='fail'; api_code=''; api_ms=''; api_rem=''; api_bd=''

    [ -f "$TMP/core_web_$c_id" ] && IFS='|' read -r _wc w_ip w_colo w_ms _wr < "$TMP/core_web_$c_id"
    [ -f "$TMP/core_api_tr_$c_id" ] && IFS='|' read -r _ac a_ip a_colo a_ms _ar < "$TMP/core_api_tr_$c_id"
    [ -f "$TMP/core_api_$c_id" ] && IFS='|' read -r api_st api_code api_ms api_rem api_bd < "$TMP/core_api_$c_id"

    official_of "$c_id"
    case "$api_st" in
      ok)     mark="${GRN}✓${R}"; st_txt="API 可达" ;;
      review) mark="${YEL}!${R}"; st_txt="响应异常" ;;
      *)      mark="${RED}×${R}"; st_txt="连接失败" ;;
    esac
    [ -n "$api_ms" ] && st_txt="$st_txt · $api_ms"
    [ "$DETAIL" -eq 1 ] && [ -n "$api_code" ] && st_txt="$st_txt (HTTP $api_code)"

    set_pad "$c_name" 9
    printf '  %s %s%s%s' "$mark" "$B$c_name$R" "$PAD" "$st_txt"
    if [ "$OFF_STATE" = "blocked" ]; then
      printf '  %s· %s%s' "$RED" "$OFF_NOTE" "$R"
    elif [ "$OFF_STATE" = "partial" ]; then
      printf '  %s· %s%s' "$YEL" "$OFF_NOTE" "$R"
    fi
    printf '\n'
    [ "$api_st" = "fail" ] && add_advice "$c_name API 连接失败 → 检查代理规则是否覆盖该服务域名"

    if [ "$DUAL_STACK_PROBE" -eq 1 ]; then
      v4_st='fail'; v4_code=''; v4_ms=''
      v6_st='fail'; v6_code=''; v6_ms=''
      [ -f "$TMP/core_api_v4_$c_id" ] && IFS='|' read -r v4_st v4_code v4_ms < "$TMP/core_api_v4_$c_id"
      [ -f "$TMP/core_api_v6_$c_id" ] && IFS='|' read -r v6_st v6_code v6_ms < "$TMP/core_api_v6_$c_id"
      official_of "$c_id" "$TMP/official_v4"
      v4_off_st="$OFF_STATE"; v4_off_note="$OFF_NOTE"
      official_of "$c_id" "$TMP/official_v6"
      v6_off_st="$OFF_STATE"; v6_off_note="$OFF_NOTE"
      printf '      双栈实测：IPv4 %s  |  IPv6 %s\n' \
        "$(format_stack_cell "$v4_st" "$v4_code" "$v4_ms" "$v4_off_st" "$v4_off_note")" \
        "$(format_stack_cell "$v6_st" "$v6_code" "$v6_ms" "$v6_off_st" "$v6_off_note")"
      if [ "$v4_st" = "ok" ] && [ "$v6_st" != "ok" ]; then
        add_advice "$c_name 的 IPv4 可达但 IPv6 异常 → 建议优先走 IPv4 或在客户端配置关闭 IPv6"
      elif [ "$v6_st" = "ok" ] && [ "$v4_st" != "ok" ]; then
        add_advice "$c_name 的 IPv6 可达但 IPv4 异常 → 核查 IPv4 出口是否受限"
      fi
    fi

    if [ -n "$c_web" ]; then
      web_show="${w_ip:-未读到}${w_colo:+ ($w_colo)}"
      api_show="${a_ip:-未读到}${a_colo:+ ($a_colo)}"
      if [ -n "$w_ip" ] && [ -n "$a_ip" ] && [ "$w_ip" != "$a_ip" ]; then
        printf '      网页：%s  |  API：%s%s%s  %s! 网页与 API 分裂%s\n' "$web_show" "$RED" "$api_show" "$R" "$RED" "$R"
        add_advice "$c_name 网页与 API 出口不同 → 让 $c_web 与 $c_api_h 走同一代理节点"
      elif [ "$HAS_SPLIT_ROUTING" -eq 1 ] && [ -n "$DOMESTIC_IP" ] && { [ "$w_ip" = "$DOMESTIC_IP" ] || [ "$a_ip" = "$DOMESTIC_IP" ]; }; then
        printf '      网页：%s  |  API：%s  %s! 与国内基线相同（未进代理）%s\n' "$web_show" "$api_show" "$RED" "$R"
        add_advice "$c_name 流量未进代理 → 在代理规则中加入 $c_web、$c_api_h"
      else
        printf '      %s网页：%s  |  API：%s%s\n' "$DIM" "$web_show" "$api_show" "$R"
      fi
    else
      if [ -n "$api_rem" ]; then
        if is_loopback_ip "$api_rem" || is_fake_ip "$api_rem"; then
          printf '      %s已进代理 · 出口按主出口计%s\n' "$DIM" "$R"
        else
          printf '      %s出口未回显 · 按主出口计%s\n' "$DIM" "$R"
        fi
      fi
    fi
    [ -n "$api_bd" ] && printf '      %s耗时拆解：%s%s\n' "$DIM" "$api_bd" "$R"
  done

  # ---------- 阶段 3：强制双栈（IPv4 vs IPv6）与本机 DNS 解析 ----------
  printf '\n  %s[03] 双栈出口、IPv6 泄漏与本机 DNS 解析%s\n' "$TITLE" "$R"

  # 设了 HTTP 代理变量时 curl -4/-6 只约束本机到代理一跳，结果不反映出口地址族，不再测
  p_fs1=''; p_fs2=''; p_fs3=''; p_fs4=''
  if [ -z "$PROXY_SET" ]; then
    if [ "$STACK_FORCE" != "-6" ]; then
      probe_forced_stack -4 claude.ai "$TMP/fs_v4_claude" & p_fs1=$!
      probe_forced_stack -4 api.anthropic.com "$TMP/fs_v4_api" & p_fs3=$!
    fi
    if [ "$STACK_FORCE" != "-4" ]; then
      probe_forced_stack -6 claude.ai "$TMP/fs_v6_claude" & p_fs2=$!
      probe_forced_stack -6 api.anthropic.com "$TMP/fs_v6_api" & p_fs4=$!
    fi
  fi
  # IPv6 泄漏：绕过代理变量、用 IPv6 字面地址直连（不走 DNS），看原生 IPv6 从哪个国家出去
  p_v6l=''
  if [ "$STACK_FORCE" != "-4" ]; then
    (
      v6l_body=$(curl -sS -m 4 --noproxy '*' 'https://[2606:4700:4700::1111]/cdn-cgi/trace' 2>/dev/null)
      v6l_ip=$(printf '%s\n' "$v6l_body" | sed -n 's/^ip=//p' | head -n 1)
      v6l_loc=$(printf '%s\n' "$v6l_body" | sed -n 's/^loc=//p' | head -n 1)
      valid_ip "$v6l_ip" || v6l_ip=''
      printf '%s|%s\n' "$v6l_ip" "$v6l_loc" > "$TMP/v6_leak"
    ) & p_v6l=$!
  fi
  (
    for h in claude.ai api.anthropic.com chatgpt.com gemini.google.com grok.com api.statsig.com; do
      ip=$(resolve_local_dns "$h")
      printf '%s|%s\n' "$h" "$ip" >> "$TMP/local_dns"
    done
  ) & p_ldns=$!
  spin_wait "正在检测双栈出口与本机 DNS" "$p_fs1" "$p_fs2" "$p_fs3" "$p_fs4" "$p_v6l" "$p_ldns"

  if [ -n "$PROXY_SET" ]; then
    printf '  %s双栈出口%s    由代理节点决定\n' "$DIM" "$R"
  else
    v4_c=''; v4_cm=''; v6_c=''; v6_cm=''; v4_a=''; v4_am=''; v6_a=''; v6_am=''
    IFS='|' read -r v4_c v4_cm < "$TMP/fs_v4_claude" 2>/dev/null
    IFS='|' read -r v6_c v6_cm < "$TMP/fs_v6_claude" 2>/dev/null
    IFS='|' read -r v4_a v4_am < "$TMP/fs_v4_api" 2>/dev/null
    IFS='|' read -r v6_a v6_am < "$TMP/fs_v6_api" 2>/dev/null
    # IPv6 通道回显的是 IPv4 地址，说明被代理或网关转成了 IPv4 出口，不能写在 IPv6 列下当作 IPv6 出口
    case "$v6_c" in ''|*:*) ;; *) v6_c="IPv4 出口 $v6_c" ;; esac
    case "$v6_a" in ''|*:*) ;; *) v6_a="IPv4 出口 $v6_a" ;; esac
    if [ "$STACK_FORCE" = "-6" ]; then
      v4_c_disp="${DIM}已跳过 (-6)${R}"
      v4_a_disp="${DIM}已跳过 (-6)${R}"
    else
      v4_c_disp="${v4_c:-不可达}${v4_cm:+ ($v4_cm)}"
      v4_a_disp="${v4_a:-不可达}${v4_am:+ ($v4_am)}"
    fi
    if [ "$STACK_FORCE" = "-4" ]; then
      v6_c_disp="${DIM}已跳过 (-4)${R}"
      v6_a_disp="${DIM}已跳过 (-4)${R}"
    else
      v6_c_disp="${v6_c:-无/未通}${v6_cm:+ ($v6_cm)}"
      v6_a_disp="${v6_a:-无/未通}${v6_am:+ ($v6_am)}"
    fi
    printf '  %sclaude.ai%s          IPv4: %s  |  IPv6: %s\n' "$DIM" "$R" "$v4_c_disp" "$v6_c_disp"
    printf '  %sapi.anthropic.com%s  IPv4: %s  |  IPv6: %s\n' "$DIM" "$R" "$v4_a_disp" "$v6_a_disp"
  fi

  v6l_ip=''; v6l_loc=''
  if [ "$STACK_FORCE" = "-4" ]; then
    printf '  %sIPv6 直连%s   %s已指定 -4 仅测 IPv4%s\n' "$DIM" "$R" "$DIM" "$R"
  else
    IFS='|' read -r v6l_ip v6l_loc < "$TMP/v6_leak" 2>/dev/null
    case "$v6l_ip" in *:*) ;; *) v6l_ip='' ;; esac
    if [ -z "$v6l_ip" ]; then
      printf '  %sIPv6 直连%s   %s✓ 无原生 IPv6 出口%s\n' "$DIM" "$R" "$GRN" "$R"
    elif [ -n "$AI_CC" ] && [ "$v6l_loc" = "$AI_CC" ]; then
      if [ -z "$PROXY_SET" ] && [ "$HAS_SPLIT_ROUTING" -eq 0 ] && [ "$v6l_ip" = "$IP6" ]; then
        printf '  %sIPv6 直连%s   %s原生 IPv6 直连（%s，与主出口同区）%s\n' "$DIM" "$R" "$DIM" "$v6l_loc" "$R"
      else
        printf '  %sIPv6 直连%s   %s✓ 已进代理（%s）%s\n' "$DIM" "$R" "$GRN" "$v6l_loc" "$R"
      fi
    elif [ -n "$PROXY_SET" ]; then
      # 代理变量模式下直连本来就不经代理（国内基线已体现），这里只说明有原生 IPv6
      printf '  %sIPv6 直连%s   %s (%s) · 本机有原生 IPv6，不读代理变量的程序会直连\n' "$DIM" "$R" "$v6l_ip" "${v6l_loc:-?}"
    else
      printf '  %sIPv6 直连%s   %s%s (%s)  ! 绕过代理直连%s\n' "$DIM" "$R" "$RED" "$v6l_ip" "${v6l_loc:-?}" "$R"
      add_advice "IPv6 流量绕过代理从 ${v6l_loc:-本地} 直连 → 在代理客户端开启 IPv6 接管，或关闭系统 IPv6"
    fi
  fi

  printf '  %s本机 DNS 解析%s：\n' "$DIM" "$R"
  if [ -s "$TMP/local_dns" ]; then
    while IFS='|' read -r dh dip; do
      set_pad "$dh" 24
      if [ -z "$dip" ]; then
        printf '    %s%s%s解析失败 / 无记录%s\n' "$dh" "$PAD" "$YEL" "$R"
      elif is_fake_ip "$dip"; then
        printf '    %s%s%s%s%s  %sFake-IP（代理 TUN 接管）%s\n' "$dh" "$PAD" "$GRN" "$dip" "$R" "$DIM" "$R"
      elif is_loopback_ip "$dip" || [ "$dip" = "0.0.0.0" ]; then
        printf '    %s%s%s%s%s  %s被拦截或指向本机%s\n' "$dh" "$PAD" "$RED" "$dip" "$R" "$RED" "$R"
        add_advice "$dh 解析到 $dip → 检查 hosts 文件与 DNS 设置"
      else
        off_tag=$(dns_official_tag "$dh" "$dip")
        if [ -n "$off_tag" ]; then
          printf '    %s%s%s  %s✓ %s%s\n' "$dh" "$PAD" "$dip" "$GRN" "$off_tag" "$R"
        else
          printf '    %s%s%s  %s! 非常见官方段（核查 DNS 污染或自定义反代）%s\n' "$dh" "$PAD" "$dip" "$YEL" "$R"
        fi
      fi
    done < "$TMP/local_dns"
  fi

  # ---------- 阶段 4：AI 遥测 / 埋点 / 鉴权域名 ----------
  printf '\n  %s[04] AI 遥测 / 埋点 / 鉴权域名（防终端漏代理）%s\n' "$TITLE" "$R"

  TEL_COUNT=$(telemetry_targets | wc -l | tr -d ' ')
  telemetry_targets | { while IFS='|' read -r t_id t_label t_host t_cf t_path t_grp; do
    probe_telemetry "$t_id" "$t_host" "$t_cf" "$t_path" &
  done; wait; } & p_tel=$!
  spin_wait "正在探测 $TEL_COUNT 个遥测与鉴权域名" "$p_tel"

  : > "$TMP/tel_eval"
  telemetry_targets | while IFS='|' read -r t_id t_label t_host t_cf t_path t_grp; do
    [ -f "$TMP/tel_res_$t_id" ] || continue
    IFS='|' read -r t_code t_ip t_colo t_ms t_rem < "$TMP/tel_res_$t_id"
    t_status=''
    if [ -z "$t_code" ] || [ "$t_code" = "000" ]; then
      t_status='fail'
    elif [ -n "$t_ip" ]; then
      if [ "$HAS_SPLIT_ROUTING" -eq 1 ] && [ -n "$DOMESTIC_IP" ] && [ "$t_ip" = "$DOMESTIC_IP" ]; then
        t_status='leak'
        add_advice "$t_label 直连国内 → 在代理规则中加入 $t_host"
      elif [ -n "$AI_EXIT" ] && [ "$t_ip" != "$AI_EXIT" ]; then
        if is_local_exit_ip "$t_ip" && is_local_exit_ip "$AI_EXIT"; then
          t_status='alt_stack'
        else
          t_status='split'
          add_advice "$t_label 出口与主出口不同 → 让 $t_host 与 AI 主域名走同一节点"
        fi
      elif [ -n "$AI_EXIT" ]; then
        t_status='match'
      else
        t_status='ip_ok'
      fi
    else
      if [ -n "$t_rem" ] && { is_loopback_ip "$t_rem" || is_fake_ip "$t_rem"; }; then
        t_status='proxy_ok'
      else
        t_status='reach_ok'
      fi
    fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$t_grp" "$t_status" "$t_id" "$t_label" "$t_host" "$t_ip" "$t_ms" "$t_rem" >> "$TMP/tel_eval"
  done

  TEL_FAIL_N=$(awk -F'|' '$2 == "fail" { n++ } END { print n + 0 }' "$TMP/tel_eval")
  if [ "$TEL_FAIL_N" -gt 0 ]; then
    TEL_FAIL_SAMPLE=$(awk -F'|' '$2 == "fail" { if (c < 3) { s = (s ? s "、" : "") $5; c++ } } END { print s }' "$TMP/tel_eval")
    if [ "$TEL_FAIL_N" -gt 3 ]; then
      add_advice "$TEL_FAIL_N 个遥测/鉴权域名连接失败（如 $TEL_FAIL_SAMPLE 等）→ 检查代理规则或网络连通性"
    else
      add_advice "$TEL_FAIL_N 个遥测/鉴权域名连接失败（$TEL_FAIL_SAMPLE）→ 检查代理规则或网络连通性"
    fi
  fi

  if [ "$DETAIL" -eq 1 ]; then
    while IFS='|' read -r t_grp t_status t_id t_label t_host t_ip t_ms t_rem; do
      set_pad "$t_label" 28
      l_pad="$PAD"
      case "$t_status" in
        fail)
          printf '  %s×%s %s%s%s连接失败%s  %s(%s)%s\n' "$RED" "$R" "$t_label" "$l_pad" "$RED" "$R" "$DIM" "$t_host" "$R" ;;
        leak)
          printf '  %s!%s %s%s%s%s%s · %s  %s漏网直连国内%s\n' "$RED" "$R" "$t_label" "$l_pad" "$RED" "$t_ip" "$R" "${t_ms:-?}" "$RED" "$R" ;;
        split)
          printf '  %s!%s %s%s%s%s%s · %s  %s与主出口不同%s\n' "$YEL" "$R" "$t_label" "$l_pad" "$YEL" "$t_ip" "$R" "${t_ms:-?}" "$YEL" "$R" ;;
        alt_stack)
          printf '  %s✓%s %s%s%s · %s  %s同机另一地址族%s\n' "$GRN" "$R" "$t_label" "$l_pad" "$t_ip" "${t_ms:-?}" "$DIM" "$R" ;;
        match)
          printf '  %s✓%s %s%s%s · %s  %s与主出口一致%s\n' "$GRN" "$R" "$t_label" "$l_pad" "$t_ip" "${t_ms:-?}" "$DIM" "$R" ;;
        ip_ok)
          printf '  %s✓%s %s%s%s · %s  %s可达%s\n' "$GRN" "$R" "$t_label" "$l_pad" "$t_ip" "${t_ms:-?}" "$DIM" "$R" ;;
        proxy_ok)
          printf '  %s✓%s %s%s可达 · %s  %s已进代理%s\n' "$GRN" "$R" "$t_label" "$l_pad" "${t_ms:-?}" "$DIM" "$R" ;;
        reach_ok)
          printf '  %s✓%s %s%s可达 · %s  %s出口未回显%s\n' "$GRN" "$R" "$t_label" "$l_pad" "${t_ms:-?}" "$DIM" "$R" ;;
      esac
    done < "$TMP/tel_eval"
  else
    telemetry_groups | while IFS='|' read -r g_id g_label; do
      g_total=0; g_ok=0; g_bad=0; g_has_red=0
      g_match_ip=''; g_ip_ok=''; g_has_alt=0; g_has_proxy=0
      while IFS='|' read -r e_grp e_st _eid _elabel _ehost e_ip _ems _erem; do
        [ "$e_grp" = "$g_id" ] || continue
        g_total=$(( g_total + 1 ))
        case "$e_st" in
          fail|leak)
            g_bad=$(( g_bad + 1 ))
            g_has_red=1 ;;
          split)
            g_bad=$(( g_bad + 1 )) ;;
          match)
            g_ok=$(( g_ok + 1 ))
            [ -z "$g_match_ip" ] && [ -n "$e_ip" ] && g_match_ip="$e_ip" ;;
          ip_ok)
            g_ok=$(( g_ok + 1 ))
            [ -z "$g_ip_ok" ] && [ -n "$e_ip" ] && g_ip_ok="$e_ip" ;;
          alt_stack)
            g_ok=$(( g_ok + 1 ))
            g_has_alt=1 ;;
          proxy_ok)
            g_ok=$(( g_ok + 1 ))
            g_has_proxy=1 ;;
          reach_ok)
            g_ok=$(( g_ok + 1 )) ;;
        esac
      done < "$TMP/tel_eval"
      [ "$g_total" -eq 0 ] && continue

      g_title="$g_label ($g_ok/$g_total)"
      set_pad "$g_title" 28
      g_pad="$PAD"

      if [ "$g_bad" -eq 0 ]; then
        if [ -n "$g_match_ip" ]; then
          if [ "$g_total" -eq 1 ]; then
            g_note='与主出口一致'
          else
            g_note='均可达且与主出口一致'
          fi
          printf '  %s✓%s %s%s%s  %s%s%s\n' "$GRN" "$R" "$g_title" "$g_pad" "$g_match_ip" "$DIM" "$g_note" "$R"
        elif [ "$g_has_alt" -eq 1 ]; then
          printf '  %s✓%s %s%s全部可达 · %s同机另一地址族%s\n' "$GRN" "$R" "$g_title" "$g_pad" "$DIM" "$R"
        elif [ -n "$g_ip_ok" ]; then
          printf '  %s✓%s %s%s%s  %s全部可达%s\n' "$GRN" "$R" "$g_title" "$g_pad" "$g_ip_ok" "$DIM" "$R"
        elif [ "$g_has_proxy" -eq 1 ]; then
          printf '  %s✓%s %s%s全部可达 · %s已进代理%s\n' "$GRN" "$R" "$g_title" "$g_pad" "$DIM" "$R"
        else
          printf '  %s✓%s %s%s全部可达 · %s出口未回显%s\n' "$GRN" "$R" "$g_title" "$g_pad" "$DIM" "$R"
        fi
      else
        if [ "$g_has_red" -eq 1 ]; then g_clr="$RED"; else g_clr="$YEL"; fi
        if [ "$g_ok" -gt 0 ]; then
          g_err_txt="$g_bad 项异常，其余 $g_ok 项正常"
        else
          g_err_txt="$g_bad 项异常"
        fi
        printf '  %s!%s %s%s%s%s%s\n' "$g_clr" "$R" "$g_title" "$g_pad" "$g_clr" "$g_err_txt" "$R"
        while IFS='|' read -r e_grp e_st _eid e_label e_host e_ip e_ms _erem; do
          [ "$e_grp" = "$g_id" ] || continue
          case "$e_st" in
            fail|leak|split)
              set_pad "$e_label" 26
              case "$e_st" in
                fail)  printf '      %s×%s %s%s%s连接失败%s  %s(%s)%s\n' "$RED" "$R" "$e_label" "$PAD" "$RED" "$R" "$DIM" "$e_host" "$R" ;;
                leak)  printf '      %s!%s %s%s%s%s%s · %s  %s漏网直连国内%s\n' "$RED" "$R" "$e_label" "$PAD" "$RED" "$e_ip" "$R" "${e_ms:-?}" "$RED" "$R" ;;
                split) printf '      %s!%s %s%s%s%s%s · %s  %s与主出口不同%s\n' "$YEL" "$R" "$e_label" "$PAD" "$YEL" "$e_ip" "$R" "${e_ms:-?}" "$YEL" "$R" ;;
              esac
              ;;
          esac
        done < "$TMP/tel_eval"
      fi
    done
    printf '  %s共探测 %s 项 · 加 -d 展开全部逐项明细%s\n' "$DIM" "$TEL_COUNT" "$R"
  fi

  # ---------- 阶段 5：TLS 证书链 & 被动 TCP 首包 + 双端 RTT 延迟差 ----------
  printf '\n  %s[05] TLS 证书链、TCP 首包与双端 RTT 延迟差%s\n' "$TITLE" "$R"

  probe_tls_cert anthropic api.anthropic.com & p_tls1=$!
  probe_tls_cert openai api.openai.com & p_tls2=$!
  probe_tls_cert gemini generativelanguage.googleapis.com & p_tls3=$!
  probe_tls_cert grok api.x.ai & p_tls4=$!
  p_tcp=''
  if ! { [ "$STACK_FORCE" = "-6" ] && [ -z "$IP4" ]; }; then
    (
      # 单次 curl 调用复用同一条热连接：先拉 SYN 指纹与服务端 RTT，再连打 3 次 /ping 测终端热往返 RTT
      curl -sS -m "$NET_TIMEOUT" \
        -o "$TMP/tcp_probe" -w 'probe|%{http_code}|%{time_total}\n' "$V4_BASE/api/tcp-probe" \
        -o /dev/null -w 'ping1|%{http_code}|%{time_total}\n' "$V4_BASE/api/tcp-probe/ping?n=1" \
        -o /dev/null -w 'ping2|%{http_code}|%{time_total}\n' "$V4_BASE/api/tcp-probe/ping?n=2" \
        -o /dev/null -w 'ping3|%{http_code}|%{time_total}\n' "$V4_BASE/api/tcp-probe/ping?n=3" \
        > "$TMP/tcp_pings" 2>/dev/null || true
    ) & p_tcp=$!
  fi
  spin_wait "正在检测 TLS 证书链与 TCP 延迟差" "$p_tls1" "$p_tls2" "$p_tls3" "$p_tls4" "$p_tcp"

  for tls_pair in "anthropic|api.anthropic.com" "openai|api.openai.com" "gemini|generativelanguage.googleapis.com" "grok|api.x.ai"; do
    IFS='|' read -r tid thost <<EOF
$tls_pair
EOF
    [ -f "$TMP/tls_res_$tid" ] || continue
    IFS='|' read -r tver tiss < "$TMP/tls_res_$tid"
    set_pad "$thost" 35
    if [ -z "$tver" ] && [ -z "$tiss" ]; then
      printf '  %s!%s %s%s未读到 TLS 握手信息\n' "$YEL" "$R" "$thost" "$PAD"
    else
      case "$tiss" in
        *Google*|*Cloudflare*|*DigiCert*|*Let\'s\ Encrypt*|*Amazon*|*Sectigo*|*GlobalSign*)
          printf '  %s✓%s %s%s%s · 签发方 %s\n' "$GRN" "$R" "$thost" "$PAD" "${tver:-TLS}" "${tiss:-未知}" ;;
        *)
          printf '  %s!%s %s%s%s · 签发方 %s%s%s  %s(非主流 CA，排查是否被代理/公司网关 MITM 替换)%s\n' \
            "$YEL" "$R" "$thost" "$PAD" "${tver:-TLS}" "$YEL" "${tiss:-未知}" "$R" "$YEL" "$R"
          add_advice "$thost 证书签发方为 ${tiss:-未知} → 检查代理或公司网关是否做了 HTTPS 解密" ;;
      esac
    fi
  done

  TCP_JSON=$(cat "$TMP/tcp_probe" 2>/dev/null)
  if [ -n "$TCP_JSON" ]; then
    TCP_SRTT=$(json_num "$TCP_JSON" serverRttMs)
    SYN_O=$(json_scope "$TCP_JSON" syn)
    SYN_OS=$(json_str "$SYN_O" guessedOsLabel)
    SYN_OS_KEY=$(json_str "$SYN_O" guessedOs)
    SYN_TTL=$(json_num "$SYN_O" ttl)
    SYN_INIT=$(json_num "$SYN_O" initialTtl)
    SYN_OPTS=$(json_str "$SYN_O" options)
    SYN_MSS=$(json_num "$SYN_O" mss)

    LOCAL_OS_FAMILY='unknown'
    case "$OS_NAME" in
      Darwin) LOCAL_OS_FAMILY='macos_ios' ;;
      Linux) LOCAL_OS_FAMILY='linux' ;;
      MINGW*|MSYS*|CYGWIN*) LOCAL_OS_FAMILY='windows' ;;
    esac

    CLIENT_RTT=$(awk -F'|' '
      /^ping[123]\|204\|/ { vals[++n] = $3 * 1000 }
      END {
        if (n == 0) exit;
        for (i = 1; i <= n; i++)
          for (j = i + 1; j <= n; j++)
            if (vals[i] > vals[j]) { t = vals[i]; vals[i] = vals[j]; vals[j] = t; }
        mid = int((n + 1) / 2);
        printf "%.1f", vals[mid];
      }
    ' "$TMP/tcp_pings" 2>/dev/null)

    if [ -n "$SYN_OS" ]; then
      if [ -n "$SYN_OS_KEY" ] && [ "$SYN_OS_KEY" != "unknown" ] && [ "$LOCAL_OS_FAMILY" != "unknown" ] && [ "$SYN_OS_KEY" != "$LOCAL_OS_FAMILY" ]; then
        printf '  %sSYN 协议栈%s  %s · TTL %s/%s · MSS %s · 选项 %s  %s! 与本机系统不符（代理转发特征）%s\n' \
          "$DIM" "$R" "$SYN_OS" "${SYN_TTL:-?}" "${SYN_INIT:-?}" "${SYN_MSS:-?}" "${SYN_OPTS:-?}" "$YEL" "$R"
        add_advice "TCP 首包协议栈 ($SYN_OS) 与本机 ($OS_LABEL) 不符 → 经代理节点转发时的固有特征，仅直连可消除"
      else
        printf '  %sSYN 协议栈%s  %s · TTL %s/%s · MSS %s · 选项 %s\n' \
          "$DIM" "$R" "$SYN_OS" "${SYN_TTL:-?}" "${SYN_INIT:-?}" "${SYN_MSS:-?}" "${SYN_OPTS:-?}"
      fi
    fi

    if [ -n "$TCP_SRTT" ] && [ -n "$CLIENT_RTT" ]; then
      RTT_EVAL=$(awk -v s="$TCP_SRTT" -v c="$CLIENT_RTT" 'BEGIN {
        diff = c - s;
        if (diff >= 35 && c >= s * 1.6) printf "relay|%.1f", diff;
        else printf "direct|%.1f", diff;
      }')
      IFS='|' read -r rtt_flag rtt_diff <<EOF
$RTT_EVAL
EOF
      if [ "$rtt_flag" = "relay" ]; then
        printf '  %s双端 RTT%s    服务端 %sms ≠ 终端热连接 %sms  %s! 差 %sms（存在中转跳数）%s\n' \
          "$DIM" "$R" "$TCP_SRTT" "$CLIENT_RTT" "$YEL" "$rtt_diff" "$R"
        add_advice "终端与服务端 RTT 差 ${rtt_diff}ms，存在中转 → 如需降低风控，可换直连（非中转）节点"
      else
        printf '  %s双端 RTT%s    服务端 %sms / 终端热连接 %sms  %s未见显著中转延迟差%s\n' \
          "$DIM" "$R" "$TCP_SRTT" "$CLIENT_RTT" "$DIM" "$R"
      fi
    elif [ -n "$TCP_SRTT" ]; then
      printf '  %s服务端 RTT%s  %sms\n' "$DIM" "$R" "$TCP_SRTT"
    fi
  elif [ "$STACK_FORCE" = "-6" ] && [ -z "$IP4" ]; then
    printf '  %sTCP 首包探针仅支持 IPv4（已指定 -6，跳过）%s\n' "$DIM" "$R"
  else
    printf '  %sTCP 首包探针暂未连通，已跳过%s\n' "$DIM" "$R"
  fi

  # ---------- 扩展 AI 工具（-d 显示） ----------
  if [ "$DETAIL" -eq 1 ]; then
    printf '\n  %s[扩展] 其他 AI 工具分流出口（-d）%s\n' "$TITLE" "$R"
    extra_ai_routes | { while IFS='|' read -r e_id e_name e_mode e_host; do
      if [ "$e_mode" = "http" ]; then
        probe_http_reach "$e_host" "$TMP/extra_$e_id" &
      else
        probe_cf_trace "$e_host" "$TMP/extra_$e_id" &
      fi
    done; wait; } & p_ext=$!
    spin_wait "正在探测扩展 AI 工具分流" "$p_ext"

    print_wrapped_names() {
      pwn_file="$1"
      [ -s "$pwn_file" ] || return
      awk '
        BEGIN { line = ""; cnt = 0 }
        {
          if (cnt > 0 && cnt % 6 == 0) {
            printf "      %s\n", line
            line = $0
          } else {
            line = (line == "" ? $0 : line " · " $0)
          }
          cnt++
        }
        END {
          if (line != "") printf "      %s\n", line
        }
      ' "$pwn_file"
    }

    : > "$TMP/ext_match"
    : > "$TMP/ext_ip_ok"
    : > "$TMP/ext_alt"
    : > "$TMP/ext_proxy"
    : > "$TMP/ext_reach"
    : > "$TMP/ext_bad"

    while IFS='|' read -r e_id e_name e_mode e_host; do
      [ -f "$TMP/extra_$e_id" ] || continue
      IFS='|' read -r e_code e_ip e_colo e_ms e_rem < "$TMP/extra_$e_id"
      if [ "$e_mode" = "http" ]; then
        if [ -z "$e_code" ] || [ "$e_code" = "000" ]; then
          printf 'fail|%s|%s|\n' "$e_name" "$e_host" >> "$TMP/ext_bad"
        elif [ -n "$e_rem" ] && { is_loopback_ip "$e_rem" || is_fake_ip "$e_rem"; }; then
          printf '%s\n' "$e_name" >> "$TMP/ext_proxy"
        else
          printf '%s\n' "$e_name" >> "$TMP/ext_reach"
        fi
        continue
      fi
      if [ -z "$e_ip" ]; then
        if [ -z "$e_code" ] || [ "$e_code" = "000" ]; then
          printf 'fail|%s|%s|\n' "$e_name" "$e_host" >> "$TMP/ext_bad"
        else
          printf '%s\n' "$e_name" >> "$TMP/ext_reach"
        fi
      elif [ "$HAS_SPLIT_ROUTING" -eq 1 ] && [ -n "$DOMESTIC_IP" ] && [ "$e_ip" = "$DOMESTIC_IP" ]; then
        printf 'leak|%s|%s|%s\n' "$e_name" "$e_ip" "$e_ms" >> "$TMP/ext_bad"
      elif [ -n "$AI_EXIT" ] && [ "$e_ip" != "$AI_EXIT" ]; then
        if is_local_exit_ip "$e_ip" && is_local_exit_ip "$AI_EXIT"; then
          printf '%s (%s)\n' "$e_name" "$e_ip" >> "$TMP/ext_alt"
        else
          printf 'split|%s|%s|%s\n' "$e_name" "$e_ip" "$e_ms" >> "$TMP/ext_bad"
        fi
      elif [ -n "$AI_EXIT" ]; then
        printf '%s\n' "$e_name" >> "$TMP/ext_match"
      else
        printf '%s (%s)\n' "$e_name" "$e_ip" >> "$TMP/ext_ip_ok"
      fi
    done <<EOF
$(extra_ai_routes)
EOF

    if [ -s "$TMP/ext_match" ]; then
      ext_n=$(wc -l < "$TMP/ext_match" | tr -d ' ')
      printf '  %s✓%s 与主出口一致（%s 项）  %s\n' "$GRN" "$R" "$ext_n" "$AI_EXIT"
      print_wrapped_names "$TMP/ext_match"
    fi
    if [ -s "$TMP/ext_ip_ok" ]; then
      ext_n=$(wc -l < "$TMP/ext_ip_ok" | tr -d ' ')
      printf '  %s✓%s 可达 · 独立回显出口（%s 项，未识别主出口）\n' "$GRN" "$R" "$ext_n"
      print_wrapped_names "$TMP/ext_ip_ok"
    fi
    if [ -s "$TMP/ext_alt" ]; then
      ext_n=$(wc -l < "$TMP/ext_alt" | tr -d ' ')
      printf '  %s✓%s 同机另一地址族（%s 项）\n' "$GRN" "$R" "$ext_n"
      print_wrapped_names "$TMP/ext_alt"
    fi
    if [ -s "$TMP/ext_proxy" ]; then
      ext_n=$(wc -l < "$TMP/ext_proxy" | tr -d ' ')
      printf '  %s✓%s 可达 · 已进代理（%s 项，无出口回显）\n' "$GRN" "$R" "$ext_n"
      print_wrapped_names "$TMP/ext_proxy"
    fi
    if [ -s "$TMP/ext_reach" ]; then
      ext_n=$(wc -l < "$TMP/ext_reach" | tr -d ' ')
      printf '  %s✓%s 可达 · 出口未回显（%s 项）\n' "$GRN" "$R" "$ext_n"
      print_wrapped_names "$TMP/ext_reach"
    fi
    if [ -s "$TMP/ext_bad" ]; then
      while IFS='|' read -r b_kind b_name b_val b_ms; do
        set_pad "$b_name" 16
        case "$b_kind" in
          leak)  printf '  %s!%s %s%s%s%s%s · %s  %s漏网直连国内%s\n' "$RED" "$R" "$b_name" "$PAD" "$RED" "$b_val" "$R" "${b_ms:-?}" "$RED" "$R" ;;
          split) printf '  %s!%s %s%s%s%s%s · %s  %s与主出口不同%s\n' "$YEL" "$R" "$b_name" "$PAD" "$YEL" "$b_val" "$R" "${b_ms:-?}" "$YEL" "$R" ;;
          fail)  printf '  %s×%s %s%s%s连接失败%s  %s(%s)%s\n' "$RED" "$R" "$b_name" "$PAD" "$RED" "$R" "$DIM" "$b_val" "$R" ;;
        esac
      done < "$TMP/ext_bad"
    fi
  fi

  SCORE_SECTION='[06]'
fi

# ==============================================================================
# 最终阶段：出口 IP 基础分
# ==============================================================================

score_color() {
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$DIM"; return ;;
  esac
  if [ "$1" -ge 85 ]; then printf '%s' "$GRN"
  elif [ "$1" -ge 50 ]; then printf '%s' "$YEL"
  else printf '%s' "$RED"
  fi
}

SCORE_V4=''; SCORE_V4_LABEL=''; SCORE_V6=''; SCORE_V6_LABEL=''
if [ -z "$TARGET_IP" ] && [ -n "$IP4" ] && [ -n "$IP6" ] && [ -s "$TMP/p_v4" ] && [ -s "$TMP/p_v6" ]; then
  SCORE_V4_O=$(json_scope "$(cat "$TMP/p_v4")" score)
  SCORE_V4=$(json_num "$SCORE_V4_O" environmentScore)
  SCORE_V4_LABEL=$(json_str "$SCORE_V4_O" levelLabel)
  SCORE_V6_O=$(json_scope "$(cat "$TMP/p_v6")" score)
  SCORE_V6=$(json_num "$SCORE_V6_O" environmentScore)
  SCORE_V6_LABEL=$(json_str "$SCORE_V6_O" levelLabel)
  case "$SCORE_V4:$SCORE_V6" in
    *[!0-9:]*) ;;
    *)
      if [ -n "$SCORE_V4" ] && [ -n "$SCORE_V6" ] && [ "$SCORE_IP" = "$IP6" ] && [ $(( SCORE_V4 - SCORE_V6 )) -ge 10 ]; then
        add_advice "IPv4 出口基础分更高（$SCORE_V4 vs $SCORE_V6）→ 若作代理落地建议优先走 IPv4"
      fi
      ;;
  esac
fi

ADVICE_N=0
[ -s "$TMP/advice" ] && ADVICE_N=$(wc -l < "$TMP/advice" | tr -d ' ')

# 出口 IP 基础分只评估出口 IP 本身；终端侧协同问题（时区、漏代理、中转等）单独汇总，不计入此分
print_terminal_check() {
  [ -n "$TARGET_IP" ] && return
  if [ "$ADVICE_N" -gt 0 ]; then
    printf '  %s终端协同%s    %s! %s 项需关注（见 [07]，未计入此基础分）%s\n' "$DIM" "$R" "$YEL" "$ADVICE_N" "$R"
  else
    printf '  %s终端协同%s    %s✓ 未见终端侧问题%s\n' "$DIM" "$R" "$GRN" "$R"
  fi
}

SCORE_O=$(json_scope "$SCORE_JSON" score)
SCORE=$(json_num "$SCORE_O" environmentScore)
SCORE_LABEL=$(json_str "$SCORE_O" levelLabel)
PURITY_URL=''
[ -n "${SCORE_IP:-}" ] && PURITY_URL="$WEB_BASE/ip/$SCORE_IP"

printf '\n  %s%s 出口 IP 基础分%s\n\n' "$TITLE" "$SCORE_SECTION" "$R"

if [ -n "$SCORE" ]; then
  SC=$(score_color "$SCORE")

  printf '  %s出口 IP 基础分%s  %s%s%s %s/ 100%s   %s%s%s\n' \
    "$B" "$R" "$SC$B" "$SCORE" "$R" "$DIM" "$R" "$SC" "$SCORE_LABEL" "$R"
  [ -n "$SCORE_IP" ] && printf '  %s计分对象%s    %s\n' "$DIM" "$R" "$SCORE_IP"
  if [ -n "$SCORE_V4" ] && [ -n "$SCORE_V6" ]; then
    SC4=$(score_color "$SCORE_V4")
    SC6=$(score_color "$SCORE_V6")
    printf '  %s双栈基础分%s  IPv4 %s%s/100 %s%s (%s)  |  IPv6 %s%s/100 %s%s (%s)\n' \
      "$DIM" "$R" \
      "$SC4$B" "$SCORE_V4" "$SCORE_V4_LABEL" "$R" "$IP4" \
      "$SC6$B" "$SCORE_V6" "$SCORE_V6_LABEL" "$R" "$IP6"
  fi
  print_terminal_check
  [ -z "$TARGET_IP" ] && printf '  %s口径说明%s    %s仅评出口 IP 质素（身份/地区一致性/信誉）；含中转与浏览器协同的综合环境分见 %s%s\n' \
    "$DIM" "$R" "$DIM" "$WEB_BASE" "$R"
  [ -n "$PURITY_URL" ] && printf '  %s深度档案%s    %s%s（0–100 纯净度、双层归属穿透与 10 家 DNSBL 明细）%s\n' \
    "$DIM" "$R" "$PURITY_URL" "$DIM" "$R"
  if [ -z "$TARGET_IP" ] && [ -n "$IP4" ] && [ "$SCORE_IP" != "$IP4" ]; then
    printf '  %sIPv4 档案%s   %s/ip/%s\n' "$DIM" "$R" "$WEB_BASE" "$IP4"
  fi

  DEDUCTIONS=$(json_list "$SCORE_O" deductions)
  if [ -n "$DEDUCTIONS" ]; then
    printf '\n'
    printf '%s\n' "$DEDUCTIONS" | while read -r reason; do
      [ -n "$reason" ] && printf '  · %s\n' "$reason"
    done
  fi
else
  printf '  %s出口 IP 基础分暂时无法计算，请稍后重试。%s\n' "$YEL" "$R"
fi

if [ -z "$TARGET_IP" ]; then
  printf '\n  %s[07] 处理建议%s\n' "$TITLE" "$R"
  if [ "$ADVICE_N" -gt 0 ]; then
    while IFS= read -r adv; do
      printf '  %s!%s %s\n' "$YEL" "$R" "$adv"
    done < "$TMP/advice"
  else
    printf '  %s✓ 无需处理%s\n' "$GRN" "$R"
  fi
fi

[ -n "${p_stat:-}" ] && wait "$p_stat" 2>/dev/null || true
SH_STATS_JSON=$(cat "$TMP/sh_stats" 2>/dev/null || echo '')
SH_TOTAL=$(json_num "$SH_STATS_JSON" total)
SH_TODAY=$(json_num "$SH_STATS_JSON" today)
case "$SH_TOTAL" in ''|*[!0-9]*) SH_TOTAL='' ;; esac
case "$SH_TODAY" in ''|*[!0-9]*) SH_TODAY='' ;; esac

# ---------- 汇总 JSON 构造、脱敏短链与论坛 Markdown ----------

build_cli_report_json() {
  bcr_mask="$1"
  bcr_elapsed="$2"
  bcr_share_url="${3:-}"

  bcr_target="${TARGET_IP:-}"
  bcr_ip4="${IP4:-}"
  bcr_ip6="${IP6:-}"
  bcr_ai_exit="${AI_EXIT:-}"
  bcr_dom="${DOMESTIC_IP:-}"
  bcr_score_ip="${SCORE_IP:-}"
  bcr_purity_url="${PURITY_URL:-}"
  if [ "$bcr_mask" -eq 1 ]; then
    bcr_target=$(mask_ip_sh "$bcr_target")
    bcr_ip4=$(mask_ip_sh "$bcr_ip4")
    bcr_ip6=$(mask_ip_sh "$bcr_ip6")
    bcr_ai_exit=$(mask_ip_sh "$bcr_ai_exit")
    bcr_dom=$(mask_ip_sh "$bcr_dom")
    bcr_score_ip=$(mask_ip_sh "$bcr_score_ip")
    bcr_purity_url="$WEB_BASE/ip"
  fi

  j_geo=$(json_scope "$SCORE_JSON" geo)
  j_country=$(json_str "$j_geo" countryNameZh)
  [ -z "$j_country" ] && j_country=$(json_str "$j_geo" countryName)
  j_region=$(json_str "$j_geo" regionNameZh)
  [ -z "$j_region" ] && j_region=$(json_str "$j_geo" region)
  j_asn_o=$(json_scope "$SCORE_JSON" asn)
  j_asn=$(json_num "$j_asn_o" asn)
  j_asname=$(json_str "$j_asn_o" asName)
  j_iptype=$(json_str "$(json_scope "$SCORE_JSON" networkProfile)" ipTypeLabel)
  j_dual=$(json_str "$SCORE_JSON" dualIspLabel)
  j_risk_o=$(json_scope "$SCORE_JSON" riskProfile)
  j_risk=$(json_str "$j_risk_o" riskLevelLabel)
  [ -z "$j_risk" ] && j_risk=$(json_str "$j_risk_o" proxyTypeLabel)

  j_ai='[]'
  if [ -z "$TARGET_IP" ]; then
    j_ai_items=$(core_ai_lines | {
      first_ai=1
      while IFS='|' read -r c_id c_name c_web _ah _au _ex; do
        api_st='fail'; api_code=''; api_ms=''; w_ip=''; a_ip=''
        [ -f "$TMP/core_api_$c_id" ] && IFS='|' read -r api_st api_code api_ms _ar _ab < "$TMP/core_api_$c_id"
        [ -f "$TMP/core_web_$c_id" ] && IFS='|' read -r _wc w_ip _wcol _wms _wr < "$TMP/core_web_$c_id"
        [ -f "$TMP/core_api_tr_$c_id" ] && IFS='|' read -r _ac a_ip _acol _ams _ar2 < "$TMP/core_api_tr_$c_id"
        if [ "$bcr_mask" -eq 1 ]; then
          w_ip=$(mask_ip_sh "$w_ip")
          a_ip=$(mask_ip_sh "$a_ip")
        fi
        official_of "$c_id"
        lat_num="${api_ms%ms}"
        [ "$first_ai" -eq 1 ] && first_ai=0 || printf ','
        printf '{"id":%s,"name":%s,"api":%s,"httpCode":%s,"latencyMs":%s,"webIp":%s,"apiIp":%s,"official":%s}' \
          "$(jstr "$c_id")" "$(jstr "$c_name")" "$(jstr "$api_st")" "$(jstr "$api_code")" \
          "$(jnum "$lat_num")" "$(jstr "$w_ip")" "$(jstr "$a_ip")" "$(jstr "$OFF_STATE")"
      done
    })
    j_ai="[$j_ai_items]"
  fi

  j_v6leak='null'
  if [ -z "$TARGET_IP" ]; then
    v6l_ip=''; v6l_loc=''
    IFS='|' read -r v6l_ip v6l_loc < "$TMP/v6_leak" 2>/dev/null
    case "$v6l_ip" in *:*) ;; *) v6l_ip='' ;; esac
    if [ -n "$v6l_ip" ]; then
      [ "$bcr_mask" -eq 1 ] && v6l_ip=$(mask_ip_sh "$v6l_ip")
      j_v6leak=$(printf '{"ip":%s,"country":%s}' "$(jstr "$v6l_ip")" "$(jstr "$v6l_loc")")
    fi
  fi

  j_deds='[]'
  j_ded_raw=$(json_list "$SCORE_O" deductions)
  if [ -n "$j_ded_raw" ]; then
    j_ded_items=$(printf '%s\n' "$j_ded_raw" | {
      first_d=1
      while IFS= read -r reason; do
        [ -n "$reason" ] || continue
        [ "$first_d" -eq 1 ] && first_d=0 || printf ','
        jstr "$reason"
      done
    })
    j_deds="[$j_ded_items]"
  fi

  j_adv='[]'
  if [ -z "$TARGET_IP" ] && [ -s "$TMP/advice" ]; then
    j_adv_items=$({
      first_a=1
      while IFS= read -r adv; do
        [ -n "$adv" ] || continue
        [ "$first_a" -eq 1 ] && first_a=0 || printf ','
        jstr "$adv"
      done < "$TMP/advice"
    })
    j_adv="[$j_adv_items]"
  fi

  j_stats='null'
  if [ -n "$SH_TOTAL" ] && [ -n "$SH_TODAY" ]; then
    j_stats=$(printf '{"total":%s,"today":%s}' "$(jnum "$SH_TOTAL")" "$(jnum "$SH_TODAY")")
  fi

  printf '{"tool":"ipforai-check","version":%s,"startedAt":%s,"elapsedSec":%s,"target":%s,"exits":{"ipv4":%s,"ipv6":%s,"aiExit":%s,"domestic":%s},"profile":{"ip":%s,"country":%s,"region":%s,"asn":%s,"asName":%s,"ipType":%s,"dualIsp":%s,"risk":%s},"ai":%s,"ipv6Leak":%s,"score":{"value":%s,"label":%s,"deductions":%s},"advice":%s,"report":%s,"purityReport":%s,"shareUrl":%s,"stats":%s}\n' \
    "$(jstr "$SCRIPT_VERSION")" "$(jstr "$CHECK_STARTED_AT")" "$(jnum "$bcr_elapsed")" \
    "$(jstr "$bcr_target")" \
    "$(jstr "$bcr_ip4")" "$(jstr "$bcr_ip6")" "$(jstr "$bcr_ai_exit")" "$(jstr "$bcr_dom")" \
    "$(jstr "$bcr_score_ip")" "$(jstr "$j_country")" "$(jstr "$j_region")" "$(jnum "$j_asn")" \
    "$(jstr "$j_asname")" "$(jstr "$j_iptype")" "$(jstr "$j_dual")" "$(jstr "$j_risk")" \
    "$j_ai" "$j_v6leak" \
    "$(jnum "${SCORE:-}")" "$(jstr "${SCORE_LABEL:-}")" "$j_deds" \
    "$j_adv" "$(jstr "$WEB_BASE")" "$(jstr "$bcr_purity_url")" "$(jstr "$bcr_share_url")" "$j_stats"
}

SHARE_URL=''
maybe_upload_share_report() {
  mus_elapsed="$1"
  DO_SHARE=0
  if [ "$SHARE_MODE" = "yes" ]; then
    DO_SHARE=1
  elif [ "$SHARE_MODE" = "auto" ] && [ "$OUT_MODE" != "json" ]; then
    DO_SHARE=1
  fi
  [ "${IPFORAI_NO_SHARE:-}" = "1" ] && DO_SHARE=0
  [ "$DO_SHARE" -eq 1 ] || return 0

  mus_payload=$(build_cli_report_json 1 "$mus_elapsed" '')
  mus_resp=$(curl -fsS -m 3 -H 'Content-Type: application/json' -d "$mus_payload" "$API_BASE/api/cli-reports" 2>/dev/null || echo '')
  mus_id=$(json_str "$mus_resp" id)
  if [ -n "$mus_id" ]; then
    SHARE_URL="$WEB_BASE/r/$mus_id"
  fi
}

format_md_ai_summary() {
  core_ai_lines | {
    first_m=1
    while IFS='|' read -r c_id c_name _w _ah _au _ex; do
      api_st='fail'; api_ms=''
      [ -f "$TMP/core_api_$c_id" ] && IFS='|' read -r api_st _ac api_ms _ar _ab < "$TMP/core_api_$c_id"
      case "$api_st" in
        ok) m_txt="$c_name ✓${api_ms:+ $api_ms}" ;;
        review) m_txt="$c_name !" ;;
        *) m_txt="$c_name ×" ;;
      esac
      [ "$first_m" -eq 1 ] && first_m=0 || printf ' / '
      printf '%s' "$m_txt"
    done
  }
}

print_forum_markdown() {
  pfm_share="$1"
  pfm_geo=$(json_scope "$SCORE_JSON" geo)
  pfm_country=$(json_str "$pfm_geo" countryNameZh)
  [ -z "$pfm_country" ] && pfm_country=$(json_str "$pfm_geo" countryName)
  pfm_asn_o=$(json_scope "$SCORE_JSON" asn)
  pfm_asn=$(json_num "$pfm_asn_o" asn)
  pfm_asname=$(json_str "$pfm_asn_o" asName)
  pfm_iptype=$(json_str "$(json_scope "$SCORE_JSON" networkProfile)" ipTypeLabel)
  pfm_dual=$(json_str "$SCORE_JSON" dualIspLabel)
  pfm_ip_masked=$(mask_ip_sh "${SCORE_IP:-}")

  printf '\n  %s─── 论坛 Markdown 体检表（可直接复制） ───%s\n\n' "$DIM" "$R"
  printf '| 检测项 | 结果 |\n| --- | --- |\n'
  printf '| 脱敏出口 | `%s` (%s) |\n' "${pfm_ip_masked:-未知}" "${pfm_country:-未知}"
  [ -n "$pfm_asn" ] && printf '| 归属 ASN | AS%s · %s |\n' "$pfm_asn" "${pfm_asname:-未知}"
  printf '| 网络属性 | %s%s |\n' "${pfm_iptype:-未知}" "${pfm_dual:+ · $pfm_dual}"
  [ -n "${SCORE:-}" ] && printf '| 出口基础分 | %s / 100（%s） |\n' "$SCORE" "${SCORE_LABEL:-}"
  if [ -z "$TARGET_IP" ]; then
    pfm_ai=$(format_md_ai_summary)
    printf '| AI 连通 | %s |\n' "$pfm_ai"
  fi
  printf '\n> [查看完整脱敏检测报告](%s) · [IP for AI](%s)\n\n' "${pfm_share:-$WEB_BASE}" "$WEB_BASE"
}

CHECK_FINISHED_EPOCH=$(date +%s 2>/dev/null || echo '')
CHECK_ELAPSED=''
if [ -n "$CHECK_STARTED_EPOCH" ] && [ -n "$CHECK_FINISHED_EPOCH" ]; then
  CHECK_ELAPSED=$((CHECK_FINISHED_EPOCH - CHECK_STARTED_EPOCH))
fi

maybe_upload_share_report "$CHECK_ELAPSED"

if [ -n "$CHECK_ELAPSED" ]; then
  printf '\n  %s本次耗时%s  %s 秒  %s（加 -d 查看扩展 AI 工具 · -m 输出论坛 Markdown）%s\n' "$DIM" "$R" "$CHECK_ELAPSED" "$DIM" "$R"
else
  printf '\n'
fi
printf '  %s────────────────────────────────────────────────────────%s\n' "$DIM" "$R"
[ -n "$SHARE_URL" ] && printf '  %s分享短链%s  %s %s（已脱敏 · 7 天有效）%s\n' "$DIM" "$R" "$SHARE_URL" "$DIM" "$R"
printf '  %sIP 纯净度%s %s\n' "$DIM" "$R" "${PURITY_URL:-$WEB_BASE/ip}"
printf '  %s网页体检%s  %s\n' "$DIM" "$R" "$WEB_BASE"
if [ -n "$SH_TOTAL" ] && [ -n "$SH_TODAY" ]; then
  printf '  %s终端累计%s  %s 次 · 今日 %s 次\n' "$DIM" "$R" "$(fmt_int "$SH_TOTAL")" "$(fmt_int "$SH_TODAY")"
fi
printf '\n'
[ "$OUT_MODE" = full ] && [ "$PRINT_MD" -eq 1 ] && print_forum_markdown "$SHARE_URL"

if [ "$OUT_MODE" != full ]; then
  exec 1>&3 3>&-

  OUT_FINISHED_EPOCH=$(date +%s 2>/dev/null || echo '')
  OUT_ELAPSED="$CHECK_ELAPSED"
  if [ -n "$CHECK_STARTED_EPOCH" ] && [ -n "$OUT_FINISHED_EPOCH" ]; then
    OUT_ELAPSED=$(( OUT_FINISHED_EPOCH - CHECK_STARTED_EPOCH ))
  fi

  if [ "$OUT_MODE" = summary ]; then
    printf '\n  %sipforai 终端守门员%s %s%s · 摘要 · %s%s\n' \
      "$TITLE" "$R" "$DIM" "$SCRIPT_VERSION" "$CHECK_STARTED_AT" "$R"
    [ -n "$IP4" ] && print_card IPv4 "$IP4"
    [ -n "$IP6" ] && print_card IPv6 "$IP6"

    if [ -z "$TARGET_IP" ]; then
      printf '\n  %sAI 可达%s   ' "$DIM" "$R"
      core_ai_lines | {
        sum_first=1
        while IFS='|' read -r c_id c_name _w _ah _au _ex; do
          api_st='fail'; api_ms=''
          [ -f "$TMP/core_api_$c_id" ] && IFS='|' read -r api_st _ac api_ms _ar _ab < "$TMP/core_api_$c_id"
          official_of "$c_id"
          case "$api_st" in
            ok)     s_mark="${GRN}✓${R}" ;;
            review) s_mark="${YEL}!${R}" ;;
            *)      s_mark="${RED}×${R}" ;;
          esac
          s_item="$s_mark $c_name"
          [ -n "$api_ms" ] && s_item="$s_item $api_ms"
          if [ "$OFF_STATE" = "blocked" ] || [ "$OFF_STATE" = "partial" ]; then
            s_item="$s_item（$OFF_NOTE）"
          fi
          if [ "$sum_first" -eq 1 ]; then
            printf '%s' "$s_item"
            sum_first=0
          else
            printf ' · %s' "$s_item"
          fi
        done
        printf '\n'
      }
    else
      printf '\n'
    fi

    if [ -n "${SCORE:-}" ]; then
      SC=$(score_color "$SCORE")
      if [ -n "$SCORE_V4" ] && [ -n "$SCORE_V6" ]; then
        printf '  %s基础分%s    %s%s%s %s/ 100%s  %s%s%s  %s（IPv4 %s · IPv6 %s）%s\n' \
          "$DIM" "$R" "$SC$B" "$SCORE" "$R" "$DIM" "$R" "$SC" "$SCORE_LABEL" "$R" "$DIM" "$SCORE_V4" "$SCORE_V6" "$R"
      else
        printf '  %s基础分%s    %s%s%s %s/ 100%s  %s%s%s\n' \
          "$DIM" "$R" "$SC$B" "$SCORE" "$R" "$DIM" "$R" "$SC" "$SCORE_LABEL" "$R"
      fi
    else
      printf '  %s基础分%s    %s暂时无法计算%s\n' "$DIM" "$R" "$YEL" "$R"
    fi

    if [ -z "$TARGET_IP" ]; then
      if [ "$ADVICE_N" -gt 0 ]; then
        printf '  %s待处理%s    %s%s 项%s\n' "$DIM" "$R" "$YEL" "$ADVICE_N" "$R"
        adv_i=0
        while IFS= read -r adv; do
          adv_i=$(( adv_i + 1 ))
          [ "$adv_i" -le 5 ] && printf '            %s!%s %s\n' "$YEL" "$R" "$adv"
        done < "$TMP/advice"
        [ "$ADVICE_N" -gt 5 ] && printf '            %s另有 %s 项%s\n' "$DIM" "$(( ADVICE_N - 5 ))" "$R"
      else
        printf '  %s待处理%s    %s✓ 无需处理%s\n' "$DIM" "$R" "$GRN" "$R"
      fi
    fi

    [ -n "$SHARE_URL" ] && printf '  %s分享短链：%s（已脱敏 · 7 天有效）%s\n' "$DIM" "$SHARE_URL" "$R"
    printf '  %sIP 纯净度：%s · 网页体检：%s%s\n' "$DIM" "${PURITY_URL:-$WEB_BASE/ip}" "$WEB_BASE" "$R"
    if [ -n "$SH_TOTAL" ] && [ -n "$SH_TODAY" ]; then
      printf '  %s终端累计：%s 次 · 今日 %s 次 · 去掉 -s 查看完整明细%s\n\n' "$DIM" "$(fmt_int "$SH_TOTAL")" "$(fmt_int "$SH_TODAY")" "$R"
    else
      printf '  %s完整明细：去掉 -s 重跑%s\n\n' "$DIM" "$R"
    fi
    if [ "$PRINT_MD" -eq 1 ]; then print_forum_markdown "$SHARE_URL"; fi
  elif [ "$OUT_MODE" = json ]; then
    build_cli_report_json 0 "$OUT_ELAPSED" "$SHARE_URL"
  fi
fi
