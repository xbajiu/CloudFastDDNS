# 🌐 CloudFastDDNS

> 🚀 自动测速优选最快 IP 并更新 DDNS（Cloudflare / DNSPod）

⚡ 支持 IPv4 / IPv6  
🛠 Linux / OpenWRT / Armbian  
🐳 Docker 版本请切换到 **docker 分支**  
🔔 多渠道通知：Telegram / PushPlus / Server 酱 / 企业微信  
🗂 自动化管理：日志记录 / 配置初始化 / 定时任务  


---

## 🛠 使用教程

### 1️⃣ 下载脚本
支持的 Linux 设备上下载本项目

### 2️⃣ 编辑配置
修改 `config/config.conf`，填写 域名 Key Zone ID Token

### 3️⃣ 运行脚本
```bash
bash start.sh
```

> 程序将自动测速并更新 DDNS。

---

## 🐳 Docker 部署 (docker 分支)

拉取镜像并运行：

```bash
docker run -d \
  -v /opt/cloudfastddns/config:/app/config \
  --name cloudfastddns \
  xbajiu/cloudfastddns:latest
```

📁 `/opt/cloudfastddns/config` 为宿主机配置目录，容器启动后自动测速与 DDNS 更新。  
可通过宿主机 crontab / supervisord 设置定时任务或循环执行。


---

## 🙏 致谢
- 感谢 [XIU2](https://github.com/XIU2) 提供的 CloudflareSpeedTest 工具  
- 感谢原作者 **lee1080** 的开源贡献  
- 感谢各类节点参考项目和社区支持  

---

## 💖 打赏支持
如果本项目对你有帮助，欢迎打赏支持 😄  

<img src="images/img.jpeg" alt="打赏二维码" width="300" />


