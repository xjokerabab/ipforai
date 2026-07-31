# ipforai JSON API

Base URL: `https://ipforai.cc`

## Endpoints

### `GET /json`

Current request source IP as observed by the server. The endpoint does not inspect the caller's local system, proxy configuration, or browser state.

```bash
curl -fsSL https://ipforai.cc/json
curl -4 -fsSL https://ipforai.cc/json
curl -6 -fsSL https://ipforai.cc/json
```

### `GET /json?ip={address}`

Look up a specific IPv4 or IPv6 address.

```bash
curl -fsSL "https://ipforai.cc/json?ip=8.8.8.8"
curl -fsSL "https://ipforai.cc/json?ip=2001:4860:4860::8888"
curl --get -fsSL --data-urlencode 'ip=8.8.8.8' "https://ipforai.cc/json"
```

`ip` is the only optional query parameter. Omit it or leave it empty to use the request source IP; provide an IPv4 or IPv6 address for a server-side profile lookup. The service does not initiate a live connection from that address. An invalid address returns HTTP 400 with `invalid_ip`.

## Response shape

```json
{
  "dualStack": false,
  "ipv4": { "...exit object or null..." },
  "ipv6": null,
  "disclaimer": "结果仅供参考，不代表账号或平台最终判断。"
}
```

| Field | Meaning |
|-------|---------|
| `dualStack` | `true` only when both `ipv4` and `ipv6` objects are present |
| `ipv4` / `ipv6` | Slim exit view, or `null` |
| `disclaimer` | Short boundary text |

**Current server behavior:** one HTTP request fills **exactly one** side (`dualStack` is almost always `false`). The unused family is `null`. This is intentional — a single TCP connection only has one source address family.

To compare dual-stack exits, call twice:

```bash
curl -4 -fsSL https://ipforai.cc/json
curl -6 -fsSL https://ipforai.cc/json
```

Or look up two known addresses with `?ip=` separately.

### Exit object (slim)

| Field | Description |
|-------|-------------|
| `ip` | Address |
| `countryCode` / `countryName` / `region` / `city` / `timezone` | Geo |
| `asn` / `asName` | ASN |
| `networkType` / `networkLabel` | Network profile |
| `accessType` / `accessLabel` | Access form |
| `routeType` / `routeLabel` | Routing |
| `riskLevel` / `riskLabel` / `isProxy` / `torExit` | Risk (may be `null` if the risk source is unavailable). Labels such as「纯净」come from the data source wording, not a product “purity score”. |
| `score` / `scoreLabel` | Environment score |
| `ai` | List of services with `id`, `name`, `status`, `label` |
| `url` | Web deep link |

### AI `status` / `label`

| status | label (zh) |
|--------|------------|
| `supported` | 可用 |
| `partial` | 受限 |
| `not_supported` | 不可用 |
| `unknown` | 待确认 |

Labels match the website footer. They are **not** live connectivity tests for `?ip=`.

## Errors

```json
{
  "error": "invalid_ip",
  "disclaimer": "结果仅供参考，不代表账号或平台最终判断。"
}
```

| error | HTTP |
|-------|------|
| `invalid_ip` | 400 |
| `client_ip_not_found` | 400 |
| `upstream_unavailable` | 503 |

## Headers

| Header | Value |
|--------|--------|
| `Cache-Control` | `private, no-store` |
| `X-IP-for-AI-Schema` | `json-v1` |

## Example

See [examples/sample.json](../examples/sample.json) (`114.114.114.114`).

## Full profile

For the complete internal profile (larger payload):

```text
https://ipforai.cc/api/ip-profile?ip=8.8.8.8
```
