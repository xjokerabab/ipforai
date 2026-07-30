#!/bin/sh
# ipforai 网络检测
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
#   - 会向 ipforai.cc（及 v4-probe）拉取公开 IP 画像；本机出口模式下还会探测多个 AI / 厂商域名
#   - 出口画像、环境质量分与网页共用后端 API；脚本不本地改写评分规则
#   - AI 服务连通 / 分流探测端点清单维护在本脚本内，与浏览器页探测方式可能不同
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
SCRIPT_VERSION="v2.1"
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
      printf 'ipforai 网络检测  %s\n' "$SCRIPT_VERSION"
      printf '官方入口：https://ipforai.cc/sh\n\n'
      printf '用法：\n'
      printf '  curl -fsSL https://ipforai.cc/sh | sh -s -- [IP] [-y] [-d]\n'
      printf '  sh /tmp/ipforai-check.sh [IP] [-y] [-d]   # 先下载审阅后再执行\n\n'
      printf '参数：\n'
      printf '  IP    仅查询该 IP 的画像与环境质量分（不含本机 AI 链路 / 分流）\n'
      printf '  -y    跳过确认直接执行\n'
      printf '  -d    显示本机详情、服务 HTTP 状态等详细诊断\n\n'
      printf '环境变量：\n'
      printf '  IPFORAI_TEST_IP  本地 API 只返回回环地址时使用的测试出口\n\n'
      printf '说明：只读检测；画像与环境质量分来自后端 API；结果不代表账号结论。\n'
      printf '      省略 IP 时检测本机出口，并探测 AI 服务链路与分流（会访问第三方域名）。\n'
      exit 0
      ;;
    -*) printf '未知选项：%s\n' "$arg" >&2; exit 2 ;;
    *) TARGET_IP="$arg" ;;
  esac
done

# ---------- 配色 ----------
# 只在真正的终端上色；重定向到文件或管道时降级成纯文本，符号保留，信息不丢。

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  R=$(printf '\033[0m');   B=$(printf '\033[1m')
  DIM=$(printf '\033[2m'); GRN=$(printf '\033[32m')
  YEL=$(printf '\033[33m'); RED=$(printf '\033[31m')
else
  R=''; B=''; DIM=''; GRN=''; YEL=''; RED=''
fi

# ---------- JSON 取值 ----------
# 后端返回的是紧凑 JSON，且这些子对象内部没有嵌套花括号（数组元素都是字符串），
# 所以先用 "key":{...} 圈出子对象再取字段，避免同名 key 跨对象误匹配。

json_scope() { printf '%s' "$1" | sed -n "s/.*\"$2\":{\([^}]*\)}.*/\1/p"; }
json_str() { printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"; }
json_num() { printf '%s' "$1" | sed -n "s/.*\"$2\":\(-\{0,1\}[0-9][0-9]*\).*/\1/p"; }

# 取字符串数组里的元素，逐行输出
json_list() {
  printf '%s' "$1" | sed -n "s/.*\"$2\":\[\([^]]*\)\].*/\1/p" \
    | tr ',' '\n' | sed -n 's/^"\(.*\)"$/\1/p'
}

# aiAccessProfile.products 是对象数组，json_scope 只能圈单个对象，处理不了。
# 这里先整体切出数组，再按 },{ 拆成一行一个对象——products 里每个对象的字段都是
# 标量，没有嵌套花括号，拆完每行都能直接用 json_str。
# 全文 "products":[ 和 ],"summary" 各只出现一次，贪婪匹配在这里是安全的。
extract_products() {
  printf '%s' "$1" \
    | sed -n 's/.*"products":\[\(.*\)\],"summary".*/\1/p' \
    | sed 's/},{/}@{/g' | tr '@' '\n'
}

fetch() { curl -fsS -m "$NET_TIMEOUT" "$1" 2>/dev/null; }

is_loopback_ip() {
  case "$1" in
    127.*|::1|0:0:0:0:0:0:0:1) return 0 ;;
    *) return 1 ;;
  esac
}

# printf 的 %-Ns 按字节补位，中文一个字 3 字节会被当成 3 列，中英混排必然错位。
# 这里按显示宽度算补白。结果写进全局 PAD 而不是用 $(...)，因为命令替换会吃掉尾部空格。
# wc -m 在非 UTF-8 locale 下会退化成按字节数，不能用。这里数 UTF-8 三字节序列的
# 首字节（0xE0-0xEF），中日韩文字都在这个区间，占 3 字节显示 2 列，
# 所以显示宽度 = 总字节数 - 三字节序列个数。与 locale 无关。
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
  # 入参为 riskProfile.riskLevel；clean/low 偏绿，medium 黄，high 红。
  case "$1" in
    clean|low) printf '%s' "$GRN" ;;
    medium) printf '%s' "$YEL" ;;
    high) printf '%s' "$RED" ;;
    *) printf '%s' "$DIM" ;;
  esac
}

# 按地址族取本机对照出口，避免用 IPv6 主出口去和 IPv4 分流回显比「不一致」。
exit_for_family() {
  case "$1" in
    *:*) printf '%s' "${IP6:-}" ;;
    *) printf '%s' "${IP4:-}" ;;
  esac
}

