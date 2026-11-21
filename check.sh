#!/bin/sh
# ipforai 终端守门员（分段流式网络与分流检测）
# 官方入口：https://ipforai.cc/sh
#
# 快捷（会直接执行远端脚本，请先确认信任来源）：
#   curl -fsSL https://ipforai.cc/sh | sh
#   curl -fsSL https://ipforai.cc/sh | sh -s -- 8.8.8.8
#   curl -fsSL https://ipforai.cc/sh | sh -s -- -y
#   curl -fsSL https://ipforai.cc/sh | sh -s -- -d
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
#   - 出口画像、环境质量分与网页共用后端 API；脚本不本地改写评分规则
#   - 指定 IP 时只查询该 IP 的画像与环境质量分，不把本机链路结果当成该 IP 的连通性
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
SCRIPT_VERSION="v3.3"
CHECK_STARTED_AT=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '未知')
CHECK_STARTED_EPOCH=$(date +%s 2>/dev/null || echo '')
LOCAL_ZONE=$(date +%Z 2>/dev/null || echo '未知')
LOCAL_UTC_OFFSET=$(date +%z 2>/dev/null || echo '')

# ---------- 参数 ----------

ASSUME_YES=0
DETAIL=0
TARGET_IP=""
TEST_IP="${IPFORAI_TEST_IP:-}"

for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -d|--detail) DETAIL=1 ;;
    -h|--help)
      printf 'ipforai 终端守门员  %s\n' "$SCRIPT_VERSION"
      printf '官方入口：https://ipforai.cc/sh\n\n'
      printf '用法：\n'
      printf '  curl -fsSL https://ipforai.cc/sh | sh -s -- [IP] [-y] [-d]\n'
      printf '  sh /tmp/ipforai-check.sh [IP] [-y] [-d]   # 先下载审阅后再执行\n\n'
      printf '参数：\n'
      printf '  IP    仅查询该 IP 的画像与环境质量分（不含本机链路 / 分流 / 遥测）\n'
      printf '  -y    跳过确认直接执行\n'
      printf '  -d    展开扩展 AI 工具分流表与 HTTP 状态详情\n\n'
      printf '环境变量：\n'
      printf '  IPFORAI_TEST_IP  本地 API 只返回回环地址时使用的测试出口\n\n'
      printf '说明：只读检测；分段流式输出；结果不代表账号结论。\n'
      exit 0
      ;;
    -*) printf '未知选项：%s\n' "$arg" >&2; exit 2 ;;
    *) TARGET_IP="$arg" ;;
  esac
done

# ---------- 配色 ----------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
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
json_num() { printf '%s' "$1" | sed -n "s/.*\"$2\":\(-\{0,1\}[0-9][0-9]*\(\.[0-9]*\)\{0,1\}\).*/\1/p"; }

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
    consumer_isp_likely:fixed_broadband) printf '%s' "$GRN" ;;
    datacenter_proxy:*|residential_proxy:*|vpn_proxy:*|tor_exit:*|public_proxy:*|web_proxy:*|privacy_network:*|enterprise_proxy:*|proxy_likely:*) printf '%s' "$RED" ;;
    datacenter_likely:*|network_infrastructure:*|search_engine_crawler:*|ai_crawler:*) printf '%s' "$YEL" ;;
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
        104.1[6-9].*|104.2[0-9].*|104.3[0-1].*|172.6[4-9].*|172.7[0-1].*|162.15[8-9].*|2606:4700:*) printf '官方接入 (Cloudflare)' ;;
      esac ;;
    chatgpt.com)
      case "$dot_ip" in
        104.1[6-9].*|104.2[0-9].*|104.3[0-1].*|172.6[4-9].*|172.7[0-1].*|162.15[8-9].*|2606:4700:*) printf '官方接入 (Cloudflare)' ;;
      esac ;;
    api.statsig.com)
      case "$dot_ip" in
        34.*|35.*|2600:1901:*) printf '官方接入 (Google Cloud)' ;;
        104.1[6-9].*|104.2[0-9].*|104.3[0-1].*|172.6[4-9].*|172.7[0-1].*|162.15[8-9].*|2606:4700:*) printf '官方接入 (Cloudflare)' ;;
      esac ;;
  esac
}

# ---------- 确认 ----------

