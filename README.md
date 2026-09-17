# 自建 VPS 访问海外大模型 · 完整实战指南

> 从选商家到稳定运行，包含 **13 个真实踩坑** 与源码级排查过程。
> 面向：需要用海外大模型（ChatGPT / Claude / Gemini / Codex）**工作**的人。
> 预算参考：**≈¥40/月**（$32/季）。

---

## 这份指南和别的教程有什么不同

网上大多数教程只教你"怎么装"。这份指南额外记录了两样东西：

| | 内容 |
|---|---|
| **① 真实踩坑** | 13 个问题，每个都有**现象 → 根因 → 定位方法 → 修复**。其中 3 个是会在你服务器上直接报错的配置陷阱，2 个是官方文档都没写清的坑 |
| **② 量化验证** | 所有结论都有实测数据。比如"代理延迟 4878ms → 197ms"这种 24 倍差距，是怎么通过一个 DNS 配置改出来的 |

**核心结论先行**：自建 VPS 的价值是 **独享 + 固定 + 少切换** 的 IP，而**不是**"变成住宅 IP"。理解这一点，能帮你避免 80% 的无效投入。

---

## 目录

| 文档 | 内容 |
|------|------|
| [docs/01-采购指南.md](docs/01-采购指南.md) | 商家筛选标准、线路选择逻辑、候选池对比、买前必查清单 |
| [docs/02-部署指南.md](docs/02-部署指南.md) | VPS 端部署、客户端配置、WSL 打通 |
| [docs/03-验证清单.md](docs/03-验证清单.md) | 六阶段可勾选验证清单 |
| [docs/04-踩坑与排查手册.md](docs/04-踩坑与排查手册.md) | **13 个坑的完整排查过程**（技术含量最高） |
| [docs/05-性能与安全审计.md](docs/05-性能与安全审计.md) | 资源占用、流量归因、异常排查方法 |
| [docs/06-常见问题.md](docs/06-常见问题.md) | FAQ |
| [scripts/deploy-singbox.sh](scripts/deploy-singbox.sh) | **一键部署脚本**（已在 Ubuntu 22.04 实测通过） |
| [configs/](configs/) | 脱敏的客户端配置模板 |

---

## 快速开始

### 前置条件

- 一台海外 VPS（Ubuntu 22.04 / 24.04，root 权限）
- 本地：Clash Verge Rev（图形化，推荐）或 sing-box 客户端
- **不需要**：域名、SSL 证书、备案

### 三步走

```bash
# ① 上传脚本
scp scripts/deploy-singbox.sh root@YOUR_VPS_IP:/root/

# ② 登录并执行
ssh root@YOUR_VPS_IP
sudo bash /root/deploy-singbox.sh

# ③ 下载自动生成的客户端配置
scp -r root@YOUR_VPS_IP:/root/client-configs ./
```

脚本会自动完成：

```
系统检查 → 开启 BBR → 网络调优 → 安装 sing-box（官方源）
→ 生成 UUID / Reality 密钥 / 自签证书
→ 写入双协议配置（Hysteria2 + VLESS-Reality）
→ sing-box check 校验配置  ← 校验不过不会启动
→ 配置 ufw 防火墙 + fail2ban
→ 设置每 20 天自动更新
→ 输出客户端配置到 /root/client-configs/
```

### 部署完成后

按 [docs/03-验证清单.md](docs/03-验证清单.md) 逐项验证。**关键的三条**：

```bash
systemctl is-active sing-box          # 应为 active
ss -tulnp | grep sing-box             # 应看到 443/tcp 和 8443/udp
curl -s https://ipinfo.io/json        # 出口应为你的 VPS IP
```

---

## 方案选型

### 协议：为什么是 Hysteria2 + VLESS-Reality 双栈

| 协议 | 优势 | 适用场景 |
|------|------|---------|
| **Hysteria2** | 基于 QUIC + 内置 BBR，弱网/高丢包下速度最好 | 家宽日常、大流量 |
| **VLESS-Reality** | 借用真实大站 TLS 握手特征，抗主动探测 | 移动网络、敏感时期 |

