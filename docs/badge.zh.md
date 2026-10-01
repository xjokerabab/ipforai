# ipforai README 徽章说明

Base URL：`https://ipforai.cc`

英文版：[badge.md](./badge.md)

给任意项目 README 挂一张「AI 网络评分」徽章：显示指定 IP 的环境质量分与档位颜色，点击回到官网结果页。

## 两种用法

**Shields.io endpoint 徽章**（推荐，Shields 负责渲染和缓存）：

```markdown
[![AI 网络评分](https://img.shields.io/endpoint?url=https%3A%2F%2Fipforai.cc%2Fbadge.json%3Fip%3D8.8.8.8)](https://ipforai.cc/?ip=8.8.8.8)
```

注意 `url=` 的值需要 URL 编码。

**自托管 SVG**（不依赖 Shields.io，任意网页 `<img>` 可直接嵌入）：

```markdown
[![AI 网络评分](https://ipforai.cc/badge.svg?ip=8.8.8.8)](https://ipforai.cc/?ip=8.8.8.8)
```

## 接口

### `GET /badge.json?ip={地址}`

返回 [Shields endpoint schema](https://shields.io/badges/endpoint-badge)：

```json
{
  "schemaVersion": 1,
  "label": "AI 网络",
  "message": "64 · 一般",
  "color": "yellowgreen",
  "cacheSeconds": 600
}
```

### `GET /badge.svg?ip={地址}`

直接返回 `image/svg+xml` 徽章图，风格与 Shields flat 一致，可独立使用。

## 颜色档位

| 分数 | 档位 | 颜色 |
|------|------|------|
| ≥ 90 | 极佳 | brightgreen |
| ≥ 75 | 良好 | green |
| ≥ 60 | 一般 | yellowgreen |
| ≥ 40 | 待检查 | yellow |
| < 40 | 异常明显 | red |
| 无分数 | 待确认 | lightgrey |

颜色与官网环境质量分档位一致；分数是网络环境参考分，**不是** AI 账号分。

## 参数与缓存

| 请求 | 目标 | Cache-Control |
|------|------|---------------|
| `?ip=` 已填 | 查询该地址画像 | `public, max-age=600` |
| 省略 `?ip=` | 本次请求源 IP（访客模式） | `private, no-store` |
| 非法 IP | 灰色「无效 IP」徽章（HTTP 200） | `public, max-age=600` |

## README 里必须带 `?ip=`

GitHub 的 README 图片由 camo 代理抓取并缓存。不带参数的徽章显示的是抓图方（GitHub 出口）的分数，不是读者的分数——所以 README 徽章请固定 `?ip=` 指向你自己的出口 IP（例如机场、VPS、代理项目的出口）。

不带参数的「访客模式」适合嵌在普通网页里（`<img src="https://ipforai.cc/badge.svg">`），每位访客看到自己出口的评分；注意别让 CDN 缓存这条路径。

## 响应头

| Header | 值 |
|--------|-----|
| `Cache-Control` | 见上表 |
| `X-IP-for-AI-Schema` | `badge-v1` |