is_ipv6_addr() {
  case "$1" in
    *:*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- 确认 ----------
# curl | sh 时 stdin 被管道占着，交互必须走 /dev/tty。

if [ "$ASSUME_YES" -eq 0 ] && [ -e /dev/tty ] && [ -t 2 ]; then
  printf '%sipforai 网络检测（只读）%s\n' "$B" "$R"
  if [ -n "$TARGET_IP" ]; then
    printf '%s将查询指定 IP 的公开画像与环境质量分；不修改本机配置，不需要 API key。%s\n' "$DIM" "$R"
  else
    printf '%s将请求 ipforai.cc 获取出口画像，并探测 AI 链路与分流（含第三方域名）。%s\n' "$DIM" "$R"
    printf '%s不修改本机配置，不需要 API key；临时文件在结束后删除。%s\n' "$DIM" "$R"
  fi
  printf '按 Enter 继续 · Ctrl-C 取消 '
  read -r _ignored < /dev/tty 2>/dev/null || true
  printf '\n'
fi

TMP=$(mktemp -d 2>/dev/null) || { printf '无法创建临时目录\n' >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT INT TERM

printf '\n  %sipforai 网络检测%s\n' "$B" "$R"
printf '  %s%s%s\n' "$DIM" '─────────────────────────────────────────────' "$R"
printf '  %s报告时间%s  %s · %s%s  %s%s%s\n' "$DIM" "$R" "$CHECK_STARTED_AT" "$LOCAL_ZONE" "${LOCAL_UTC_OFFSET:+ (UTC$LOCAL_UTC_OFFSET)}" "$DIM" "$SCRIPT_VERSION" "$R"
if [ -n "$TARGET_IP" ]; then
  printf '  %s检测范围%s  指定 IP 画像 · 环境质量分（不含本机链路 / 分流）\n' "$DIM" "$R"
else
  printf '  %s检测范围%s  本机出口画像 · AI 链路与分流探测 · 环境质量分\n' "$DIM" "$R"
fi

# ---------- 系统环境 ----------

OS_NAME=$(uname -s 2>/dev/null || echo unknown)
OS_REL=$(uname -r 2>/dev/null || echo '')
OS_ARCH=$(uname -m 2>/dev/null || echo '')
CURL_VER=$(curl --version 2>/dev/null | head -n 1 | cut -d' ' -f2)
OS_LABEL="$OS_NAME $OS_REL"
DEVICE_INFO=''
CPU_INFO=''
MEMORY_INFO=''
UPTIME_INFO=''
DEFAULT_INTERFACE=''

case "$OS_NAME" in
  Darwin)
    MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null || echo '')
    MACOS_BUILD=$(sw_vers -buildVersion 2>/dev/null || echo '')
    [ -n "$MACOS_VERSION" ] && OS_LABEL="macOS $MACOS_VERSION"
    [ -n "$MACOS_BUILD" ] && OS_LABEL="$OS_LABEL · $MACOS_BUILD"
    MAC_MODEL=$(sysctl -n hw.model 2>/dev/null || echo '')
    MAC_CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '')
    MAC_MEMORY=$(sysctl -n hw.memsize 2>/dev/null | awk '{ printf "%.0f GB", $1 / 1073741824 }')
    MAC_PHYSICAL_CPU=$(sysctl -n hw.physicalcpu 2>/dev/null || echo '')
    MAC_LOGICAL_CPU=$(sysctl -n hw.logicalcpu 2>/dev/null || echo '')
    DEVICE_INFO="$MAC_MODEL"
    CPU_INFO="$MAC_CHIP"
    [ -n "$MAC_PHYSICAL_CPU" ] && CPU_INFO="$CPU_INFO · ${MAC_PHYSICAL_CPU} 物理核"
    [ -n "$MAC_LOGICAL_CPU" ] && CPU_INFO="$CPU_INFO · ${MAC_LOGICAL_CPU} 逻辑核"
    MEMORY_INFO="$MAC_MEMORY"
    UPTIME_INFO=$(uptime 2>/dev/null | sed -n 's/.* up \(.*\), [0-9][0-9]* user.*/\1/p')
    DEFAULT_INTERFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
    ;;
  Linux)
    LINUX_NAME=$(awk -F= '$1 == "PRETTY_NAME" { gsub(/"/, "", $2); print $2; exit }' /etc/os-release 2>/dev/null)
    [ -n "$LINUX_NAME" ] && OS_LABEL="$LINUX_NAME"
    CPU_INFO="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo '')"
    [ -n "$CPU_INFO" ] && CPU_INFO="$CPU_INFO 逻辑核"
    MEMORY_INFO=$(awk '/MemTotal/{printf "%.0f GB", $2 / 1048576}' /proc/meminfo 2>/dev/null)
    UPTIME_INFO=$(uptime -p 2>/dev/null | sed 's/^up //')
    ;;
esac

PROXY_SET="${https_proxy:-${HTTPS_PROXY:-}}"

printf '\n  %s系统%s      %s · %s · curl %s\n' "$DIM" "$R" "$OS_LABEL" "$OS_ARCH" "${CURL_VER:-?}"
if [ -n "$PROXY_SET" ]; then
  printf '  %s代理环境%s  已设置 https_proxy / HTTPS_PROXY（已脱敏）\n' "$DIM" "$R"
