# IP for AI — 是我的问题，还是 AI 的问题？

[English](./README_EN.md) · [立即检测](https://ipforai.cc) · [AI 天气](https://ipforai.cc/weather) · [规则体检](https://ipforai.cc/rules) · [机房库](https://ipforai.cc/datacenters) · [终端](https://ipforai.cc/cli) · [指南](https://ipforai.cc/guides)

打开即测 **Claude、ChatGPT、Gemini、Grok** 各自看到的出口 IP、地区、官方状态与底层协议泄露（WebRTC / DNS & ECS / TCP 首包 / MSS / 被动 JA4 / HTTP/3 QUIC），扣分项逐条标明 **你能修**、**改分流规则** 还是 **换节点**。

> 只评价网络环境，不预测账号是否被封。

![IP for AI 新版检测面板](./docs/images/web-overview.png)

---

## 页面与工具

- **首页总览**：[ipforai.cc](https://ipforai.cc) — 同屏对比四家出口、环境分与实时修复推演
- **四家专项页**：[Claude](https://ipforai.cc/claude-check) · [ChatGPT](https://ipforai.cc/chatgpt-check) · [Gemini](https://ipforai.cc/gemini-check) · [Grok](https://ipforai.cc/grok-check)
- **AI 天气**：[ipforai.cc/weather](https://ipforai.cc/weather) — 官方状态、近 60 天故障记录与 7 地区 API 直连实测
- **分流规则体检**：[ipforai.cc/rules](https://ipforai.cc/rules) — 浏览器本地解析 Clash / Surge 规则，查 11 个关键 AI 域名漏网
- **ASN 与机房库**：[ipforai.cc/datacenters](https://ipforai.cc/datacenters) — 全球 12 万+ ASN 实时反查，附高频 VPS 机房与家宽对照榜
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

> 权威脚本地址：`https://ipforai.cc/sh`；本仓库 [`check.sh`](./check.sh) 为审阅镜像（`v3.3`）。

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

详见 [mcp/README.md](./mcp/README.md)。

---

## License

[MIT](./LICENSE)
