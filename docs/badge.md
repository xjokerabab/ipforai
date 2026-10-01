# ipforai README Badge

Base URL: `https://ipforai.cc`

中文版: [badge.zh.md](./badge.zh.md)

Add an "AI network score" badge to any project README: it shows the environment score and level color for a fixed IP, and clicks through to the result page on the site.

## Two ways to embed

**Shields.io endpoint badge** (recommended; Shields handles rendering and caching):

```markdown
[![AI network score](https://img.shields.io/endpoint?url=https%3A%2F%2Fipforai.cc%2Fbadge.json%3Fip%3D8.8.8.8)](https://ipforai.cc/?ip=8.8.8.8)
```

The `url=` value must be URL-encoded.

**Self-hosted SVG** (no Shields.io dependency; works in any `<img>`):

```markdown
[![AI network score](https://ipforai.cc/badge.svg?ip=8.8.8.8)](https://ipforai.cc/?ip=8.8.8.8)
```

## Endpoints

### `GET /badge.json?ip={address}`

Returns the [Shields endpoint schema](https://shields.io/badges/endpoint-badge):

```json
{
  "schemaVersion": 1,
  "label": "AI 网络",
  "message": "64 · 一般",
  "color": "yellowgreen",
  "cacheSeconds": 600
}
```

### `GET /badge.svg?ip={address}`

Returns the badge directly as `image/svg+xml`, styled like Shields flat, usable on its own.

## Color levels

| Score | Level | Color |
|-------|-------|-------|
| ≥ 90 | 极佳 (excellent) | brightgreen |
| ≥ 75 | 良好 (good) | green |
| ≥ 60 | 一般 (fair) | yellowgreen |
| ≥ 40 | 待检查 (needs review) | yellow |
| < 40 | 异常明显 (clearly abnormal) | red |
| no score | 待确认 (pending) | lightgrey |

Colors match the site's environment-score levels; the score is a network-environment reference, **not** an AI account score.

## Parameters and caching

| Request | Target | Cache-Control |
|---------|--------|---------------|
| `?ip=` given | Look up that address | `public, max-age=600` |
| `?ip=` omitted | This request's source IP (visitor mode) | `private, no-store` |
| Invalid IP | Grey "无效 IP" badge (HTTP 200) | `public, max-age=600` |

## Always pass `?ip=` in READMEs

GitHub renders README images through its camo proxy and caches them. A parameterless badge shows the fetcher's (GitHub's) score, not the reader's — so fix `?ip=` to your own exit IP (e.g. a VPN, VPS, or proxy project's exit).

The parameterless "visitor mode" fits ordinary web pages (`<img src="https://ipforai.cc/badge.svg">`), where each visitor sees their own exit; make sure your CDN does not cache that path.

## Response headers

| Header | Value |
|--------|-------|
| `Cache-Control` | see table above |
| `X-IP-for-AI-Schema` | `badge-v1` |
