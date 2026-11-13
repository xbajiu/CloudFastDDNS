#!/bin/bash
# ==============================================================================
# CloudFastDDNS Docker 容器入口与后台保活脚本 (entrypoint.sh)
# - 映射目录: /opt/cloudfastddns/
# - 仅在刚部署时拉取环境与 cfst 软件，重启容器或点击开始运行不会再次拉取
# - 启动 crond 定时守护与 9909 Web 服务后台保活循环
# ==============================================================================

export DATA_DIR="${DATA_DIR:-/opt/cloudfastddns}"
export APP_DIR="${APP_DIR:-/app}"
export PORT="${PORT:-9909}"

mkdir -p "${DATA_DIR}/cf_ddns"

# 1. 首次挂载时初始化默认配置文件（不覆盖已有配置）
if [ ! -f "${DATA_DIR}/config.conf" ]; then
    echo "[Entrypoint] 正在生成默认配置文件: ${DATA_DIR}/config.conf"
    cp -f "${APP_DIR}/config.conf" "${DATA_DIR}/config.conf"
fi

# 2. 同步最新执行脚本到 /opt/cloudfastddns
cp -f "${APP_DIR}/start.sh" "${DATA_DIR}/start.sh"
cp -f "${APP_DIR}/cf_ddns/"*.sh "${DATA_DIR}/cf_ddns/"
chmod +x "${DATA_DIR}/start.sh" "${DATA_DIR}/cf_ddns/"*.sh

# 同步默认 IP 库（仅当目标不存在时）
[ ! -f "${DATA_DIR}/cf_ddns/ip.txt" ] && [ -f "${APP_DIR}/cf_ddns/ip.txt" ] && cp -f "${APP_DIR}/cf_ddns/ip.txt" "${DATA_DIR}/cf_ddns/ip.txt"
[ ! -f "${DATA_DIR}/cf_ddns/ipv6.txt" ] && [ -f "${APP_DIR}/cf_ddns/ipv6.txt" ] && cp -f "${APP_DIR}/cf_ddns/ipv6.txt" "${DATA_DIR}/cf_ddns/ipv6.txt"

# 3. 仅在刚部署（无 .ran_before 标记或无 cfst 二进制）时拉取一次环境与 cfst 软件
if [ ! -f "${DATA_DIR}/.ran_before" ] || [ ! -f "${DATA_DIR}/cf_ddns/cfst" ]; then
    echo "[Entrypoint] 检测到首次部署，开始初始化环境并拉取 cfst 核心程序..."
    sed -i 's/\r$//' "${DATA_DIR}/config.conf" 2>/dev/null || true
    set -a
    source "${DATA_DIR}/config.conf" 2>/dev/null || true
    set +a
    bash "${DATA_DIR}/cf_ddns/cf_check.sh" --init-only 2>&1 | tee -a "${DATA_DIR}/run.log"
else
    chmod +x "${DATA_DIR}/cf_ddns/cfst" 2>/dev/null || true
    echo "[Entrypoint] 已存在初始化标记 (${DATA_DIR}/.ran_before) 及 cfst 程序，跳过拉取。"
fi

# 4. 启动 crond 定时任务服务
if command -v crond &> /dev/null; then
    crond
    echo "[Entrypoint] crond 定时任务守护进程已启动"
fi

# 5. Web 服务与后台保活循环 (端口: 9909)
echo "[Entrypoint] 启动 CloudFastDDNS Web 控制台 (端口: ${PORT}) 并开启后台保活..."
while true; do
    python3 "${APP_DIR}/web/server.py"
    EXIT_CODE=$?
    echo "[KeepAlive] Web 服务退出 (代码: ${EXIT_CODE})，3 秒后自动重启保活..."
    sleep 3
done