else
  printf '  %s代理环境%s  未设置 https_proxy / HTTPS_PROXY\n' "$DIM" "$R"
fi
if [ "$DETAIL" -eq 1 ]; then
  [ -n "$DEVICE_INFO" ] && printf '  %s设备%s      %s\n' "$DIM" "$R" "$DEVICE_INFO"
  [ -n "$CPU_INFO" ] && printf '  %s处理器%s    %s\n' "$DIM" "$R" "$CPU_INFO"
  [ -n "$MEMORY_INFO" ] && printf '  %s内存%s      %s\n' "$DIM" "$R" "$MEMORY_INFO"
  [ -n "$UPTIME_INFO" ] && printf '  %s运行状态%s  已运行 %s\n' "$DIM" "$R" "$UPTIME_INFO"
  [ -n "$DEFAULT_INTERFACE" ] && printf '  %s默认接口%s  %s\n' "$DIM" "$R" "$DEFAULT_INTERFACE"
fi

# ---------- 出口探测 ----------
# v4-probe 是只有 A 记录的独立域名，哪怕挂着代理，代理也只能用 IPv4 连它，
# 所以这是有代理时唯一可靠的 IPv4 出口探测方式（curl -4 只作用于到代理的那一跳）。

( fetch "$V4_BASE/api/ip-profile/echo" > "$TMP/echo4" 2>/dev/null ) &
( fetch "$API_BASE/api/ip-profile/echo" > "$TMP/echo_main" 2>/dev/null ) &
wait

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
    printf '\n  %s未能识别公网出口（收到回环地址或探测未返回有效 IP）。%s\n' "$YEL" "$R"
    printf '  %s可在命令末尾指定 IP，或设置环境变量 IPFORAI_TEST_IP 后重试。%s\n\n' "$DIM" "$R"
    exit 1
  fi
fi

if [ -n "$TARGET_IP" ]; then
  case "$TARGET_IP" in
    *:*) IP6="$TARGET_IP"; IP4='' ;;
    *)   IP4="$TARGET_IP"; IP6='' ;;
  esac
fi

if [ -z "$IP4" ] && [ -z "$IP6" ]; then
  printf '\n  %s未能连接 ipforai.cc 或未取得出口 IP，请检查网络后重试。%s\n\n' "$RED" "$R"
  exit 1
fi

# ---------- 拉画像 ----------
# 逐个 IP 单独取。批量接口会把两份画像拼在一个字符串里，而 sed 的贪婪匹配
# 无法只圈住其中一份，取 geo 这类同名字段时会串到另一个 IP 上。

[ -n "$IP4" ] && ( fetch "$API_BASE/api/ip-profile?ip=$IP4" > "$TMP/p_v4" 2>/dev/null ) &
[ -n "$IP6" ] && ( fetch "$API_BASE/api/ip-profile?ip=$IP6" > "$TMP/p_v6" 2>/dev/null ) &
wait

if [ ! -s "$TMP/p_v4" ] && [ ! -s "$TMP/p_v6" ]; then
  printf '\n  %s未能获取 IP 画像，请稍后重试；若持续失败可指定 IP 或稍后再查。%s\n\n' "$YEL" "$R"
  exit 1
fi

profile_of() {
  if [ "$1" = "$IP6" ] && [ -s "$TMP/p_v6" ]; then
    cat "$TMP/p_v6"
  elif [ "$1" = "$IP4" ] && [ -s "$TMP/p_v4" ]; then
    cat "$TMP/p_v4"
  fi
}

# ---------- 时区与地区一致性 ----------

SYS_TZ=''
if [ -r /etc/timezone ]; then
  SYS_TZ=$(cat /etc/timezone 2>/dev/null)
elif [ -L /etc/localtime ]; then
  SYS_TZ=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
fi
[ -z "$SYS_TZ" ] && SYS_TZ="${TZ:-}"
UTC_OFF=$(date +%z 2>/dev/null)

# 展示与政策对照优先 IPv4（更贴近常见心智）；无 IPv4 时再用 IPv6。
PRIMARY_IP="${IP4:-$IP6}"
PRIMARY=$(profile_of "$PRIMARY_IP")
PGEO=$(json_scope "$PRIMARY" geo)
P_COUNTRY=$(json_str "$PGEO" countryName)
P_REGION=$(json_str "$PGEO" regionNameZh)
[ -z "$P_REGION" ] && P_REGION=$(json_str "$PGEO" region)
IP_TZ=$(json_str "$PGEO" timezone)

P_PLACE="$P_COUNTRY"
[ -n "$P_REGION" ] && P_PLACE="$P_PLACE $P_REGION"

print_tz_line() {
  ptz_label="$1"
  ptz_place="$2"
  ptz_ip_tz="$3"
  if [ -z "$ptz_ip_tz" ]; then
    printf '  %s%s%s  %s%s地区暂未定位 · 暂不判断时区%s\n' \
      "$DIM" "$ptz_label" "$R" "${ptz_place:+$ptz_place · }" "$DIM" "$R"
  elif [ -z "$SYS_TZ" ]; then
    printf '  %s%s%s  %s · %s系统时区未识别%s\n' \
      "$DIM" "$ptz_label" "$R" "$ptz_place" "$DIM" "$R"
  elif [ "$SYS_TZ" = "$ptz_ip_tz" ]; then
    printf '  %s%s%s  %s · %s✓ 时区一致%s\n' \
      "$DIM" "$ptz_label" "$R" "$ptz_place" "$GRN" "$R"
  else
    printf '  %s%s%s  %s · %s! 时区不一致%s\n' \
      "$DIM" "$ptz_label" "$R" "$ptz_place" "$YEL" "$R"
    printf '            %s系统 %s · 出口 %s%s\n' \
      "$DIM" "${SYS_TZ:-未知}" "$ptz_ip_tz" "$R"
  fi
}

