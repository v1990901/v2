# 🚀 V2Ray 静态住宅 IP 中转一键脚本

![Ubuntu](https://img.shields.io/badge/OS-Ubuntu%2022.04-orange?logo=ubuntu)
![License](https://img.shields.io/badge/License-MIT-blue)

本项目专为 **跨境电商 (TikTok/FB/Amazon)** 及 **外贸业务** 打造。通过阿里云轻量服务器中转，挂载美国原生静态住宅 IP，为您提供纯净、不跳 IP 的海外办公网络环境。

---

## 📋 核心准备工作

在运行脚本前，请务必通过以下官方渠道完成基础设施准备：

### 1. 选购中转服务器
推荐使用 **阿里云轻量应用服务器**（Ubuntu 22.04 系统），海外线路稳定，性价比极高。
* 🔗 [**阿里云轻量服务器 · 特惠注册通道**](https://www.aliyun.com/minisite/goods?userCode=ou12hhzv)

### 2. 获取美国静态住宅 IP
脚本需要对接 SOCKS5 代理出口。推荐使用以下平台获取原生住宅 IP，模拟真实海外用户环境：
* 🔗 [**获取美国原生静态住宅 IP (ipipd.com)**](https://ipipd.com?ref=HSMBEEGM)

---

## ⚡ 快速安装

在您的服务器终端执行以下一键安装命令：

```bash
bash <(curl -sL [https://raw.githubusercontent.com/v1990901/v2/main/v2ray_relay.sh](https://raw.githubusercontent.com/v1990901/v2/main/v2ray_relay.sh))

