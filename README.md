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