# 查指定 IP 时，本机时区和该 IP 时区没有可比性；本机出口模式下再做一致性判断。
if [ -n "$TARGET_IP" ]; then
  printf '\n  %s本机时区%s  %s (UTC%s)\n' "$DIM" "$R" "${SYS_TZ:-未知}" "${UTC_OFF:-?}"
  printf '  %s目标时区%s  %s\n' "$DIM" "$R" "${IP_TZ:-未知}"
else
  printf '\n  %s系统时区%s  %s (UTC%s)\n' "$DIM" "$R" "${SYS_TZ:-未知}" "${UTC_OFF:-?}"
  if [ -n "$IP4" ] && [ -n "$IP6" ] && [ "$IP4" != "$IP6" ]; then
    P4=$(profile_of "$IP4")
    P4GEO=$(json_scope "$P4" geo)
    P4_PLACE=$(json_str "$P4GEO" countryName)
    P4_REG=$(json_str "$P4GEO" regionNameZh)
    [ -z "$P4_REG" ] && P4_REG=$(json_str "$P4GEO" region)
    [ -n "$P4_REG" ] && P4_PLACE="$P4_PLACE $P4_REG"
    P4_TZ=$(json_str "$P4GEO" timezone)
    print_tz_line "IPv4 地区" "$P4_PLACE" "$P4_TZ"

    P6=$(profile_of "$IP6")
    P6GEO=$(json_scope "$P6" geo)
    P6_PLACE=$(json_str "$P6GEO" countryName)
    P6_REG=$(json_str "$P6GEO" regionNameZh)
    [ -z "$P6_REG" ] && P6_REG=$(json_str "$P6GEO" region)
    [ -n "$P6_REG" ] && P6_PLACE="$P6_PLACE $P6_REG"
    P6_TZ=$(json_str "$P6GEO" timezone)
    print_tz_line "IPv6 地区" "$P6_PLACE" "$P6_TZ"
  else
    print_tz_line "出口地区" "$P_PLACE" "$IP_TZ"
  fi
fi

# ---------- 出口卡片 ----------

print_card() {
  card_fam="$1"; card_ip="$2"
  card_json=$(profile_of "$card_ip")
  [ -z "$card_json" ] && return

  card_geo=$(json_scope "$card_json" geo)
  card_country=$(json_str "$card_geo" countryName)
  card_region=$(json_str "$card_geo" regionNameZh)
  [ -z "$card_region" ] && card_region=$(json_str "$card_geo" region)
  card_city=$(json_str "$card_geo" city)

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
  [ -n "$card_city" ] && [ "$card_city" != "$card_region" ] && card_loc="$card_loc $card_city"

  printf '\n  %s%-5s%s %s\n' "$DIM" "$card_fam" "$R" "$card_ip"
  printf '        %s · AS%s %s\n' "$card_loc" "$card_asn" "$card_asname"
  if [ -n "$card_access" ] && [ "$card_access_key" != "unknown" ]; then
    printf '        网络：%s%s%s · 接入：%s · 路由：%s%s%s · 风险：%s%s%s\n' \
      "$(network_tone "$card_type_key" "$card_access_key")" "$card_type" "$R" \
      "$card_access" \
      "$(route_tone "$card_route_key")" "$card_route" "$R" \
      "$(risk_tone "$card_risk_key")" "$card_risk" "$R"
  else
    printf '        网络：%s%s%s · 路由：%s%s%s · 风险：%s%s%s\n' \
      "$(network_tone "$card_type_key" "$card_access_key")" "$card_type" "$R" \
      "$(route_tone "$card_route_key")" "$card_route" "$R" \
      "$(risk_tone "$card_risk_key")" "$card_risk" "$R"
  fi
}

printf '\n  %s[01] 出口总览%s\n' "$B" "$R"
if [ -n "$TARGET_IP" ]; then
  printf '  %s指定 IP 画像%s\n' "$DIM" "$R"
elif [ -n "$IP4" ] && [ -n "$IP6" ]; then
  printf '  %s检测到 IPv4 / IPv6 双栈出口%s\n' "$DIM" "$R"
else
  printf '  %s检测到单栈出口%s\n' "$DIM" "$R"
fi
[ -n "$IP4" ] && print_card IPv4 "$IP4"
[ -n "$IP6" ] && print_card IPv6 "$IP6"

# ---------- AI 服务清单 ----------
# 服务 id 与后端 /api/services 的花名册严格对齐，官方地区结论才 join 得上。
# trace_url 能拿到该服务实际看到的出口 IP；api_url 打官方 API 域名，
# 拿到的 401/403/405 是服务自己的业务错误，证明请求穿透到了应用层。
# expect_code 是实测过的「正常无 key」响应码，只有完全吻合才判可达。
# 不用后端那份 favicon 清单：那是给浏览器 <img> 探测设计的，curl 不跟跳转，
# 实测 DeepSeek 429、Kimi 302、通义 301、OpenAI 308、Gemini 404，判不出可达性。

