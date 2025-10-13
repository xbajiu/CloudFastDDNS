#!/bin/bash

# 创建log目录
[ ! -d "./log" ] && mkdir -p ./log
LOG_FILE="./log/run.log"
exec > >(tee "$LOG_FILE") 2>&1

# 初始化配置
if [ ! -e ".ran_before" ]; then
  # 创建cfst目录
  [ ! -d "./cfst" ] && mkdir -p ./cfst
  # 如果 config 目录不存在则创建
  [ ! -d "./config" ] && mkdir -p ./config
  if [ ! -f "./config/config.conf" ]; then
      cp ./cf_ddns/config.conf.bak ./config/config.conf
  fi
fi


# 加载配置和检查脚本
source ./config/config.conf
source ./cf_ddns/cf_check.sh
source ./cf_ddns/crontab.sh

# 根据 DNS_PROVIDER 选择 DDNS 脚本
case $DNS_PROVIDER in
    1)
        source ./cf_ddns/cf_ddns_cloudflare.sh
        ;;
    2)
        source ./cf_ddns/cf_ddns_dnspod.sh
        ;;
    *)
        echo "未选择任何DNS服务商"
        ;;
esac

# 推送脚本
source ./cf_ddns/cf_push.sh

#tail -f /dev/null
