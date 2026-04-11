# 🚀 工业级防封静态住宅 IP 中转一键脚本

![Ubuntu](https://img.shields.io/badge/OS-Ubuntu%2022.04-orange?logo=ubuntu)
![License](https://img.shields.io/badge/License-MIT-blue)
![Security](https://img.shields.io/badge/Security-Anti--DNS--Leak-success)

本项目专为 **跨境电商 (TikTok/FB/Amazon)** 及 **外贸业务** 打造。通过深度优化 V2Ray 路由策略，强制远端 DNS 解析，从根源解决 DNS 泄露导致的账号封控问题。

---

## 📋 核心准备工作

在运行脚本前，请务必通过以下官方渠道完成基础设施准备：

### 1. 选购中转服务器 (入口)
推荐使用 **阿里云轻量应用服务器**（系统必选 **Ubuntu 22.04**），海外线路稳定，性价比极高。
* 🔗 [**阿里云轻量服务器 · 特惠注册通道**](https://www.aliyun.com/minisite/goods?userCode=ou12hhzv)

### 2. 获取美国静态住宅 IP (出口)
脚本需要对接 SOCKS5 代理。推荐使用原生住宅 IP，模拟真实海外用户环境，避开 Meta/TK 的风控黑名单：
* 🔗 [**获取美国原生静态住宅 IP (ipipd.com)**](https://ipipd.com?ref=HSMBEEGM)

---

## ⚡ 快速安装

在您的服务器终端执行以下一键安装命令。脚本已适配自适应二维码显示及灵活 UUID 配置。

```bash
bash <(curl -sL [https://raw.githubusercontent.com/v1990901/v2/main/v2ray_relay.sh](https://raw.githubusercontent.com/v1990901/v2/main/v2ray_relay.sh))
```
---

## ✨ 脚本高级特性

* **🛡️ 彻底防 DNS 泄露**：强制拦截 53 端口，所有 DNS 解析请求均通过美国落地端执行。
* **🔑 灵活 UUID 逻辑**：支持**一键回车随机生成**，或**手动输入指定 UUID**，满足不同场景需求。
* **📡 流量嗅探 (Sniffing)**：精准识别 TLS/HTTP 流量目的地，防止被识别为代理流量。
* **📟 自适应二维码**：根据您的终端窗口大小自动渲染二维码，支持手机扫码即连，不占位、不重叠。
* **🚀 内核级加速**：自动开启 BBR 拥塞控制算法，显著降低跨境网络延迟。

---

## ⚙️ 阿里云后台配置 (关键步骤)

安装完成后，请务必完成以下操作，否则无法连通：

### 1. 开启防火墙端口
1. 登录 [阿里云控制台](https://www.aliyun.com/) -> 进入 **“轻量应用服务器”**。
2. 点击 **详情** -> **防火墙** -> **添加规则**。
3. **协议**：选择 `TCP`（如需语音/视频通话，建议同时添加一条 `UDP`）。
4. **端口**：填入您在脚本中设置的端口（默认 `54321`）。

### 2. 配置住宅 IP 白名单
1. 登录您的住宅 IP 服务商（如 [ipipd.com](https://ipipd.com?ref=HSMBEEGM)）后台。
2. 将您 **阿里云服务器的公网 IP** 添加到“授权白名单”中。

---

## 🩺 运营前安全体检 (必做)

在正式登录 TikTok/Meta 账号前，请务必完成以下测试：

1. **DNS 泄露测试**：
   访问 [DNSLeakTest.com](https://www.dnsleaktest.com) 运行 **Standard Test**。
   - **✅ 合格**：服务器地理位置全部显示为美国（United States）。
   - **❌ 风险**：如果出现中国（China）服务器，说明环境异常，严禁登录账号！

2. **匿名度检查**：
   访问 [Whoer.net](https://whoer.net)，确保 **Anonymity** 评分在 90% 以上。

---

## 🆘 常见问题排查

| 报错现象 | 原因及解决方法 |
| :--- | :--- |
| **404 Not Found** | 请检查安装命令 URL 是否完整，确保服务器能正常访问 GitHub。 |
| **\r: command not found** | 脚本混入 Windows 换行符。请务必使用上方的 `curl` 命令直接安装。 |
| **连接成功但无法上网** | 1. 检查阿里云防火墙；2. 检查住宅 IP 侧是否已加白名单。 |

---

### ⚖️ 免责声明
本脚本仅供学习交流及正当跨境贸易业务使用，请务必在遵守当地法律法规的前提下使用。