ai_services() {
  cat <<'SERVICES'
chatgpt|ChatGPT|https://chat.openai.com/cdn-cgi/trace|https://api.openai.com/v1/models|401
claude|Claude|https://claude.ai/cdn-cgi/trace|https://api.anthropic.com/v1/messages|405
gemini|Gemini||https://generativelanguage.googleapis.com/v1beta/models|403
grok|Grok|https://grok.com/cdn-cgi/trace|https://api.x.ai/v1/models|401
deepseek|DeepSeek||https://api.deepseek.com/v1/models|401
kimi|Kimi||https://api.moonshot.cn/v1/models|401
qwen|通义千问||https://dashscope.aliyuncs.com/compatible-mode/v1/models|401
doubao|豆包||https://ark.cn-beijing.volces.com/api/v3/models|401
zhipu|智谱清言||https://open.bigmodel.cn/api/paas/v4/models|401
minimax|MiniMax||https://api.minimaxi.com/v1/files/list|200
mimo|Mimo||https://www.mimoai.chat/mimo_logo.png|200
SERVICES
}

ai_routing_services() {
  cat <<'SERVICES'
chatgpt|ChatGPT|cloudflare|chatgpt.com
openai|OpenAI|cloudflare|openai.com
sora|Sora|cloudflare|sora.com
claude|Claude|cloudflare|claude.ai
anthropic|Anthropic|cloudflare|anthropic.com
grok|Grok|cloudflare|grok.com
perplexity|Perplexity|cloudflare|www.perplexity.ai
midjourney|Midjourney|cloudflare|midjourney.com
poe|Poe|cloudflare|poe.com
character_ai|Character AI|cloudflare|character.ai
suno|Suno|cloudflare|suno.com
leonardo|Leonardo AI|cloudflare|leonardo.ai
pi|Pi|cloudflare|pi.ai
phind|Phind|cloudflare|www.phind.com
bolt|Bolt|cloudflare|bolt.new
lovable|Lovable|cloudflare|lovable.dev
pixpix|PixPix|cloudflare|pixpix.com
pixverse|PixVerse|cloudflare|pixverse.ai
synthesia|Synthesia|cloudflare|www.synthesia.io
replicate|Replicate|cloudflare|replicate.com
openrouter|OpenRouter|cloudflare|openrouter.ai
genspark|Genspark|cloudflare|www.genspark.ai
bytedance|字节系|header|https://perfops.byte-test.com/500b-bench.jpg
alibaba|阿里系|alibaba|
tencent|腾讯系|tencent|
SERVICES
}

probe_routing_service() {
  prs_id="$1"; prs_mode="$3"; prs_target="$4"
  prs_ip=''; prs_time=''; prs_code=''

  case "$prs_mode" in
    cloudflare)
      prs_result=$(curl -sS -m "$NET_TIMEOUT" -o "$TMP/route_$prs_id" -w '%{http_code}|%{time_total}' "https://$prs_target/cdn-cgi/trace" 2>/dev/null)
      IFS='|' read -r prs_code prs_time <<EOF
$prs_result
EOF
      [ "$prs_code" -ge 200 ] 2>/dev/null && [ "$prs_code" -lt 300 ] 2>/dev/null && prs_ip=$(sed -n 's/^ip=//p' "$TMP/route_$prs_id")
      ;;
    header)
      prs_result=$(curl -sS -m "$NET_TIMEOUT" -D "$TMP/route_$prs_id" -o /dev/null -w '%{http_code}|%{time_total}' "$prs_target" 2>/dev/null)
      IFS='|' read -r prs_code prs_time <<EOF
$prs_result
EOF
      [ "$prs_code" -ge 200 ] 2>/dev/null && [ "$prs_code" -lt 300 ] 2>/dev/null && prs_ip=$(tr -d '\r' < "$TMP/route_$prs_id" | tr '[:upper:]' '[:lower:]' | sed -n -e 's/^x-request-ip:[[:space:]]*//p' -e 's/^x-response-cinfo:.*\([0-9][0-9a-f:.]*\).*/\1/p' | head -n 1)
      ;;
    alibaba)
      prs_url="https://$(date +%s)$$.dns-detect.alicdn.com/api/detect/DescribeDNSLookup?cb=ipforai"
      prs_result=$(curl -sS -m "$NET_TIMEOUT" -o "$TMP/route_$prs_id" -w '%{http_code}|%{time_total}' "$prs_url" 2>/dev/null)
      IFS='|' read -r prs_code prs_time <<EOF
$prs_result
EOF
      [ "$prs_code" -ge 200 ] 2>/dev/null && [ "$prs_code" -lt 300 ] 2>/dev/null && prs_ip=$(sed -n 's/.*"localIp":"\([^"]*\)".*/\1/p' "$TMP/route_$prs_id")
      ;;
    tencent)
      prs_result=$(curl -sS -m "$NET_TIMEOUT" -o "$TMP/route_$prs_id" -w '%{http_code}|%{time_total}' "https://vv.video.qq.com/checktime?otype=json&_=$(date +%s)$$" 2>/dev/null)
      IFS='|' read -r prs_code prs_time <<EOF
