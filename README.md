# 用 AI Agent 搭建 VPS 代理节点

> 一份 **Agent 协作实操记录**：从选型到上线，全程由 AI Agent 执行、验证、纠错。
> 完整保留 13 次故障定位、2 次主动回滚，以及 Agent 自身的 3 处误判修正。

---

## 为什么记录这个

AI Agent 已经能操作服务器、执行命令、编排部署。但**能用**和**可信**之间隔着一整套工作方法。

这份记录想回答一个问题：

> 当 Agent 拥有 root 权限、能改配置、能重启服务时，**怎样让它做的事可以被信任？**

答案不是"用更强的模型"，而是把它放进一套**可验证的工作流**里。下面是实际总结出的六条，每条都配本次部署中的真实案例。

---

## 六条 Agent 协作原则

### 1. 部署前用真实运行时校验配置

**不要相信"文档看起来对"。** 让 Agent 下载目标版本的官方二进制，把配置喂给它校验。

> **本次案例**
> 部署脚本写完、`sing-box check` 通过。但 Agent 进一步用真实的 sing-box v1.14.1 二进制逐项验证，抓出 **3 个会导致启动失败的配置错误**：
>
> - 1.14 **移除**了旧版 DNS server 格式（`address` 字段）
> - 1.14 **强制要求** `route.default_domain_resolver`
> - `"detour": "direct"` 指向内置空出站
>
> 这三个都是 `check` 通过、但运行时 FATAL 的类型。详见 [故障 2–4](docs/04-故障排查手册.md)。

**可复用的做法**：让 Agent 把"实际会生成的配置"提取出来喂给真实二进制，而不是校验手写的近似版本。

### 2. 每项优化都要有前后测量，退化就回滚

**没有测量就没有优化。** 要求 Agent 对每个改动给出改动前后的数据。

> **本次案例**
> Agent 发现 DNS 检测报告"泄露"，提出把 DNS 查询改为经代理。改动后延迟从 **189 ms 涨到 860 ms**。Agent 没有辩解，直接回滚并记录结论。
>
> 另一个反向案例：同样通过测量，把延迟从 **4878 ms 降到 197 ms**（DNS 解析路径问题）。
>
> 两次都保留了原始数据。详见 [故障 8](docs/04-故障排查手册.md)。

**可复用的做法**：把"改前测、改后测、退化即回滚"作为硬性要求写进任务。

### 3. 用对照实验代替推测

**当一个变量无法确定时，构造只改变它的对照组。**

> **本次案例**
> SSH 密钥认证持续失败。Agent 没有停留在"可能是网络问题"的猜测上，而是让 **VPS 用同一把私钥登录它自己的回环地址**：
>
> - 回环（完全不经网络）也失败 → **排除网络因素**
> - 最终定位到 PowerShell 生成密钥时，`-N '""'` 被当成字面量口令，导致私钥被 bcrypt 加密
>
> 详见 [故障 1](docs/04-故障排查手册.md)。

**可复用的做法**：要求 Agent 在给出结论前，明确指出"这个结论排除了哪些可能，用什么实验排除的"。

### 4. 追到源码，不要停在搜索引擎

**社区答案经常是错的或不完整的。** 让 Agent 去读上游源码和 issue。

> **本次案例**
> 桌面客户端间歇断连，社区普遍归因到"WebSocket 问题"。Agent 追到源码位置：
>
> ```
> codex-rs/http-client/src/outbound_proxy.rs
>   默认策略 ReqwestDefault    → 只读环境变量
>   可选策略 RespectSystemProxy → 读系统代理（默认关闭）
> ```
>
> 找到真正的开关 `features.respect_system_proxy`，而不是跟着社区改 WebSocket 设置。
>
> 另一例：一个 403 错误被 Agent **误判为"IP 被封"**，后来通过补齐 `originator` 请求头做对照实验，证明是请求头缺失。详见 [故障 10](docs/04-故障排查手册.md)、[故障 12](docs/04-故障排查手册.md)。

**可复用的做法**：要求 Agent 给出结论时附上**证据类型**（源码 / 实测 / 社区说法），并标出置信度。

### 5. 审计要找"不合理"，不只是找"报错"

**系统不会为静默的性能损失报警。**

> **本次案例**
> 部署完成、一切正常。Agent 做全量审计时发现：VPS 流量约 **100 GB/天**，按此推算 2TB 配额 20 天耗尽。
>
> 根因是代理被误设为 global 模式，导致国内流量也绕行境外。改为 rule 模式后：
>
> | 指标 | global | rule |
> |------|--------|------|
> | 国内站点延迟 | 1674 ms | **236 ms** |
> | 20 次国内请求的境外流量 | 持续占用 | **0.121 MB** |
>
> 详见 [故障 13](docs/04-故障排查手册.md)。

**可复用的做法**：让 Agent 建立**基线**（资源占用、流量速率、错误计数），之后任何偏离基线的都值得追问。

### 6. 记录 Agent 自身的误判

**Agent 会犯错。把它定位错的过程记下来，比只记正确结论更有价值。**

> **本次案例（Agent 的 3 处误判）**
>
> | 误判 | 更正方式 |
> |------|---------|
> | 断言"IP 被 Cloudflare 标记"，建议换 IP | 补请求头做对照实验，证明是请求头缺失 |
> | 报告"延迟优秀 1ms" | 发现测的是本机到本地代理客户端，非真实延迟 |
> | 断言"存在 DNS 泄露" | 用 tcpdump 抓包，确认解析实际发生在服务端 |
>
> 三处都保留在文档中，标注为更正记录。

