# VPS 自建代理节点实战指南

> 从选型、部署到性能调优的完整工程实践。
> 基于 **sing-box 1.14** 实现 Hysteria2 + VLESS-Reality 双协议，含 13 个真实故障的定位与修复过程。

---

## 关于本指南

现有教程大多止步于"命令能跑通"。本指南补充两个通常缺失的部分：

**故障工程**
13 个实际遇到的问题，每个按 `现象 → 根因 → 定位方法 → 修复 → 验证` 组织。
其中 3 个是配置语法完全正确、`check` 通过但运行时 FATAL 的陷阱；2 个涉及官方文档未明确说明的行为。

**量化验证**
所有性能结论均附实测数据与复现方法。例如本地 DNS 策略调整带来的延迟差异：

| DNS 策略 | 实测平均延迟 |
|---------|-------------|
| `nameserver` 使用 1.1.1.1（经代理） | 860 ms |
| `nameserver` 使用国内 DNS + fake-ip | **189 ms** |

差异来源不是网络质量，而是解析路径。

---

## 核心结论

**自建节点的价值在于「独享 + 固定 + 可控」，而非 IP 类型本身。**

对目标服务的风控体系而言，一个长期稳定、不与他人共享、地理位置一致的出口，其可信度高于频繁切换的共享 IP。理解这一点可以避免绝大部分无效投入——包括为追求"住宅 IP"标签而支付数倍成本。

---

## 目录

| 文档 | 内容 |
|------|------|
| [01 · 选型与采购](docs/01-选型与采购.md) | 线路分类（CN2 GIA / AS9929 / CMIN2）、机房取舍、商家对比、验真方法 |
| [02 · 部署与客户端](docs/02-部署与客户端.md) | 服务端部署、双协议配置、客户端接入、WSL / 局域网打通 |
| [03 · 验证清单](docs/03-验证清单.md) | 六阶段验证流程与判定标准 |
| [04 · 故障排查手册](docs/04-故障排查手册.md) | **13 个真实故障的完整排查过程** |
| [05 · 性能与安全审计](docs/05-性能与安全审计.md) | 资源基线、流量归因、DNS/WebRTC 泄露检测 |
| [06 · 常见问题](docs/06-常见问题.md) | FAQ |
| [scripts/deploy-singbox.sh](scripts/deploy-singbox.sh) | 一键部署脚本（Ubuntu 22.04 实测通过） |
| [configs/](configs/) | 客户端配置模板 |

---

## 快速开始

### 环境要求

| 项目 | 要求 |
|------|------|
| 服务端 | 海外 VPS，Ubuntu 22.04 / 24.04，root 权限 |
| 客户端 | Clash Verge Rev（推荐）或 sing-box |
| 域名 / 证书 | **不需要** |
| 备案 | **不需要** |

Reality 复用外部站点的 TLS 特征，Hysteria2 使用自签证书（协议自带加密层），因此无需域名与证书配置。

### 部署

```bash
scp scripts/deploy-singbox.sh root@YOUR_VPS_IP:/root/
ssh root@YOUR_VPS_IP
sudo bash /root/deploy-singbox.sh
```

脚本执行流程：

```
系统检查与依赖安装
  → BBR + 网络参数调优
  → 安装 sing-box（官方源）
  → 生成 UUID / Reality x25519 密钥 / 自签证书
  → 写入双协议配置
  → sing-box check 校验（不通过则中止）
  → ufw 防火墙 + fail2ban
  → 每 20 天自动更新任务
  → 输出客户端配置到 /root/client-configs/
```

### 部署后验证

```bash
systemctl is-active sing-box          # active
systemctl is-enabled sing-box         # enabled
ss -tulnp | grep sing-box             # 443/tcp + 8443/udp
curl -s https://ipinfo.io/json        # 出口 IP 应为 VPS IP
```

完整验证流程见 [03 · 验证清单](docs/03-验证清单.md)。

---

## 技术方案

### 协议选型

采用双协议并行，客户端以 `url-test` 策略组自动选择：

| 协议 | 传输层 | 优势 | 适用场景 |
|------|--------|------|---------|
| **Hysteria2** | QUIC / UDP 8443 | 内置 BBR，弱网与高丢包环境下吞吐最优 | 家庭宽带、大流量 |
| **VLESS-Reality** | TCP 443 | 复用真实站点 TLS 握手特征，抗主动探测 | 移动网络、严格审查环境 |

选择依据：

- **不选 WireGuard** —— 固定 UDP 端口与握手特征明显，易被识别
- **不选 Trojan** —— 依赖域名与证书，抗主动探测能力弱于 Reality
- **Reality 的优势** —— 无需自有域名，直接借用 `www.microsoft.com` 等站点的 TLS 特征

### 分流策略

```
GEOIP,CN,DIRECT     国内流量直连
MATCH,PROXY         其余走代理
```

**必须使用规则（rule）模式。** 全局（global）模式下分流规则失效，国内流量将绕行境外节点——实测延迟从 236 ms 升至 1674 ms，且产生约 100 GB/天的额外流量消耗。