if [ "$ASSUME_YES" -eq 0 ] && [ -e /dev/tty ] && [ -t 2 ]; then
  printf '%sipforai 终端守门员（只读 · 分段实时输出）%s\n' "$TITLE" "$R"
  if [ -n "$TARGET_IP" ]; then
    printf '%s将查询指定 IP 的公开画像与环境质量分；不修改本机配置，不需要 API key。%s\n' "$DIM" "$R"
  else
    printf '%s将分段检测：出口画像 → 网页/API 分流与耗时 → 双栈/IPv6 泄漏/DNS → 遥测域名 → TLS/TCP 延迟差 → 环境分 → 处理建议。%s\n' "$DIM" "$R"
    printf '%s不修改本机配置，不需要 API key；临时文件在结束后删除。%s\n' "$DIM" "$R"
  fi
  printf '按 Enter 继续 · Ctrl-C 取消 '
  read -r _ignored < /dev/tty 2>/dev/null || true
  printf '\n'
fi

TMP=$(mktemp -d 2>/dev/null) || { printf '无法创建临时目录\n' >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
trap '[ -t 1 ] && printf "\r\033[2K"; rm -rf "$TMP"; exit 130' INT TERM

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

printf '\n  %sipforai 终端守门员%s  %s%s%s\n' "$TITLE" "$R" "$DIM" "$SCRIPT_VERSION" "$R"
printf '  %s%s%s\n' "$DIM" '────────────────────────────────────────────────────────' "$R"
printf '  %s报告时间%s  %s · %s%s\n' "$DIM" "$R" "$CHECK_STARTED_AT" "$LOCAL_ZONE" "${LOCAL_UTC_OFFSET:+ (UTC$LOCAL_UTC_OFFSET)}"
printf '  %s系统环境%s  %s · %s · curl %s\n' "$DIM" "$R" "$OS_LABEL" "$OS_ARCH" "${CURL_VER:-?}"
if [ -n "$PROXY_SET" ]; then
  printf '  %s代理变量%s  %s已设置 HTTPS_PROXY / ALL_PROXY（已脱敏）%s\n' "$DIM" "$R" "$GRN" "$R"
else
  printf '  %s代理变量%s  未设置代理环境变量（若开 TUN 透明代理则由系统接管）\n' "$DIM" "$R"
fi
[ "$DETAIL" -eq 1 ] && [ -n "$NO_PROXY_SET" ] && printf '  %sNO_PROXY%s  %s\n' "$DIM" "$R" "$NO_PROXY_SET"

# NO_PROXY 里含 AI 域名（或 *）时，读代理变量的程序访问这些域名也会直连
if [ -n "$PROXY_SET" ] && [ -n "$NO_PROXY_SET" ]; then
  NO_PROXY_HIT=$(printf '%s' "$NO_PROXY_SET" | tr ',' '\n' | tr '[:upper:]' '[:lower:]' | awk '
    function ends(s, t) { return length(s) > length(t) && substr(s, length(s) - length(t) + 1) == t }
    BEGIN { n = split("anthropic.com claude.ai claude.com openai.com chatgpt.com googleapis.com gemini.google.com x.ai grok.com statsig.com", d, " ") }
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
for base_var in ANTHROPIC_BASE_URL OPENAI_BASE_URL; do
  eval "base_val=\${$base_var:-}"
  [ -z "$base_val" ] && continue
  base_host=$(printf '%s' "$base_val" | sed -e 's|^[A-Za-z][A-Za-z0-9+.-]*://||' -e 's|[/?#].*||' -e 's|.*@||' -e 's|:[0-9]*$||')
  case "$base_host" in
    api.anthropic.com|api.openai.com) ;;
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

( fetch "$V4_BASE/api/ip-profile/echo" > "$TMP/echo4" 2>/dev/null ) & p_e4=$!
( fetch "$API_BASE/api/ip-profile/echo" > "$TMP/echo_main" 2>/dev/null ) & p_em=$!
spin_wait "正在识别公网出口" "$p_e4" "$p_em"

IP4=$(json_str "$(cat "$TMP/echo4" 2>/dev/null)" ip)
MAIN_JSON=$(cat "$TMP/echo_main" 2>/dev/null)
MAIN_IP=$(json_str "$MAIN_JSON" ip)
MAIN_FAM=$(json_str "$MAIN_JSON" addressFamily)

IP6=''
if [ "$MAIN_FAM" = "ipv6" ]; then
  IP6="$MAIN_IP"
elif [ -z "$IP4" ]; then
  IP4="$MAIN_IP"
fi

if [ -n "$IP4" ] && is_loopback_ip "$IP4"; then IP4=''; fi
if [ -n "$IP6" ] && is_loopback_ip "$IP6"; then IP6=''; fi

if [ -z "$TARGET_IP" ] && [ -z "$IP4" ] && [ -z "$IP6" ]; then
  if [ -n "$TEST_IP" ]; then
    TARGET_IP="$TEST_IP"
  else
    printf '  %s未能识别公网出口（收到回环地址或探测未返回有效 IP）。%s\n\n' "$YEL" "$R"
    exit 1
  fi
fi

if [ -n "$TARGET_IP" ]; then
  case "$TARGET_IP" in
    *:*) IP6="$TARGET_IP"; IP4='' ;;
    *)   IP4="$TARGET_IP"; IP6='' ;;
  esac
