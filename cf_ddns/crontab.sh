#!/bin/bash

# 获取脚本所在目录
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# 定时任务命令
CRON_CMD="$TIMING cd \"$SCRIPT_DIR\" && bash start.sh"

# 临时文件
TMP_CRON=$(mktemp)

# 获取已有任务，删除旧的 start.sh 任务
crontab -l 2>/dev/null | grep -v "cd \"$SCRIPT_DIR\" && bash start.sh" > "$TMP_CRON"

# 添加新任务
echo "$CRON_CMD" >> "$TMP_CRON"

# 安装新的 crontab
crontab "$TMP_CRON"

# 删除临时文件
rm "$TMP_CRON"

# 启动 cron 服务
if command -v crond >/dev/null 2>&1; then
    # Alpine / BusyBox
    crond -f -L /dev/stdout &
elif command -v cron >/dev/null 2>&1; then
    # Debian / Ubuntu
    service cron start
fi