### DNS 策略

```yaml
dns:
  enhanced-mode: fake-ip
  respect-rules: true
  nameserver:
    - https://223.5.5.5/dns-query       # 国内 DNS
    - https://119.29.29.29/dns-query
```

fake-ip 模式下客户端持有虚拟 IP，真实域名经协议传递至服务端解析。因此本地 DNS 仅影响解析速度，不改变境外站点的解析位置。将 `nameserver` 指向境外 DNS（即便标记 `#PROXY`）会使每次解析引入跨境往返，实测延迟由 189 ms 升至 860 ms。

### 网络参数

服务端脚本自动配置：

```
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max / wmem_max = 33554432
```

---

## 实测数据

部署环境：ZgoCloud 洛杉矶，AMD EPYC / 3 GB RAM，9929 + CMIN2 线路；客户端位于中国联通家宽。

| 指标 | 数值 |
|------|------|
| 出口延迟（15 次采样） | 最小 172 ms / 平均 **189 ms** / 最大 244 ms |
| 持续请求失败率（30 次） | **0 %** |
| 抖动 | 15.5 ms |
| 国内站点延迟（直连验证） | 百度 192 ms / 淘宝 159 ms |
| 代理栈内存占用（客户端） | 137 MB |
| 代理栈 CPU 占用（客户端） | ≈ 0.02 % |
| sing-box 内存占用（服务端） | 83.9 MB |
| 服务端系统负载 | 0.05 |

### 流量归因验证

在规则模式下产生 20 次国内站点请求，观测服务端网卡增量：

```
接收增量：0.083 MB
发送增量：0.039 MB
合计：    0.121 MB
```

国内流量未经境外节点。

---

## 13 个故障索引

| # | 现象 | 根因类别 |
|---|------|---------|
| 1 | SSH 密钥认证持续失败 | 密钥生成（口令编码） |
| 2 | `check` 通过但启动 FATAL | 配置格式变更（1.14 移除旧 DNS 格式） |
| 3 | `missing default_domain_resolver` | 配置格式变更（1.14 强制要求） |
| 4 | `detour to an empty direct outbound` | 配置语义 |
| 5 | 局域网/WSL 无法访问代理 | 主机防火墙策略 |
| 6 | PowerShell 脚本解析错误 | 脚本文件编码 |
| 7 | 修改配置不生效 | 多层级配置优先级 |
| 8 | 代理延迟 4878 ms | DNS 解析路径 |
| 9 | 开机自启未生效 | 自启机制未实际写入 |
| 10 | 桌面客户端间歇断连 | 应用默认不读取系统代理 |
| 11 | Node 程序不遵循代理环境变量 | 运行时行为 |
| 12 | Cloudflare 403 挑战 | 请求头缺失（非 IP 信誉） |
| 13 | 流量异常（约 100 GB/天） | 分流模式配置 |

详细排查过程见 [04 · 故障排查手册](docs/04-故障排查手册.md)。

---

## 适用与不适用

**适用**

- 需要稳定、可控、独享的境外出口
- 需要 DNS 与流量路径完全可控
- 具备基础 Linux 运维能力，或愿意按文档操作

**不适用**

- 期望零配置、开箱即用（建议使用商业代理服务）
- 需要住宅 IP 属性（需另择方案，成本显著更高）
- 需要规避平台服务条款的场景

---

## 已知限制

| 限制 | 说明 |
|------|------|
| 出口为数据中心 IP | 部分站点会触发人机验证。多数情况下可通过补齐标准客户端请求头解决，见故障 12 |
| 需自行维护 | 系统更新、证书轮换、IP 被封后更换 |
| 单点故障 | 建议保留备用出口 |

---

## 参考来源

| 内容 | 来源 |
|------|------|
| sing-box 官方文档 | [sing-box.sagernet.org](https://sing-box.sagernet.org/) |
| Reality 协议技术说明 | [XTLS/Reality](https://github.com/XTLS/Reality) |
| Hysteria2 官方文档 | [v2.hysteria.network](https://v2.hysteria.network/) |
| 回国线路对比（CN2 GIA / AS9929 / CMIN2） | [VPS Moon](https://www.vpsmoon.com/cn2-gia-hosting/cn2-gia-vps-recommendation) |
| 出口选择策略与预算分档 | [VPSKnow](https://vpsknow.com/guides/ai-fixed-ip-residential-isp-guide) |
| VLESS + Reality 部署 | [cholf5/random#38](https://github.com/cholf5/random/issues/38) |
| sing-box 双协议部署实践 | [Sagasu](https://www.sagasu.art/posts/complete-vpn-tutorial-for-beginners-optimal-version) |
| Codex 客户端代理行为（源码级） | [cg689/codex-reconnect-fix](https://github.com/cg689/codex-reconnect-fix) |
| 代理环境变量与客户端兼容性 | [openai/codex#37662](https://github.com/openai/codex/issues/37662) |
| Cloudflare 挑战与请求头 | [NousResearch/hermes-agent#6391](https://github.com/NousResearch/hermes-agent/pull/6391) |

---

## License

MIT
