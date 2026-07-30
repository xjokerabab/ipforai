# ipforai Network Check

[中文](./README.md) · [Website](https://ipforai.cc) · [Method](https://ipforai.cc/about)

Network environment checks for **AI access**: public exit profile, network / access / routing attributes, risk signals, environment score, and availability references for ChatGPT, Claude, Gemini, and more (**Available / Limited / Unavailable / Pending**).

Results describe the **network only**. They are not account login, subscription, or platform risk decisions.

---

## One-liners

### Terminal (recommended)

```bash
curl -fsSL https://ipforai.cc/sh | sh
```

Review before run:

```bash
curl -fsSL https://ipforai.cc/sh -o /tmp/ipforai-check.sh
less /tmp/ipforai-check.sh
sh /tmp/ipforai-check.sh -y
```

```bash
curl -fsSL https://ipforai.cc/sh | sh -s -- -y
curl -fsSL https://ipforai.cc/sh | sh -s -- -y 8.8.8.8
curl -fsSL https://ipforai.cc/sh | sh -s -- -y -d
```

> **Canonical script URL is always** `https://ipforai.cc/sh`. `check.sh` in this repo is a mirror for review and stars.

### Developer JSON

```bash
curl -fsSL https://ipforai.cc/json
curl -fsSL "https://ipforai.cc/json?ip=8.8.8.8"
curl -4 -fsSL https://ipforai.cc/json
curl -6 -fsSL https://ipforai.cc/json
```

See [docs/api.md](./docs/api.md) ([中文](./docs/api.zh.md)) and [examples/sample.json](./examples/sample.json).

One HTTP request fills only one of `ipv4` / `ipv6` (`dualStack` is usually `false`).

### Web UI

[https://ipforai.cc](https://ipforai.cc)

---

## Scope

| Included | Notes |
|----------|--------|
| Exit profile | Geo, ASN, network type, access form, routing |
| Risk signals | Proxy-related level, Tor exit when data exists |
| Environment score | Network reference score — **not** an account score |
| AI labels | Same as the site: Available / Limited / Unavailable / Pending |
| CLI path probes | From **this machine’s exit** only (not for arbitrary `?ip=` as live path) |

**Not included:** ban prediction, unlock guarantees, “IP purity” marketing scores.

---

## Dual stack

One TCP connection exposes one source family. Use `curl -4` / `curl -6`, or `?ip=` for a specific address. The JSON shape always has `ipv4` / `ipv6` slots; the unused side is `null`.

Canonical runtime URL remains `https://ipforai.cc/sh`.

## GitHub listing tips

- **Description:** AI network environment check — one-liner CLI + JSON API (ipforai.cc)
- **Topics:** `ip` `ai` `chatgpt` `claude` `shell` `network` `json-api`
- **Website:** https://ipforai.cc

---

## License

[MIT](./LICENSE)