$prs_result
EOF
      [ "$prs_code" -ge 200 ] 2>/dev/null && [ "$prs_code" -lt 300 ] 2>/dev/null && prs_ip=$(sed -n 's/.*"ip":"\([^"]*\)".*/\1/p' "$TMP/route_$prs_id")
      ;;
  esac

  case "$prs_ip" in
    *.*) printf '%s' "$prs_ip" | awk -F. 'NF != 4 { exit 1 } { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1 }' || prs_ip='' ;;
    *:*) printf '%s' "$prs_ip" | grep -Eq '^[0-9A-Fa-f:]+$' || prs_ip='' ;;
    *) prs_ip='' ;;
  esac

  prs_latency=$(awk -v seconds="$prs_time" 'BEGIN { if (seconds ~ /^[0-9]+([.][0-9]+)?$/) printf "%.0fms", seconds * 1000 }')
  [ -n "$prs_ip" ] && prs_state='identified' || prs_state='unavailable'
  printf '%s|%s|%s\n' "$prs_state" "$prs_ip" "$prs_latency" > "$TMP/route_result_$prs_id"
}

# products 折叠成「服务 → 结论」，一次遍历写成小表。每个服务各扫一遍原数组的话，
# 11 个服务 × 16 个产品要开上百个 sed，实测会让整个脚本慢一倍。
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

# 汇总一个服务下所有产品形态的地区政策参考。它只看主归属地区与公开名单的对应，
# 不等同于整体可用性；后者还会受地区数据冲突、账号和实时链路影响。
OFF_STATE=''; OFF_NOTE=''
official_of() {
  of_all=0; of_no=0; of_un=0; of_lab=''
  while IFS='|' read -r of_sid of_st of_l; do
    [ "$of_sid" = "$1" ] || continue
    of_all=$(( of_all + 1 ))
    case "$of_st" in
      not_supported) of_no=$(( of_no + 1 )); of_lab="$of_l" ;;
      unknown)       of_un=$(( of_un + 1 )); of_lab="$of_l" ;;
    esac
  done < "$TMP/official"

  if [ "$of_all" -eq 0 ]; then
    OFF_STATE='none'; OFF_NOTE=''
  elif [ "$of_no" -eq "$of_all" ]; then
    OFF_STATE='blocked'; OFF_NOTE='地区受限'
  elif [ "$of_no" -gt 0 ]; then
    OFF_STATE='partial'; OFF_NOTE='部分准入'
  elif [ "$of_un" -eq "$of_all" ]; then
    OFF_STATE='unsure'; OFF_NOTE='地区待核'
  else
    OFF_STATE='open'; OFF_NOTE=''
  fi
}

# ---------- 本机探测 ----------

probe_service() {
  ps_id="$1"; ps_trace="$2"; ps_api="$3"; ps_expect="$4"
  ps_ip=''; ps_state='fail'; ps_code=''; ps_time=''

  # trace 和 api 并发跑。串行的话任何一个端点挂掉都会把它的超时加进总耗时——
  # chatgpt.com 的 trace 就是这样：连着 5 秒才 Connection reset，一个服务拖慢整个脚本。
  if [ -n "$ps_trace" ] && [ -n "$ps_api" ]; then
    ( fetch "$ps_trace" | sed -n 's/^ip=//p' > "$TMP/tr_$ps_id" ) &
    ps_result=$(curl -s -m "$NET_TIMEOUT" -o /dev/null -w '%{http_code}|%{time_total}' "$ps_api" 2>/dev/null)
    IFS='|' read -r ps_code ps_time <<EOF
$ps_result
EOF
    wait
    ps_ip=$(cat "$TMP/tr_$ps_id" 2>/dev/null)
  elif [ -n "$ps_trace" ]; then
    ps_ip=$(fetch "$ps_trace" | sed -n 's/^ip=//p')
  fi

  if [ -n "$ps_api" ]; then
    if [ -z "$ps_code" ]; then
      ps_result=$(curl -s -m "$NET_TIMEOUT" -o /dev/null -w '%{http_code}|%{time_total}' "$ps_api" 2>/dev/null)
      IFS='|' read -r ps_code ps_time <<EOF
$ps_result
EOF
    fi
    if [ "$ps_code" = "$ps_expect" ]; then
      ps_state='ok'
    elif [ "$ps_code" = "000" ] || [ -z "$ps_code" ]; then
      ps_state='fail'
    else
      ps_state='review'
    fi
  elif [ -n "$ps_ip" ]; then
    ps_state='ok'
  fi

  ps_latency=$(awk -v seconds="$ps_time" 'BEGIN { if (seconds ~ /^[0-9]+([.][0-9]+)?$/) printf "%.0fms", seconds * 1000 }')
  printf '%s|%s|%s|%s\n' "$ps_state" "$ps_ip" "$ps_latency" "$ps_code" > "$TMP/svc_$ps_id"
}

# 指定 IP：只画像 + 环境质量分。连通 / 分流依赖本机出口，不能当成该 IP 的链路结论。
if [ -n "$TARGET_IP" ]; then
  SCORE_IP="$PRIMARY_IP"
  SCORE_JSON="$PRIMARY"
  [ -z "$SCORE_JSON" ] && SCORE_JSON=$(fetch "$API_BASE/api/ip-profile?ip=$SCORE_IP")
  build_official "$PRIMARY"
  SCORE_SECTION='[02]'
