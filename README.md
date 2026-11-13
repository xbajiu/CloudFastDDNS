# 🌐 CloudFastDDNS

> 🚀 基于 [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) (`cfst`) 与 [lee1080/CloudflareSpeedTestDDNS](https://github.com/lee1080/CloudflareSpeedTestDDNS) (`main` 分支) 深度改造优化的 **Docker 可视化 Web 版优选 IP 自动 DDNS 工具**。

支持 **IPv4 / IPv6 优选**、**反代 IP 优选**、**Cloudflare（单 IP / 一域名多 IP）**、**DNSPod**、**本地 `/etc/hosts` 同步**、**`crond` 定时调度**、**多渠道消息推送** 以及 **端口 `9909` Web 控制台**。

---

## ✨ 核心特性

### 1. 可视化 Web 控制台（默认端口 `9909`）
- **4 大模块化表单**：将 `config.conf` 完整结构化为 **基础与工作模式**、**DNS 服务商配置**、**CFST 测速参数**、**消息推送通知**，支持一键预设与密码显隐切换。
- **智能参数互斥**：
  - 关闭定时运行自动锁定 `TIMING`；
  - 开启反代 IP 自动锁定 `IPv4` 并禁用 `-tll`；
  - `TCPing` 模式下自动禁用 `HTTPing` 专属参数（`httping_code` / `cfcolo`）；
  - 根据所选 DNS 服务商隔离对应配置面板，**一域名多 IP (`MULTI_IP`)** 位于基础配置栏便于随时切换。
- **运行控制与结果监控**：支持 **保存并开始运行**、**手动终止任务**、**实时状态与清洗后测速进度条日志**、**优选 IP 结果榜及一键复制**，并支持浅色 / 深色主题切换。

### 2. 新版 `cfst` 自动适配 & 首次部署按需拉取
- 适配 `XIU2/CloudflareSpeedTest` 新版 Releases 命名与目录结构（`cfst_linux_amd64.tar.gz` / `cfst_linux_arm64.tar.gz` / `cfst_linux_mips64.tar.gz`，自动兼容 `v2.3.5` 及后续版本）。
- 系统依赖（`python3`、`bash`、`jq`、`curl`、`tar`、`dcron` 等）在镜像构建阶段一次性集成。
- 容器首次启动时按需下载 `cfst` 并持久化保存至 `/opt/cloudfastddns/cf_ddns/cfst`（同时生成 `.ran_before` 标记），**后续点击运行或重启容器不再重复拉取**。
- 内置 GitHub 代理地址设置（默认 `https://gh-proxy.com/`），支持在 Web 面板修改或留空直连 GitHub，代理失败自动回退直连下载。

### 3. 安全可靠的 DDNS 更新（修复上游多项缺陷）
- **Cloudflare 单 IP / 一域名多 IP**：仅需邮箱（`x_email`）+ `Global API Key`（`api_key`），运行期自动逐级识别根域名、多级子域名与跨 Zone 多域名；**严格在确认存在有效优选 IP 后再删除/更新旧记录**，避免测速无结果时误删解析导致断网。
- **DNSPod 自动拆分主域与子域**：通过 `Domain.List` / `Domain.Info` 智能识别根域名与多级后缀域名（如 `.eu.org` 等），按记录类型更新与创建解析。
- **Hosts 安全同步**：采用覆写方式同步 `/etc/hosts`，避免 Docker 挂载文件执行 `rm` 触发 `Resource busy`。
- **纯粹后端环境**：已彻底移除 OpenWrt 科学上网插件暂停/重启逻辑；内置 Web 服务保活循环与 `dcron` 实时重载（保存配置自动更新系统 `crontab`）。

### 4. 多渠道消息推送 & 日志优化
- 支持 **Telegram**（支持自定义 `Proxy_TG` 反代）、**PushPlus**、**Server 酱**、**PushDeer**、**企业微信**（支持 `Proxy_WX` 反代）、**Synology Chat**。
- 使用 `jq` 与 `--data-urlencode` 安全构造请求载荷，修复特殊字符、换行导致推送失败以及重复打印 DNS 更新日志、进度条刷屏/丢失结尾进度的问题。

---

## 🐳 快速部署

> [!TIP]
> 持久化数据统一映射在宿主机 **`/opt/cloudfastddns`** 目录，Web 管理端口为 **`9909`**。

### 方式一：使用 Docker Hub 预构建镜像（推荐）

镜像支持 `linux/amd64` 与 `linux/arm64`：

```bash
docker run -d \
  --name cloudfastddns \
  --restart unless-stopped \
  -p 9909:9909 \
  -v /opt/cloudfastddns:/opt/cloudfastddns \
  -e TZ=Asia/Shanghai \
  -e PORT=9909 \
  -e DATA_DIR=/opt/cloudfastddns \
  xbajiu/cfstddns:latest
```

### 方式二：使用 Docker Compose 从源码构建部署

```bash
git clone https://github.com/xbajiu/CloudFastDDNS.git
cd CloudFastDDNS
docker compose up -d --build
```

部署完成后，浏览器打开：

```text
http://<你的服务器IP>:9909
```

在 Web 控制台中填写域名与 DNS 凭证，点击 **「保存配置」** 或 **「开始运行」** 即可。

---

## 📁 目录与持久化文件说明

| 宿主机路径 | 说明 |
| :--- | :--- |
| `/opt/cloudfastddns/config.conf` | 主配置文件（Web 修改与手动修改实时互通） |
| `/opt/cloudfastddns/run.log` | Web 与容器统一运行日志 |
| `/opt/cloudfastddns/.ran_before` | 首次初始化完成标记 |
| `/opt/cloudfastddns/cf_ddns/cfst` | 持久化保存的 `CloudflareSpeedTest` 可执行程序 |
| `/opt/cloudfastddns/cf_ddns/result.csv` | 最新一次测速完整结果（供 Web 表格与 DDNS 脚本读取） |
| `/opt/cloudfastddns/cf_ddns/ip.txt` / `ipv6.txt` | Cloudflare IPv4 / IPv6 优选 IP 段文件（支持自定义编辑） |

---

## ⚙️ 环境变量

| 变量名 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `TZ` | `Asia/Shanghai` | 容器时区（影响定时任务与日志时间） |
| `PORT` | `9909` | Web 控制台监听端口 |
| `DATA_DIR` | `/opt/cloudfastddns` | 配置、日志、脚本及 `cfst` 持久化目录 |

---

## ❓ 常见问题

1. **为什么下载测速进度没到 `100%`（例如停在 `1 / 5 (20%)`）就显示“测速完毕”？**
   - 当配置了下载速度下限 `CFST_SL`（默认 `5` MB/s）时，`cfst` 会测完本轮所有候选 IP，但只有达到或超过 `CFST_SL` 的 IP 才会计入分子（如 `1 / 5`）。未到 `100%` 说明本轮全部候选 IP 中仅找到对应数量达标的高速 IP，测速本身已正常完成。如需放宽数量可适当调低 `CFST_SL` 或放宽延迟上限 `CFST_TL`。
2. **Cloudflare 校验提示认证失败？**
   - 本项目遵循 `main` 分支认证方式，请填写 Cloudflare 账号邮箱（`x_email`）和 **Global API Key**（`api_key`），**不要**填写区域 API Token；空间 `Zone ID` 会根据 `hostname` 自动获取。
3. **首次启动拉取 `cfst` 较慢或失败怎么办？**
   - 可在 Web 控制台「基础与工作模式」修改 `PROXY`（如 `https://gh-proxy.com/`、`https://ghfast.top/` 或留空直连 GitHub），保存后重新启动容器或手动触发一次运行即可。

---

## 🙏 致谢

- 感谢 [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) 提供的强力测速核心 `cfst`
- 感谢原作者 [lee1080/CloudflareSpeedTestDDNS](https://github.com/lee1080/CloudflareSpeedTestDDNS) 的开源贡献

---

## 💖 打赏支持

如果本项目对你有帮助，欢迎请作者喝杯咖啡 😄

<img src="https://raw.githubusercontent.com/xbajiu/CloudFastDDNS/main/images/img.jpeg" alt="打赏二维码" width="280" />
