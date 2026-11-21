# IP for AI — Is It My Network, or Is It AI?

[中文](./README.md) · [Open Site](https://ipforai.cc) · [AI Weather](https://ipforai.cc/weather) · [Routing Checker](https://ipforai.cc/rules) · [ASN Database](https://ipforai.cc/datacenters) · [CLI](https://ipforai.cc/cli)

Instantly see the exit IP, region, official status, and low-level leaks (WebRTC, DNS/ECS, TCP SYN/MSS, passive JA4, HTTP/3 QUIC) observed by **Claude, ChatGPT, Gemini, and Grok** — with every issue labeled as fixable locally, fixable via routing rules, or requiring a different node.

> Evaluates the network environment only — never predicts account bans or subscription eligibility.

![IP for AI Web Dashboard](./docs/images/web-overview.png)

---

## Pages & Tools

- **Dashboard**: [ipforai.cc](https://ipforai.cc) — Side-by-side exits, scores, and interactive fix simulation
- **Per-Service Checks**: [Claude](https://ipforai.cc/claude-check) · [ChatGPT](https://ipforai.cc/chatgpt-check) · [Gemini](https://ipforai.cc/gemini-check) · [Grok](https://ipforai.cc/grok-check)
- **AI Weather**: [ipforai.cc/weather](https://ipforai.cc/weather) — Live official status, 60-day incident history, and 7-region API reachability
- **Routing Checker**: [ipforai.cc/rules](https://ipforai.cc/rules) — Client-side Clash / Surge rule check for 11 critical AI domains
- **ASN & Datacenter DB**: [ipforai.cc/datacenters](https://ipforai.cc/datacenters) — 120k+ global ASNs with PeeringDB metadata

---

## Terminal Check (CLI)

On a local computer, terminals ignore the OS system proxy by default. Either enable **TUN mode**, or run in a subshell with your proxy port so both `curl` and `sh` route through it:

```bash
# VPS / server, or local terminal with TUN mode enabled
curl -fsSL https://ipforai.cc/sh | sh

# Local terminal without TUN (replace 7890 with your proxy port)
(export HTTPS_PROXY=http://127.0.0.1:7890 ALL_PROXY=socks5h://127.0.0.1:7890;
  curl -fsSL https://ipforai.cc/sh | sh)

# Profile a specific IP only
curl -fsSL https://ipforai.cc/sh | sh -s -- 8.8.8.8

# Non-interactive + detailed diagnostics
curl -fsSL https://ipforai.cc/sh | sh -s -- -y -d
```

![ipforai Terminal Output](./docs/images/terminal-report.png)

> Canonical URL: `https://ipforai.cc/sh`. [`check.sh`](./check.sh) is a review mirror (`v3.3`).

---

## JSON API, Badge & MCP

```bash
curl -fsSL 'https://ipforai.cc/json'
curl -fsSL 'https://ipforai.cc/json?ip=8.8.8.8'
```

```bash
claude mcp add ipforai -- npx -y ipforai-mcp
```

4 tools: `check_my_ip`, `lookup_ip`, `check_ai_weather`, and `lookup_asn`. Docs: [docs/api.md](./docs/api.md) · [docs/badge.md](./docs/badge.md) · [mcp/README.md](./mcp/README.md)

## License

[MIT](./LICENSE)
