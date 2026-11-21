# ipforai-mcp

[![npm](https://img.shields.io/npm/v/ipforai-mcp)](https://www.npmjs.com/package/ipforai-mcp)

MCP server for [IP for AI](https://ipforai.cc) — **Is it my network, or is it AI?**

为 [IP for AI](https://ipforai.cc) 提供的 MCP 服务：在 Claude Code、Cursor 等 AI 客户端里直接排查本机出口 IP、查询任意 IP、查看四大 AI 官方状态与 7 地区连通，以及反查全球 ASN 机房/家宽属性。

## Tools

| Tool | Input | Returns |
|------|-------|---------|
| `check_my_ip` | none | 本机 IPv4/IPv6 出口画像、环境分与 AI 地区支持（走 `HTTPS_PROXY`） |
| `lookup_ip` | `ip` | 指定 IPv4/IPv6 的网络画像、风险信号与环境分 |
| `check_ai_weather` | none | Claude / ChatGPT / Gemini / Grok 实时官方状态与 7 地区 API 直连连通 |
| `lookup_asn` | `query` | 反查全球 12 万+ ASN / 运营方（如 `AS2497`、`Vultr`），区分机房与家宽 |

Results describe the network environment only — never account, login, or subscription verdicts.

## Setup

Requires Node.js 20.18.1 or later. No API key required.

**Claude Code**

```bash
claude mcp add ipforai -- npx -y ipforai-mcp
```

**Claude Desktop / Cursor / other clients**

```json
{
  "mcpServers": {
    "ipforai": {
      "command": "npx",
      "args": ["-y", "ipforai-mcp"]
    }
  }
}
```

## Proxy

`check_my_ip` reports the exit seen by `ipforai.cc`. The server honors `HTTPS_PROXY`, `HTTP_PROXY`, and `NO_PROXY`. With TUN / transparent proxy enabled, no extra config is needed; otherwise pass your local proxy port in `env`:

```json
{
  "mcpServers": {
    "ipforai": {
      "command": "npx",
      "args": ["-y", "ipforai-mcp"],
      "env": { "HTTPS_PROXY": "http://127.0.0.1:7890" }
    }
  }
}
```

## Privacy

The server only calls `ipforai.cc` public endpoints (`/json`, `/api/ip-profile/echo`, `/api/service-status`, `/api/region-reachability`, `/api/asn`). It reads nothing from your machine besides proxy environment variables.

## License

MIT