fi

p_pv4=''; p_pv6=''
if [ -n "$IP4" ]; then ( fetch "$API_BASE/api/ip-profile?ip=$IP4" > "$TMP/p_v4" 2>/dev/null ) & p_pv4=$!; fi
if [ -n "$IP6" ]; then ( fetch "$API_BASE/api/ip-profile?ip=$IP6" > "$TMP/p_v6" 2>/dev/null ) & p_pv6=$!; fi
spin_wait "正在查询出口画像" "$p_pv4" "$p_pv6"

if [ ! -s "$TMP/p_v4" ] && [ ! -s "$TMP/p_v6" ]; then
  printf '  %s未能获取 IP 画像，请稍后重试。%s\n\n' "$YEL" "$R"
  exit 1
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
}

if [ -n "$TARGET_IP" ]; then
  printf '  %s指定 IP 画像%s · 本机时区 %s (UTC%s) · 目标时区 %s\n' "$DIM" "$R" "${SYS_TZ:-未知}" "${UTC_OFF:-?}" "${IP_TZ:-未知}"
else
  if [ -n "$IP4" ] && [ -n "$IP6" ]; then
    printf '  %s双栈出口%s（IPv4 + IPv6）' "$DIM" "$R"
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

telemetry_targets() {
  cat <<'TELEM'
claude_statsig|Claude 遥测 (Statsig)|api.statsig.com|no|/
claude_console|Claude 控制台|platform.claude.com|yes|/cdn-cgi/trace
datadog_logs|Claude Code 日志 (Datadog)|http-intake.logs.datadoghq.com|no|/
sentry_ingest|异常上报 (Sentry)|sentry.io|no|/
openai_auth|OpenAI 登录鉴权|auth.openai.com|yes|/cdn-cgi/trace
openai_ab|ChatGPT 遥测 (AB)|ab.chatgpt.com|yes|/cdn-cgi/trace
google_oauth|Google / Gemini 鉴权|oauth2.googleapis.com|no|/
cf_turnstile|人机验证 (Turnstile)|challenges.cloudflare.com|yes|/cdn-cgi/trace
TELEM
}

extra_ai_routes() {
  cat <<'EXTRA'
perplexity|Perplexity|cloudflare|www.perplexity.ai
midjourney|Midjourney|cloudflare|midjourney.com
openrouter|OpenRouter|cloudflare|openrouter.ai
poe|Poe|cloudflare|poe.com
suno|Suno|cloudflare|suno.com
replicate|Replicate|cloudflare|replicate.com
bolt|Bolt|cloudflare|bolt.new
lovable|Lovable|cloudflare|lovable.dev
EXTRA
}