else
  # 厂商自己的状态页。探测失败时用它区分「服务方挂了」和「你的线路不通」。
  fetch "$API_BASE/api/service-status" > "$TMP/status" 2>/dev/null || : > "$TMP/status"

  vendor_down() {
    vd=$(json_str "$(json_scope "$(cat "$TMP/status" 2>/dev/null)" "$1")" indicator)
    [ "$vd" = "major" ] || [ "$vd" = "critical" ]
  }

  # 管道会让 while 跑在子 shell 里，wait 必须一起放进去，否则父 shell 等不到这些后台任务。
  ai_services | { while IFS='|' read -r s_id s_name s_trace s_api s_expect; do
    probe_service "$s_id" "$s_trace" "$s_api" "$s_expect" &
  done; wait; }

  # 分流出口独立于服务连通性检测；只信任服务或厂商端点实际回显的公网 IP。
  ai_routing_services | { while IFS='|' read -r r_id r_name r_mode r_target; do
    probe_routing_service "$r_id" "$r_name" "$r_mode" "$r_target" &
  done; wait; }

  : > "$TMP/exits"
  ai_routing_services | while IFS='|' read -r r_id r_name r_mode r_target; do
    [ -f "$TMP/route_result_$r_id" ] || continue
    IFS='|' read -r r_state r_ip r_latency < "$TMP/route_result_$r_id"
    [ "$r_state" = 'identified' ] && echo "$r_ip" >> "$TMP/exits"
  done

  AI_EXIT=$(sort "$TMP/exits" 2>/dev/null | uniq -c | sort -rn | head -n 1 | awk '{print $2}')
  EXIT_KINDS=$(sort -u "$TMP/exits" 2>/dev/null | awk 'NF { count++ } END { print count + 0 }')
  ROUTING_TOTAL=$(ai_routing_services | wc -l | tr -d ' ')
  ROUTING_IDENTIFIED=$(wc -l < "$TMP/exits" | tr -d ' ')

  SCORE_IP="${AI_EXIT:-$PRIMARY_IP}"
  SCORE_JSON=$(profile_of "$SCORE_IP")
  [ -z "$SCORE_JSON" ] && SCORE_JSON=$(fetch "$API_BASE/api/ip-profile?ip=$SCORE_IP")
  [ -z "$SCORE_JSON" ] && SCORE_JSON="$PRIMARY"

  build_official "$SCORE_JSON"

  service_status_count() {
    ssc_state="$1"
    ai_services | while IFS='|' read -r ssc_id ssc_name ssc_trace ssc_api ssc_expect; do
      [ -f "$TMP/svc_$ssc_id" ] || continue
      IFS='|' read -r ssc_result _ssc_ip _ssc_latency _ssc_code < "$TMP/svc_$ssc_id"
      [ "$ssc_result" = "$ssc_state" ] && printf 'x\n'
    done | wc -l | tr -d ' '
  }

  print_service_results() {
    ai_services | while IFS='|' read -r s_id s_name s_trace s_api s_expect; do
      [ -f "$TMP/svc_$s_id" ] || continue
      IFS='|' read -r r_state r_ip r_latency r_code < "$TMP/svc_$s_id"
      official_of "$s_id"
      case "$OFF_STATE" in
        open) policy_note='准入范围内' ;;
        partial|blocked) policy_note="$OFF_NOTE" ;;
        *) policy_note='地区待核' ;;
      esac

      case "$r_state" in
        ok)
          mark="${GRN}✓${R}"; label='可连接'; note='' ;;
        review)
          mark="${YEL}!${R}"; label='响应异常'; note="$policy_note" ;;
        *)
          if [ "$OFF_STATE" = 'blocked' ]; then
            mark="${RED}×${R}"; label='连接失败'; note="$policy_note"
          elif vendor_down "$s_id"; then
            mark="${YEL}!${R}"; label='服务异常'; note="$policy_note"
          else
            mark="${RED}×${R}"; label='连接失败'; note="$policy_note"
          fi ;;
      esac

      [ -n "$r_latency" ] && label="$label · $r_latency"
      [ "$DETAIL" -eq 1 ] && [ -n "$r_code" ] && label="$label · HTTP $r_code"
      set_pad "$s_name" 13
      name_pad="$PAD"
      if [ -n "$note" ]; then
        set_pad "$label" 28
        printf '  %s %s%s%s%s  %s%s%s\n' "$mark" "$s_name" "$name_pad" "$label" "$PAD" "$DIM" "$note" "$R"
      else
        printf '  %s %s%s%s\n' "$mark" "$s_name" "$name_pad" "$label"
      fi
    done
  }

  SERVICE_OK=$(service_status_count ok)
  SERVICE_FAIL=$(service_status_count fail)
  SERVICE_REVIEW=$(service_status_count review)

  printf '\n  %s[02] AI 服务链路%s\n' "$B" "$R"
  printf '  %s检测结果%s  %s%s 可连接%s · %s%s 失败%s' "$DIM" "$R" "$GRN" "$SERVICE_OK" "$R" "$RED" "$SERVICE_FAIL" "$R"
  [ "$SERVICE_REVIEW" -gt 0 ] && printf ' · %s%s 需复核%s' "$YEL" "$SERVICE_REVIEW" "$R"
  printf '\n'
  printf '  %s说明%s      基于本机当前出口的公开资源探测，不代表账号或完整功能可用\n\n' "$DIM" "$R"
  print_service_results

  printf '\n  %s[03] AI 分流出口%s\n' "$B" "$R"
  printf '  %s说明%s      与本机同地址族出口对照；无对照出口时不判「不一致」\n' "$DIM" "$R"
  if [ -s "$TMP/exits" ]; then
    printf '  %s%s 项中识别到 %s 项 · %s 条出口路径%s\n\n' "$DIM" "$ROUTING_TOTAL" "$ROUTING_IDENTIFIED" "$EXIT_KINDS" "$R"
    ai_routing_services | while IFS='|' read -r r_id r_name r_mode r_target; do
      [ -f "$TMP/route_result_$r_id" ] || continue
      IFS='|' read -r r_state r_ip r_latency < "$TMP/route_result_$r_id"
      [ "$r_state" = 'identified' ] || continue

      set_pad "$r_name" 16
      baseline=$(exit_for_family "$r_ip")
      if [ -z "$baseline" ]; then
        fam_note='无同族对照'
        is_ipv6_addr "$r_ip" && fam_note='无 IPv6 对照' || fam_note='无 IPv4 对照'
        printf '  %s%s  %s · %s  %s%s%s\n' "$r_name" "$PAD" "$r_ip" "$r_latency" "$DIM" "$fam_note" "$R"
      elif [ "$r_ip" != "$baseline" ]; then
        if is_ipv6_addr "$r_ip"; then
          mismatch_note='与 IPv6 出口不一致'
        else
          mismatch_note='与 IPv4 出口不一致'
        fi
        printf '  %s%s  %s%s%s · %s  %s%s%s\n' "$r_name" "$PAD" "$RED" "$r_ip" "$R" "$r_latency" "$RED" "$mismatch_note" "$R"
      else
        printf '  %s%s  %s · %s\n' "$r_name" "$PAD" "$r_ip" "$r_latency"
      fi
    done
  else
    printf '\n  %s%s 项服务本次均未返回可识别的公网出口。%s\n' "$DIM" "$ROUTING_TOTAL" "$R"
  fi

  if [ "$EXIT_KINDS" -gt 1 ]; then
    printf '\n  %s%s 条路径并行，存在服务级分流。%s\n' "$YEL" "$EXIT_KINDS" "$R"
  fi

  SCORE_SECTION='[04]'