两者互补：客户端配置 `fallback` 策略组，HY2 不通自动切 Reality。

### 为什么不用 WireGuard / Trojan

- **WireGuard**：特征极其明显（固定 UDP 端口 + 握手包特征），容易被识别
- **Trojan**：技术上没失效，但依赖域名+证书，且抗主动探测能力弱于 Reality
- **Reality 的核心优势**：**不需要域名、不需要证书**，直接借用 `www.microsoft.com` 这类大站的 TLS 特征

### 机房：延迟 vs 风控的取舍

| 机房 | 到国内延迟 | AI 风控友好度 |
|------|-----------|--------------|
| 香港 | 30–50ms | ⚠️ 部分 IP 段不友好 |
| 东京/大阪 | 50–90ms | ⚠️ 尚可 |
| **洛杉矶（美西）** | **150–220ms** | ✅ **最友好** |

**要"美国原生 IP"就选洛杉矶**——它是离中国最近的美国机房，是"美国 IP + 尽可能低延迟"的唯一解。

---

## 13 个坑速览

| # | 问题 | 根因 | 章节 |
|---|------|------|------|
| 1 | SSH 密钥认证一直 `Permission denied` | PowerShell 把空口令 `""` 当字面量，密钥被 bcrypt 加密 | [04](docs/04-踩坑与排查手册.md#1-ssh-密钥认证失败) |
| 2 | `sing-box check` 通过但启动 FATAL | 1.14 **移除**了旧版 DNS server 格式 | [04](docs/04-踩坑与排查手册.md#2-dns-server-格式在-114-被移除) |
| 3 | 同上 | 1.14 **强制要求** `route.default_domain_resolver` | [04](docs/04-踩坑与排查手册.md#3-缺少-default_domain_resolver) |
| 4 | `detour to an empty direct outbound` | `"detour": "direct"` 指向内置空 direct | [04](docs/04-踩坑与排查手册.md#4-detour-指向空-direct) |
| 5 | WSL 连不上 Windows 代理 | Windows 防火墙有**自动生成的 Block 规则** | [04](docs/04-踩坑与排查手册.md#5-wsl-连不上-windows-代理) |
| 6 | PS 脚本报 `MissingEndCurlyBrace` | PS 5.1 按 ANSI 读 UTF-8 无 BOM 文件 | [04](docs/04-踩坑与排查手册.md#6-powershell-脚本编码陷阱) |
| 7 | Clash 端口改了不生效 | **应用级设置优先于 profile** | [04](docs/04-踩坑与排查手册.md#7-clash-端口设置被覆盖) |
| 8 | **代理延迟高达 4878ms** | DNS 配了 `1.1.1.1`，国内直连不稳定 | [04](docs/04-踩坑与排查手册.md#8-延迟-4878ms-到-197ms) |
| 9 | 开机自启"设置是假的" | `enable_auto_launch: true` 不写注册表 | [04](docs/04-踩坑与排查手册.md#9-开机自启未生效) |
| 10 | Codex 桌面端「重新连接 1/5」 | Rust 后端默认不读系统代理 | [04](docs/04-踩坑与排查手册.md#10-codex-桌面端连不上) |
| 11 | Node CLI 不读 `HTTPS_PROXY` | Node 需 `NODE_USE_ENV_PROXY=1` | [04](docs/04-踩坑与排查手册.md#11-node-不读代理环境变量) |
| 12 | 误判「Cloudflare 封了 IP」 | 实际是缺 `originator` 请求头 | [04](docs/04-踩坑与排查手册.md#12-cloudflare-403-的真相) |
| 13 | **VPS 流量约 100GB/天** | 全局模式让国内流量也绕道美国 | [04](docs/04-踩坑与排查手册.md#13-全局模式导致流量浪费) |

---

## 核心知识速查

### Node 程序代理（最容易踩的坑）

```bash
# Node.js 原生不读 HTTP_PROXY / HTTPS_PROXY
# 必须设置这个（Node 24+）：
export NODE_USE_ENV_PROXY=1
```

受影响工具：`claude`、`codex`、以及任何 Node 写的 CLI。

### Clash 的 DNS 配置（决定延迟）

```yaml
dns:
  enable: true
  enhanced-mode: fake-ip
  respect-rules: true
  # ✅ 全部用国内 DNS —— fake-ip 模式下不影响国外访问
  nameserver:
    - https://223.5.5.5/dns-query
    - https://119.29.29.29/dns-query
  # ❌ 不要在这里写 1.1.1.1 / 8.8.8.8（国内直连不稳定，会卡数秒）
```

### 代理模式必须用 rule

```
rule 模式   : 国内直连 + 国外走代理   ← 正确
global 模式 : 全部走代理（含国内）    ← 慢 + 浪费流量
```

---

## 实测性能数据

| 指标 | 数值 |
|------|------|
| 平均延迟（美西优化线路） | **193–197 ms** |
| 连续 30 次请求失败率 | **0%** |
| 抖动 | 15.5 ms |
| 代理栈内存占用 | 137 MB（占 31.4 GB 的 0.43%） |
| 代理栈 CPU 占用 | ≈0.02% |
| VPS sing-box 内存 | 83.9 MB |
| VPS 系统负载 | 0.05 |

---

## 已知限制

| 限制 | 说明 |
|------|------|
| `chatgpt.com` 网页版可能 403 | Cloudflare 对非浏览器 TLS 指纹的挑战。**API 不受影响**（`api.openai.com` 返回 401 正常） |
| Codex 桌面端需额外配置 | 见 [坑 10](docs/04-踩坑与排查手册.md#10-codex-桌面端连不上) |
| 自建 ≠ 住宅 IP | 机房 IP 仍有被风控可能。真正的价值是**固定 + 独享 + 少切换** |
| 需要自己维护 | 系统更新、IP 被封后换 IP、流量监控 |

---

## 免责声明

本项目仅供**技术学习与个人合规使用**。请确保你的使用场景符合当地法律法规。
自建代理涉及服务器运维，请自行承担风险。作者不对使用本指南产生的任何后果负责。

---

## 参考来源

| 内容 | 来源 |
|------|------|
| AI 出口选择策略、预算分档 | [VPSKnow 固定IP/住宅IP/ISP IP 指南](https://vpsknow.com/guides/ai-fixed-ip-residential-isp-guide) |
| sing-box 官方文档 | [sing-box.sagernet.org](https://sing-box.sagernet.org/) |
| Reality 技术说明 | [XTLS/Reality](https://github.com/XTLS/Reality) |
| Hysteria2 官方文档 | [v2.hysteria.network](https://v2.hysteria.network/) |
| Codex 后端不读系统代理（源码级定位） | [cg689/codex-reconnect-fix](https://github.com/cg689/codex-reconnect-fix) |
| 桌面端代理变量变空 | [openai/codex#37662](https://github.com/openai/codex/issues/37662) |
| Cloudflare 403 challenge 分析 | [openai/codex#39324](https://github.com/openai/codex/issues/39324) |
| `originator` 头绕过 CF 挑战 | [NousResearch/hermes-agent#6391](https://github.com/NousResearch/hermes-agent/pull/6391) |
| CN2 GIA / AS9929 / CMIN2 线路对比 | [VPS Moon](https://www.vpsmoon.com/cn2-gia-hosting/cn2-gia-vps-recommendation) |
| 自建 vs 机场实测对比 | [Sagasu 自建教程](https://www.sagasu.art/posts/complete-vpn-tutorial-for-beginners-optimal-version) |
| VLESS + Reality 搭建 | [cholf5/random#38](https://github.com/cholf5/random/issues/38) |

---

## License

MIT
