# ipforai 网络检测

[English](./README_EN.md) · [官网](https://ipforai.cc) · [检测方法](https://ipforai.cc/about)

面向 **AI 访问场景** 的网络环境检测：当前出口画像、网络/接入/路由属性、风险信号、环境质量分，以及对 ChatGPT / Claude / Gemini 等服务的可用性参考（可用 / 受限 / 不可用 / 待确认）。

结果**只描述网络环境**，不代表账号登录、订阅资格或平台风控结论。

---

## 一行命令

### 终端检测（推荐入口）

```bash
curl -fsSL https://ipforai.cc/sh | sh
```

先审阅再执行（更安全）：

```bash
curl -fsSL https://ipforai.cc/sh -o /tmp/ipforai-check.sh
less /tmp/ipforai-check.sh
sh /tmp/ipforai-check.sh -y
```

常用参数：

```bash
# 跳过确认
curl -fsSL https://ipforai.cc/sh | sh -s -- -y

# 指定 IP（仅画像与环境质量分，不含本机 AI 链路探测）
curl -fsSL https://ipforai.cc/sh | sh -s -- -y 8.8.8.8

# 详细输出
curl -fsSL https://ipforai.cc/sh | sh -s -- -y -d
```

> **权威脚本地址始终是官网** `https://ipforai.cc/sh`。本仓库中的 `check.sh` 为镜像副本，便于审阅与 star；请以官网版本为准。

### 开发者 JSON

```bash
# 当前出口（一次连接只填一个地址族）
curl -fsSL https://ipforai.cc/json

# 指定 IP
curl -fsSL "https://ipforai.cc/json?ip=8.8.8.8"

# 分别看 IPv4 / IPv6 出口
curl -4 -fsSL https://ipforai.cc/json
curl -6 -fsSL https://ipforai.cc/json
```

字段说明见 [docs/api.zh.md](./docs/api.zh.md)（[English](./docs/api.md)），示例响应见 [examples/sample.json](./examples/sample.json)。

### 网页

打开 [https://ipforai.cc](https://ipforai.cc) 使用完整面板与排查指南。

---

## 能做什么

| 能力 | 说明 |
|------|------|
| 出口画像 | 地理位置、ASN、网络类型、接入形态、路由属性 |
| 风险信号 | 代理相关风险档位、Tor 出口等（有数据时） |
| 环境质量分 | 网络环境参考分，**不是** AI 账号分 |
| AI 可用性参考 | 与官网底部一致：可用 / 受限 / 不可用 / 待确认 |
| 终端链路探测 | CLI 在本机出口下探测公开入口与分流（指定 IP 时不跑链路） |

## 明确不做什么

- 不判断账号是否会被封、能否登录、订阅是否有效
- 不提供「纯净度 / 防封 / 解锁」承诺
- 不把任意 IP 的字符串当成「从该 IP 真实访问 AI」的连通探测（指定 IP 只查画像）

---

## 依赖与边界

- **CLI**：POSIX `sh` + `curl`；只读检测，不写系统配置、不安装软件、不需要 API Key
- **JSON / CLI 画像**：请求 [ipforai.cc](https://ipforai.cc) 后端；离线库与规则由官网维护
- 会创建临时目录并在退出时删除
- 一次 TCP 请求只能看到一个源地址族；双栈请 `-4` / `-6` 各查一次

---

## 仓库结构

```text
.
├── README.md / README_EN.md
├── LICENSE
├── check.sh                 # 与官网 /sh 同步的镜像
├── docs/api.zh.md / api.md  # /json 说明
└── examples/sample.json     # 示例响应（单次请求仅一侧有值）
```

### 发布到 GitHub 时建议

- **Description：** AI 网络环境检测：终端一行命令 + JSON API（ipforai.cc）
- **Topics：** `ip` `ai` `chatgpt` `claude` `shell` `network` `json-api` `ipv4` `ipv6`
- **Website：** `https://ipforai.cc`

---

## 与官网的关系

| 入口 | 地址 |
|------|------|
| 网站 | https://ipforai.cc |
| 终端脚本 | https://ipforai.cc/sh |
| JSON API | https://ipforai.cc/json |
| 方法说明 | https://ipforai.cc/about |
| 本仓库 | 文档、示例与脚本镜像，用于发现与传播 |

本仓库 **不包含** 离线 IP 数据库与后端服务源码；检测能力以官网在线服务为准。

---

## 更新

- 脚本版本以运行输出中的版本号及响应头 `X-IP-for-AI-Check-Version` 为准（当前镜像：`v2.1`）
- JSON 模式：`X-IP-for-AI-Schema: json-v1`；**单次 `/json` 只填一个地址族**，`dualStack` 多为 `false`
- 更新镜像：`curl -fsSL https://ipforai.cc/sh -o check.sh`

---

## License

[MIT](./LICENSE)