fi

# ---------- 环境质量分 ----------
# 本机模式优先用分流众数出口的后端分数；指定 IP 用该 IP 画像。脚本不本地改写规则。

SCORE_O=$(json_scope "$SCORE_JSON" score)
SCORE=$(json_num "$SCORE_O" environmentScore)
SCORE_LABEL=$(json_str "$SCORE_O" levelLabel)

printf '\n  %s%s 环境质量分%s\n\n' "$B" "$SCORE_SECTION" "$R"

if [ -n "$SCORE" ]; then
  if [ "$SCORE" -ge 85 ]; then SC="$GRN"
  elif [ "$SCORE" -ge 50 ]; then SC="$YEL"
  else SC="$RED"; fi

  printf '  %s环境质量分%s  %s%s%s %s/ 100%s   %s%s%s\n' \
    "$B" "$R" "$SC$B" "$SCORE" "$R" "$DIM" "$R" "$SC" "$SCORE_LABEL" "$R"
  if [ -n "$SCORE_IP" ]; then
    printf '  %s计分对象%s    %s\n\n' "$DIM" "$R" "$SCORE_IP"
  else
    printf '\n'
  fi

  json_list "$SCORE_O" deductions | while read -r reason; do
    [ -n "$reason" ] && printf '  %s\n' "$reason"
  done
else
  printf '  %s环境质量分暂时无法计算，请稍后重试。%s\n' "$YEL" "$R"
fi

if [ "$DETAIL" -eq 1 ]; then
  printf '\n  %s详细诊断%s\n' "$B" "$R"
  printf '  %s本机时区%s  %s (UTC%s)\n' "$DIM" "$R" "${SYS_TZ:-$LOCAL_ZONE}" "${UTC_OFF:-?}"
  if [ -z "$TARGET_IP" ]; then
    printf '  %s服务响应%s  HTTP 状态已显示在每项服务耗时后（需 -d）\n' "$DIM" "$R"
  fi
  printf '  %s脚本版本%s  %s\n' "$DIM" "$R" "$SCRIPT_VERSION"
fi

CHECK_FINISHED_EPOCH=$(date +%s 2>/dev/null || echo '')
if [ -n "$CHECK_STARTED_EPOCH" ] && [ -n "$CHECK_FINISHED_EPOCH" ]; then
  CHECK_ELAPSED=$((CHECK_FINISHED_EPOCH - CHECK_STARTED_EPOCH))
  printf '  %s本次耗时%s  %s 秒\n' "$DIM" "$R" "$CHECK_ELAPSED"
fi
printf '\n  %s在线查看 IP 画像  %s/?ip=%s%s\n\n' "$DIM" "$WEB_BASE" "$SCORE_IP" "$R"