probe_cf_trace() {
  pct_domain="$1"; pct_out="$2"
  pct_res=$(curl -sS -m "$NET_TIMEOUT" -o "$pct_out.body" -w '%{http_code}|%{time_total}|%{remote_ip}' "https://$pct_domain/cdn-cgi/trace" 2>/dev/null)
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

# 核心服务探测：同时记录 DNS / TCP / TLS / TTFB 四段毫秒耗时
probe_core_line() {
  pcl_id="$1"; pcl_web="$2"; pcl_api_host="$3"; pcl_api_url="$4"; pcl_expect="$5"
  [ -n "$pcl_web" ] && probe_cf_trace "$pcl_web" "$TMP/core_web_$pcl_id" &
  [ -n "$pcl_api_host" ] && probe_cf_trace "$pcl_api_host" "$TMP/core_api_tr_$pcl_id" &
  (
    pcl_res=$(curl -s -m "$NET_TIMEOUT" -o /dev/null \
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
    pt_res=$(curl -sS -m "$NET_TIMEOUT" -o "$TMP/tel_$pt_id.body" -w '%{http_code}|%{time_total}|%{remote_ip}' "https://$pt_host$pt_path" 2>/dev/null)
    IFS='|' read -r pt_code pt_time pt_rem <<EOF
$pt_res
EOF
    if [ "$pt_code" -ge 200 ] 2>/dev/null && [ "$pt_code" -lt 300 ] 2>/dev/null; then
      pt_ip=$(sed -n 's/^ip=//p' "$TMP/tel_$pt_id.body" | head -n 1)
      pt_colo=$(sed -n 's/^colo=//p' "$TMP/tel_$pt_id.body" | head -n 1)
      valid_ip "$pt_ip" || pt_ip=''
    fi
  else
    pt_res=$(curl -s -m "$NET_TIMEOUT" -o /dev/null -w '%{http_code}|%{time_total}|%{remote_ip}' "https://$pt_host$pt_path" 2>/dev/null)
    IFS='|' read -r pt_code pt_time pt_rem <<EOF
$pt_res
EOF
  fi
  pt_ms=$(awk -v s="$pt_time" 'BEGIN { if (s ~ /^[0-9]+([.][0-9]+)?$/) printf "%.0fms", s * 1000 }')
  printf '%s|%s|%s|%s|%s\n' "$pt_code" "$pt_ip" "$pt_colo" "$pt_ms" "$pt_rem" > "$TMP/tel_res_$pt_id"
}

probe_tls_cert() {
  ptc_id="$1"; ptc_host="$2"
  curl -sS -vI -m "$NET_TIMEOUT" "https://$ptc_host/" -o /dev/null > /dev/null 2> "$TMP/tls_$ptc_id" || true
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
  extract_products "$1" > "$TMP/products"
  : > "$TMP/official"
  while read -r bo_line || [ -n "$bo_line" ]; do
    bo_sid=$(json_str "$bo_line" serviceId)
    [ -z "$bo_sid" ] && continue
    printf '%s|%s|%s\n' "$bo_sid" \
      "$(json_str "$bo_line" regionPolicyStatus)" \
      "$(json_str "$bo_line" regionPolicyLabel)" >> "$TMP/official"
  done < "$TMP/products"
}

OFF_STATE=''; OFF_NOTE=''
official_of() {
  of_all=0; of_no=0; of_un=0
  while IFS='|' read -r of_sid of_st _of_l; do
    [ "$of_sid" = "$1" ] || continue
    of_all=$(( of_all + 1 ))
    case "$of_st" in
      not_supported) of_no=$(( of_no + 1 )) ;;
      unknown)       of_un=$(( of_un + 1 )) ;;
    esac
  done < "$TMP/official"

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
  AI_CC=$(json_str "$(json_scope "$SCORE_JSON" geo)" countryCode)

  if [ -n "$DOMESTIC_IP" ]; then
    if [ -n "$AI_EXIT" ] && [ "$DOMESTIC_IP" != "$AI_EXIT" ]; then
      printf '  %s国内基线%s  %s  %s✓ 已与 AI 出口分流%s\n\n' "$DIM" "$R" "$DOMESTIC_IP" "$GRN" "$R"
    else
      printf '  %s国内基线%s  %s  %s! 与 AI 出口相同（未分流或全局代理）%s\n\n' "$DIM" "$R" "$DOMESTIC_IP" "$YEL" "$R"
    fi
  else
    printf '  %s国内基线%s  未读到\n\n' "$DIM" "$R"
  fi

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

    if [ -n "$c_web" ]; then
      web_show="${w_ip:-未读到}${w_colo:+ ($w_colo)}"
      api_show="${a_ip:-未读到}${a_colo:+ ($a_colo)}"
      if [ -n "$w_ip" ] && [ -n "$a_ip" ] && [ "$w_ip" != "$a_ip" ]; then
        printf '      网页：%s  |  API：%s%s%s  %s! 网页与 API 分裂%s\n' "$web_show" "$RED" "$api_show" "$R" "$RED" "$R"
        add_advice "$c_name 网页与 API 出口不同 → 让 $c_web 与 $c_api_h 走同一代理节点"
      elif [ -n "$DOMESTIC_IP" ] && [ "$DOMESTIC_IP" != "$AI_EXIT" ] && { [ "$w_ip" = "$DOMESTIC_IP" ] || [ "$a_ip" = "$DOMESTIC_IP" ]; }; then
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
    probe_forced_stack -4 claude.ai "$TMP/fs_v4_claude" & p_fs1=$!
    probe_forced_stack -6 claude.ai "$TMP/fs_v6_claude" & p_fs2=$!
    probe_forced_stack -4 api.anthropic.com "$TMP/fs_v4_api" & p_fs3=$!
    probe_forced_stack -6 api.anthropic.com "$TMP/fs_v6_api" & p_fs4=$!
  fi
  # IPv6 泄漏：绕过代理变量、用 IPv6 字面地址直连（不走 DNS），看原生 IPv6 从哪个国家出去
  (
    v6l_body=$(curl -sS -m 4 --noproxy '*' 'https://[2606:4700:4700::1111]/cdn-cgi/trace' 2>/dev/null)
    v6l_ip=$(printf '%s\n' "$v6l_body" | sed -n 's/^ip=//p' | head -n 1)
    v6l_loc=$(printf '%s\n' "$v6l_body" | sed -n 's/^loc=//p' | head -n 1)
    valid_ip "$v6l_ip" || v6l_ip=''
    printf '%s|%s\n' "$v6l_ip" "$v6l_loc" > "$TMP/v6_leak"
  ) & p_v6l=$!
  (
    for h in claude.ai api.anthropic.com chatgpt.com api.statsig.com; do
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
    printf '  %sclaude.ai%s          IPv4: %s  |  IPv6: %s\n' "$DIM" "$R" \
      "${v4_c:-不可达}${v4_cm:+ ($v4_cm)}" "${v6_c:-无/未通}${v6_cm:+ ($v6_cm)}"
    printf '  %sapi.anthropic.com%s  IPv4: %s  |  IPv6: %s\n' "$DIM" "$R" \
      "${v4_a:-不可达}${v4_am:+ ($v4_am)}" "${v6_a:-无/未通}${v6_am:+ ($v6_am)}"
  fi

  v6l_ip=''; v6l_loc=''
  IFS='|' read -r v6l_ip v6l_loc < "$TMP/v6_leak" 2>/dev/null
  case "$v6l_ip" in *:*) ;; *) v6l_ip='' ;; esac
  if [ -z "$v6l_ip" ]; then
    printf '  %sIPv6 直连%s   %s✓ 无原生 IPv6 出口%s\n' "$DIM" "$R" "$GRN" "$R"
  elif [ -n "$AI_CC" ] && [ "$v6l_loc" = "$AI_CC" ]; then
    printf '  %sIPv6 直连%s   %s✓ 已进代理（%s）%s\n' "$DIM" "$R" "$GRN" "$v6l_loc" "$R"
  elif [ -n "$PROXY_SET" ]; then
    # 代理变量模式下直连本来就不经代理（国内基线已体现），这里只说明有原生 IPv6
    printf '  %sIPv6 直连%s   %s (%s) · 本机有原生 IPv6，不读代理变量的程序会直连\n' "$DIM" "$R" "$v6l_ip" "${v6l_loc:-?}"
  else
    printf '  %sIPv6 直连%s   %s%s (%s)  ! 绕过代理直连%s\n' "$DIM" "$R" "$RED" "$v6l_ip" "${v6l_loc:-?}" "$R"
    add_advice "IPv6 流量绕过代理从 ${v6l_loc:-本地} 直连 → 在代理客户端开启 IPv6 接管，或关闭系统 IPv6"
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

  telemetry_targets | { while IFS='|' read -r t_id t_label t_host t_cf t_path; do
    probe_telemetry "$t_id" "$t_host" "$t_cf" "$t_path" &
  done; wait; } & p_tel=$!
  spin_wait "正在探测 8 个遥测与鉴权域名" "$p_tel"

  telemetry_targets | while IFS='|' read -r t_id t_label t_host t_cf t_path; do
    [ -f "$TMP/tel_res_$t_id" ] || continue
    IFS='|' read -r t_code t_ip t_colo t_ms t_rem < "$TMP/tel_res_$t_id"
    set_pad "$t_label" 28
    l_pad="$PAD"

    if [ -z "$t_code" ] || [ "$t_code" = "000" ]; then
      printf '  %s×%s %s%s%s连接失败%s  %s(%s)%s\n' "$RED" "$R" "$t_label" "$l_pad" "$RED" "$R" "$DIM" "$t_host" "$R"
      continue
    fi

    if [ -n "$t_ip" ]; then
      if [ -n "$DOMESTIC_IP" ] && [ "$t_ip" = "$DOMESTIC_IP" ] && [ "$DOMESTIC_IP" != "$AI_EXIT" ]; then
        printf '  %s!%s %s%s%s%s%s · %s  %s漏网直连国内%s\n' "$RED" "$R" "$t_label" "$l_pad" "$RED" "$t_ip" "$R" "${t_ms:-?}" "$RED" "$R"
        add_advice "$t_label 直连国内 → 在代理规则中加入 $t_host"
      elif [ -n "$AI_EXIT" ] && [ "$t_ip" != "$AI_EXIT" ]; then
        printf '  %s!%s %s%s%s%s%s · %s  %s与主出口不同%s\n' "$YEL" "$R" "$t_label" "$l_pad" "$YEL" "$t_ip" "$R" "${t_ms:-?}" "$YEL" "$R"
        add_advice "$t_label 出口与主出口不同 → 让 $t_host 与 AI 主域名走同一节点"
      else
        printf '  %s✓%s %s%s%s · %s  %s与主出口一致%s\n' "$GRN" "$R" "$t_label" "$l_pad" "$t_ip" "${t_ms:-?}" "$DIM" "$R"
      fi
    else
      if [ -n "$t_rem" ] && { is_loopback_ip "$t_rem" || is_fake_ip "$t_rem"; }; then
        printf '  %s✓%s %s%s可达 · %s  %s已进代理%s\n' "$GRN" "$R" "$t_label" "$l_pad" "${t_ms:-?}" "$DIM" "$R"
      else
        printf '  %s✓%s %s%s可达 · %s  %s出口未回显%s\n' "$GRN" "$R" "$t_label" "$l_pad" "${t_ms:-?}" "$DIM" "$R"
      fi
    fi
  done

  # ---------- 阶段 5：TLS 证书链 & 被动 TCP 首包 + 双端 RTT 延迟差 ----------
  printf '\n  %s[05] TLS 证书链、TCP 首包与双端 RTT 延迟差%s\n' "$TITLE" "$R"

  probe_tls_cert anthropic api.anthropic.com & p_tls1=$!
  probe_tls_cert openai api.openai.com & p_tls2=$!
  (
    # 单次 curl 调用复用同一条热连接：先拉 SYN 指纹与服务端 RTT，再连打 3 次 /ping 测终端热往返 RTT
    curl -sS -m "$NET_TIMEOUT" \
      -o "$TMP/tcp_probe" -w 'probe|%{http_code}|%{time_total}\n' "$V4_BASE/api/tcp-probe" \
      -o /dev/null -w 'ping1|%{http_code}|%{time_total}\n' "$V4_BASE/api/tcp-probe/ping?n=1" \
      -o /dev/null -w 'ping2|%{http_code}|%{time_total}\n' "$V4_BASE/api/tcp-probe/ping?n=2" \
      -o /dev/null -w 'ping3|%{http_code}|%{time_total}\n' "$V4_BASE/api/tcp-probe/ping?n=3" \
      > "$TMP/tcp_pings" 2>/dev/null || true
  ) & p_tcp=$!
  spin_wait "正在检测 TLS 证书链与 TCP 延迟差" "$p_tls1" "$p_tls2" "$p_tcp"

  for tls_pair in "anthropic|api.anthropic.com" "openai|api.openai.com"; do
    IFS='|' read -r tid thost <<EOF
$tls_pair
EOF
    [ -f "$TMP/tls_res_$tid" ] || continue
    IFS='|' read -r tver tiss < "$TMP/tls_res_$tid"
    set_pad "$thost" 20
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
    SYN_TTL=$(json_num "$SYN_O" ttl)
    SYN_INIT=$(json_num "$SYN_O" initialTtl)
    SYN_OPTS=$(json_str "$SYN_O" options)
    SYN_MSS=$(json_num "$SYN_O" mss)

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

    [ -n "$SYN_OS" ] && printf '  %sSYN 协议栈%s  %s · TTL %s/%s · MSS %s · 选项 %s\n' \
      "$DIM" "$R" "$SYN_OS" "${SYN_TTL:-?}" "${SYN_INIT:-?}" "${SYN_MSS:-?}" "${SYN_OPTS:-?}"

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
  else
    printf '  %sTCP 首包探针暂未连通，已跳过%s\n' "$DIM" "$R"
  fi

  # ---------- 扩展 AI 工具（-d 显示） ----------
  if [ "$DETAIL" -eq 1 ]; then
    printf '\n  %s[扩展] 其他 AI 工具分流出口（-d）%s\n' "$TITLE" "$R"
    extra_ai_routes | { while IFS='|' read -r e_id e_name e_mode e_host; do
      probe_cf_trace "$e_host" "$TMP/extra_$e_id" &
    done; wait; } & p_ext=$!
    spin_wait "正在探测扩展 AI 工具分流" "$p_ext"
    extra_ai_routes | while IFS='|' read -r e_id e_name e_mode e_host; do
      [ -f "$TMP/extra_$e_id" ] || continue
      IFS='|' read -r _ec e_ip e_colo e_ms _er < "$TMP/extra_$e_id"
      [ -n "$e_ip" ] || continue
      set_pad "$e_name" 14
      if [ -n "$AI_EXIT" ] && [ "$e_ip" != "$AI_EXIT" ]; then
        printf '  %s%s  %s%s%s · %s  %s与主出口不同%s\n' "$e_name" "$PAD" "$YEL" "$e_ip" "$R" "${e_ms:-?}" "$YEL" "$R"
      else
        printf '  %s%s  %s · %s\n' "$e_name" "$PAD" "$e_ip" "${e_ms:-?}"
      fi
    done
  fi

  SCORE_SECTION='[06]'
fi

# ==============================================================================
# 最终阶段：环境质量分
# ==============================================================================

ADVICE_N=0
[ -s "$TMP/advice" ] && ADVICE_N=$(wc -l < "$TMP/advice" | tr -d ' ')

# 环境分只评估出口 IP；终端侧问题（时区、漏代理、中转等）单独汇总，不计入分数
print_terminal_check() {
  [ -n "$TARGET_IP" ] && return
  if [ "$ADVICE_N" -gt 0 ]; then
    printf '  %s终端检查%s    %s! %s 项需处理（见 [07]，不计入环境分）%s\n' "$DIM" "$R" "$YEL" "$ADVICE_N" "$R"
  else
    printf '  %s终端检查%s    %s✓ 未见终端侧问题%s\n' "$DIM" "$R" "$GRN" "$R"
  fi
}

SCORE_O=$(json_scope "$SCORE_JSON" score)
SCORE=$(json_num "$SCORE_O" environmentScore)
SCORE_LABEL=$(json_str "$SCORE_O" levelLabel)

printf '\n  %s%s 环境质量分%s\n\n' "$TITLE" "$SCORE_SECTION" "$R"

if [ -n "$SCORE" ]; then
  if [ "$SCORE" -ge 85 ]; then SC="$GRN"
  elif [ "$SCORE" -ge 50 ]; then SC="$YEL"
  else SC="$RED"; fi

  printf '  %s环境质量分%s  %s%s%s %s/ 100%s   %s%s%s\n' \
    "$B" "$R" "$SC$B" "$SCORE" "$R" "$DIM" "$R" "$SC" "$SCORE_LABEL" "$R"
  [ -n "$SCORE_IP" ] && printf '  %s计分对象%s    %s\n' "$DIM" "$R" "$SCORE_IP"
  print_terminal_check

  DEDUCTIONS=$(json_list "$SCORE_O" deductions)
  if [ -n "$DEDUCTIONS" ]; then
    printf '\n'
    printf '%s\n' "$DEDUCTIONS" | while read -r reason; do
      [ -n "$reason" ] && printf '  · %s\n' "$reason"
    done
  fi
else
  printf '  %s环境质量分暂时无法计算，请稍后重试。%s\n' "$YEL" "$R"
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

CHECK_FINISHED_EPOCH=$(date +%s 2>/dev/null || echo '')
if [ -n "$CHECK_STARTED_EPOCH" ] && [ -n "$CHECK_FINISHED_EPOCH" ]; then
  CHECK_ELAPSED=$((CHECK_FINISHED_EPOCH - CHECK_STARTED_EPOCH))
  printf '\n  %s本次耗时%s  %s 秒  %s（加 -d 查看扩展 AI 工具与 HTTP 状态）%s\n' "$DIM" "$R" "$CHECK_ELAPSED" "$DIM" "$R"
fi
printf '\n'