**可复用的做法**：要求 Agent 明确区分「已验证」和「推测」，并在发现误判时**主动更正而非静默修改**。

> 三处误判的完整记录（含更正实验）见 [04 · 故障排查手册 · 附 B](docs/04-故障排查手册.md#附-bagent-误判记录)。

---

## 实操：生成的技术资产

本项目不只是文档，Agent 产出的可复用资产：

| 资产 | 说明 |
|------|------|
| [scripts/deploy-singbox.sh](scripts/deploy-singbox.sh) | 一键部署脚本，含配置自校验、BBR、防火墙、fail2ban、自动更新 |
| [docs/04-故障排查手册.md](docs/04-故障排查手册.md) | 13 个故障的完整定位过程 + 方法论摘要 |
| [docs/05-性能与安全审计.md](docs/05-性能与安全审计.md) | 可复现的审计脚本与判定基准 |
| [configs/](configs/) | 客户端配置模板（Clash / sing-box） |

---

## 技术方案概要

被搭建出来的东西本身：

```
客户端                         服务端
┌──────────────────┐          ┌─────────────────────┐
│ Clash Verge Rev  │          │  sing-box 1.14      │
│  TUN + 系统代理   │ ───────► │  Hysteria2  UDP/8443 │
│  url-test 选节点  │          │  VLESS-Reality TCP/443│
└──────────────────┘          │  BBR + ufw + fail2ban│
                              └─────────────────────┘
       规则分流: GEOIP,CN,DIRECT / MATCH,PROXY
```

| 项目 | 方案 |
|------|------|
| 协议 | Hysteria2（QUIC，弱网吞吐）+ VLESS-Reality（复用真实 TLS 特征，抗探测） |
| 分流 | 规则模式，国内直连 |
| DNS | fake-ip + 国内 nameserver（解析位置在服务端，本地只影响速度） |
| 域名/证书 | **不需要** |

完整实测数据见 [README 实测数据](#实测数据) 下方的技术文档。

### 实测结果

| 指标 | 数值 |
|------|------|
| 出口延迟（15 次采样） | 最小 172 / 平均 **189** / 最大 244 ms |
| 持续请求失败率（30 次） | **0 %** |
| 抖动 | 15.5 ms |
| 代理栈内存（客户端） | 137 MB |
| 代理栈 CPU（客户端） | ≈ 0.02 % |
| 服务端 sing-box 内存 | 83.9 MB |

---

## 目录

| 文档 | 内容 |
|------|------|
| [01 · 选型与采购](docs/01-选型与采购.md) | 线路分类、机房取舍、商家对比、验真方法 |
| [02 · 部署与客户端](docs/02-部署与客户端.md) | 服务端部署、双协议配置、客户端接入、WSL 打通 |
| [03 · 验证清单](docs/03-验证清单.md) | 六阶段验证流程与判定标准 |
| [04 · 故障排查手册](docs/04-故障排查手册.md) | **13 个故障的完整定位过程** |
| [05 · 性能与安全审计](docs/05-性能与安全审计.md) | 审计脚本、基线判定、流量归因 |
| [06 · 常见问题](docs/06-常见问题.md) | FAQ |

---

## 快速开始

```bash
scp scripts/deploy-singbox.sh root@YOUR_VPS_IP:/root/
ssh root@YOUR_VPS_IP
sudo bash /root/deploy-singbox.sh
```

脚本流程：系统检查 → BBR 调优 → 安装 sing-box → 生成密钥 → 写配置 → **自校验** → 防火墙 → fail2ban → 自动更新 → 输出客户端配置。

环境要求：Ubuntu 22.04 / 24.04，root 权限。**不需要域名、证书、备案。**

---

## 适用与边界

**这套方法适用**

- 需要 Agent 执行具有副作用的操作（改配置、重启服务、`sudo`）
- 需要结论可追溯到证据
- 愿意为"验证"付出额外步骤

**不适用**

- 期望 Agent 给出结论即可、不需要验证过程
- 纯只读的分析任务（不需要这套约束）

---

## 参考来源

| 内容 | 来源 |
|------|------|
| sing-box 官方文档 | [sing-box.sagernet.org](https://sing-box.sagernet.org/) |
| Reality 协议说明 | [XTLS/Reality](https://github.com/XTLS/Reality) |
| Hysteria2 文档 | [v2.hysteria2.network](https://v2.hysteria.network/) |
| 回国线路对比 | [VPS Moon](https://www.vpsmoon.com/cn2-gia-hosting/cn2-gia-vps-recommendation) |
| 出口选择策略 | [VPSKnow](https://vpsknow.com/guides/ai-fixed-ip-residential-isp-guide) |
| VLESS + Reality 部署 | [cholf5/random#38](https://github.com/cholf5/random/issues/38) |
| 双协议部署实践 | [Sagasu](https://www.sagasu.art/posts/complete-vpn-tutorial-for-beginners-optimal-version) |
| 客户端代理行为（源码级） | [cg689/codex-reconnect-fix](https://github.com/cg689/codex-reconnect-fix) |
| 代理环境变量兼容性 | [openai/codex#37662](https://github.com/openai/codex/issues/37662) |

---

## License

MIT
