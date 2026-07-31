# ipforai JSON 接口说明

Base URL：`https://ipforai.cc`

英文版：[api.md](./api.md)

## 接口

### `GET /json`

服务端看到的当前请求源 IP。这个接口不会读取调用方本机系统、代理配置或浏览器状态。

```bash
curl -fsSL https://ipforai.cc/json
curl -4 -fsSL https://ipforai.cc/json
curl -6 -fsSL https://ipforai.cc/json
```

### `GET /json?ip={地址}`

查询指定 IPv4 或 IPv6。

```bash
curl -fsSL "https://ipforai.cc/json?ip=8.8.8.8"
curl -fsSL "https://ipforai.cc/json?ip=2001:4860:4860::8888"
curl --get -fsSL --data-urlencode 'ip=8.8.8.8' "https://ipforai.cc/json"
```

`ip` 是唯一可选查询参数。省略或留空时使用本次请求源 IP；填入 IPv4/IPv6 时只做服务端画像查询，不会从该地址发起实时连接。非法地址返回 HTTP 400 `invalid_ip`。

## 响应形状

```json
{
  "dualStack": false,
  "ipv4": { "..." },
  "ipv6": null,
  "disclaimer": "结果仅供参考，不代表账号或平台最终判断。"
}
```

| 字段 | 含义 |
|------|------|
| `dualStack` | 仅当 `ipv4` 与 `ipv6` 都有对象时为 `true` |
| `ipv4` / `ipv6` | 瘦画像，或 `null` |
| `disclaimer` | 简短边界说明 |

**当前实现：** 一次 HTTP 只填一侧（`dualStack` 几乎总是 `false`）。单次 TCP 只能看到一个源地址族。双栈请 `curl -4` / `curl -6` 各请求一次，或分别 `?ip=`。

### 单侧字段（瘦）

| 字段 | 说明 |
|------|------|
| `ip` | 地址 |
| `countryCode` / `countryName` / `region` / `city` / `timezone` | 地理 |
| `asn` / `asName` | ASN |
| `networkType` / `networkLabel` | 网络属性 |
| `accessType` / `accessLabel` | 接入形态 |
| `routeType` / `routeLabel` | 路由 |
| `riskLevel` / `riskLabel` / `isProxy` / `torExit` | 风险（源不可用时可为 `null`；「纯净」等为数据源用词，非产品「纯净度」承诺） |
| `score` / `scoreLabel` | 环境质量分 |
| `ai` | `id` / `name` / `status` / `label` |
| `url` | 网页深链 |

### AI `status` / `label`

| status | label |
|--------|--------|
| `supported` | 可用 |
| `partial` | 受限 |
| `not_supported` | 不可用 |
| `unknown` | 待确认 |

与官网底部文案一致。`?ip=` 查询不是从该 IP 发起的实时连通探测。

## 错误

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

## 响应头

| Header | 值 |
|--------|-----|
| `Cache-Control` | `private, no-store` |
| `X-IP-for-AI-Schema` | `json-v1` |

## 示例

见 [examples/sample.json](../examples/sample.json)（`114.114.114.114`）。

## 完整画像

```text
https://ipforai.cc/api/ip-profile?ip=8.8.8.8
```
