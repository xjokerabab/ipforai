# ipforai-mcp

[![npm](https://img.shields.io/npm/v/ipforai-mcp)](https://www.npmjs.com/package/ipforai-mcp)

MCP server for [IP for AI](https://ipforai.cc): ask your AI assistant whether your current exit IP works for ChatGPT, Claude, Gemini and other AI services.

为 [IP for AI](https://ipforai.cc) 提供的 MCP 服务：在 Claude、Cursor 等 AI 客户端里直接检测当前出口 IP 能否正常使用 ChatGPT、Claude、Gemini 等 AI 服务。

## Tools

| Tool | Input | Returns |
|------|-------|---------|
| `check_my_ip` | none | Profile of this machine's IPv4 / IPv6 exit |
| `lookup_ip` | `ip` (IPv4 or IPv6) | Profile of the given address |

Each profile includes location, ASN, network type (residential / ISP / datacenter / proxy / Tor), access and routing type, risk level, an environment score, AI service availability, and a link to the full report on ipforai.cc.

Results describe the network environment only. They are not account, login or subscription verdicts.

## Setup

Requires Node.js 20.18.1 or later. No API key.

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

`check_my_ip` reports the exit that ipforai.cc sees, so the request has to go through the same proxy your AI traffic uses. The server honors `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY`. TUN / transparent proxy modes need no setup. If your proxy is only set as the system proxy, pass it explicitly:

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

The server only calls ipforai.cc (`/json` and the exit echo endpoints). It reads nothing from your machine besides the proxy environment variables.

## License

MIT
