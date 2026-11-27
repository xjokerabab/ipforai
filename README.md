# IP for AI — 是我的问题，还是 AI 的问题？

[English](./README_EN.md) · [立即检测](https://ipforai.cc) · [IP 纯净度](https://ipforai.cc/ip) · [AI 天气](https://ipforai.cc/weather) · [支持地区](https://ipforai.cc/regions) · [规则体检](https://ipforai.cc/rules) · [机房库](https://ipforai.cc/datacenters) · [终端](https://ipforai.cc/cli) · [指南](https://ipforai.cc/guides) · [商务合作](https://ipforai.cc/contact)

打开即测 **Claude、ChatGPT、Gemini、Grok** 各自看到的出口 IP、地区、官方状态与底层协议泄露（WebRTC / DNS & ECS / TCP 首包 / MSS / 被动 JA4 / HTTP/3 QUIC），扣分项逐条标明 **你能修**、**改分流规则** 还是 **换节点**。

> 只评价网络环境，不预测账号是否被封。

![IP for AI 新版检测面板](./docs/images/web-overview.png)

---

## 页面与工具

- **首页总览**：[ipforai.cc](https://ipforai.cc) — 同屏对比四家出口、环境分与实时修复推演
- **IP 纯净度检测**：[ipforai.cc/ip](https://ipforai.cc/ip) — 0–100 纯净度评分（A+~F）、原生 / 广播 IP 与 ASN 跨区播报识别、双 ISP 与大运营商托管转租段穿透（IRR + 按需 RDAP）、IP2Proxy / Spamhaus / 公开攻击名单与 10 家国际 DNSBL
- **泄露专项排查**：[WebRTC 泄露](https://ipforai.cc/webrtc-leak) · [DNS 泄露](https://ipforai.cc/dns-leak) — 并发 STUN 候选探测与递归 DNS / ECS 子网核验
- **四家专项页**：[Claude](https://ipforai.cc/claude-check) · [ChatGPT](https://ipforai.cc/chatgpt-check) · [Gemini](https://ipforai.cc/gemini-check) · [Grok](https://ipforai.cc/grok-check)
- **AI 天气**：[ipforai.cc/weather](https://ipforai.cc/weather) — 官方状态、受影响组件与未关闭事件明细、近 60 天故障记录与 7 地区 API 直连实测
- **AI 官方支持地区**：[ipforai.cc/regions](https://ipforai.cc/regions) — 10 个核心节点地区与 9 项网页 / App / API 官方支持清单对照
- **分流规则体检**：[ipforai.cc/rules](https://ipforai.cc/rules) — 提供 Clash / Mihomo、Surge、Sing-box、Quantumult X 官方规则集订阅，并支持浏览器本地查漏 89 个核心、编程工具、扩展 AI 与鉴权遥测域名
- **ASN 与机房库**：[ipforai.cc/datacenters](https://ipforai.cc/datacenters) — 全球 12 万+ ASN 实时反查，支持单 ASN 深度档案（`/asn/as<num>`）与 IRR 托管转租子网拆解
- **排查指南**：[ipforai.cc/guides](https://ipforai.cc/guides) — 按打不开、验证循环、地区不可用、终端代理等症状排查

---

## 终端守门员（CLI）

一条命令排查 VPS、SSH 或本机 Claude Code / Codex / Gemini CLI 的真实出口、分流、遥测域名与 TCP 指纹（纯 POSIX `sh`，只读不装软件）。

本机电脑终端默认不走系统代理：请先**开启代理软件的 TUN 模式**，或用第二条命令在子壳里临时传入代理端口：

```bash
# VPS / 服务器，或本机已开 TUN 模式
curl -fsSL https://ipforai.cc/sh | sh

# 本机不开 TUN，从代理视角测（7890 换成你的端口：Clash 7890 / Surge 6152 / v2rayN 10808）
(export HTTPS_PROXY=http://127.0.0.1:7890 ALL_PROXY=socks5h://127.0.0.1:7890;
  curl -fsSL https://ipforai.cc/sh | sh)

# 只查指定 IP 画像（不测本机链路）
curl -fsSL https://ipforai.cc/sh | sh -s -- 8.8.8.8

# 跳过确认 + 展开详细诊断
curl -fsSL https://ipforai.cc/sh | sh -s -- -y -d

# 只按 IPv4（-4）或 IPv6（-6）出口与连通性检测
curl -fsSL https://ipforai.cc/sh | sh -s -- -4

# 一屏摘要（出口、四家 AI 可达性与基础分）
curl -fsSL https://ipforai.cc/sh | sh -s -- -s

# 输出可贴论坛的 Markdown 体检表（附 7 天脱敏短链）
curl -fsSL https://ipforai.cc/sh | sh -s -- -m

# 关闭在线脱敏分享短链生成
curl -fsSL https://ipforai.cc/sh | sh -s -- --no-share

# 输出 JSON 到 stdout（隐含 -y，供其他脚本集成）
curl -fsSL https://ipforai.cc/sh | sh -s -- -j
```

<details>
<summary>想先下载源码审阅再执行？</summary>

```bash
curl -fsSL https://ipforai.cc/sh -o /tmp/ipforai-check.sh
less /tmp/ipforai-check.sh
sh /tmp/ipforai-check.sh
```

</details>

![ipforai 终端守门员实测输出](./docs/images/terminal-report.png)

> 权威脚本地址：`https://ipforai.cc/sh`；本仓库 [`check.sh`](./check.sh) 为审阅镜像（`v3.8`）。

---

## 开发者接口、徽章与 MCP

### JSON API（`GET /json`）

```bash
curl -fsSL 'https://ipforai.cc/json'
curl -4 -fsSL 'https://ipforai.cc/json'
curl -fsSL 'https://ipforai.cc/json?ip=8.8.8.8'
```

字段与稳定性说明：[docs/api.zh.md](./docs/api.zh.md) · 示例：[examples/sample.json](./examples/sample.json)

### README 评分徽章

```markdown
[![IP for AI](https://ipforai.cc/badge.svg?ip=8.8.8.8)](https://ipforai.cc/?ip=8.8.8.8)
```

[![IP for AI](https://ipforai.cc/badge.svg?ip=8.8.8.8)](https://ipforai.cc/?ip=8.8.8.8)

详见 [docs/badge.zh.md](./docs/badge.zh.md)（在 GitHub README 使用时必须带 `?ip=`）。

### MCP（Claude Code / Cursor）

```bash
claude mcp add ipforai -- npx -y ipforai-mcp
```

提供 `check_my_ip`（本机出口）、`lookup_ip`（指定 IP）、`check_ai_weather`（官方状态与 7 地区连通）和 `lookup_asn`（全球 ASN 反查）四个工具，详见 [mcp/README.md](./mcp/README.md)。

---

## 商务合作与联系

赞助、合作、API 集成或数据纠错请发邮件至 [bd@ipforai.cc](mailto:bd@ipforai.cc)，详见 [ipforai.cc/contact](https://ipforai.cc/contact)。

---

## License

[MIT](./LICENSE)
