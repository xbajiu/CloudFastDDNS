#!/bin/bash
# ==============================================================================
# CloudFastDDNS 主执行脚本 (基于 lee1080/CloudflareSpeedTestDDNS main 分支 start.sh)
# ==============================================================================

export DATA_DIR="${DATA_DIR:-/opt/cloudfastddns}"
export CF_DDNS_DIR="${DATA_DIR}/cf_ddns"

config_file="${DATA_DIR}/config.conf"
if [ ! -f "$config_file" ] && [ -f "./config.conf" ]; then
    config_file="./config.conf"
fi

while [[ $# -gt 0 ]]; do
    if [ "$1" == "--cfg" ]; then
        shift
        if [ -z "${1:-}" ]; then
            echo "[错误] --cfg 参数缺少配置文件路径"
            exit 1
        fi
        config_file="$1"
        break
    fi
    shift
done

if [ ! -f "$config_file" ]; then
    echo "[错误] 未找到配置文件: $config_file"
    exit 1
fi

if grep -q $'\r' "$config_file" 2>/dev/null; then
    sed -i 's/\r$//' "$config_file" 2>/dev/null || true
fi

source "$config_file"

# remove the result.csv if exists
rm -f "${CF_DDNS_DIR}/result.csv" "${DATA_DIR}/result.csv"

source "${CF_DDNS_DIR}/cf_check.sh"

case $DNS_PROVIDER in
    1)
        if [ "$MULTI_IP" = "true" ]; then
            echo "DNS服务商: Cloudflare (工作模式: 一个域名多个IP，每域名 ${MULTI_IP_NUM:-3} 个IP)"
            source "${CF_DDNS_DIR}/cf_ddns_cloudflare_multiple.sh"
        else
            echo "DNS服务商: Cloudflare (工作模式: 一个域名单IP)"
            source "${CF_DDNS_DIR}/cf_ddns_cloudflare.sh"
        fi
        ;;
    2)
        source "${CF_DDNS_DIR}/cf_ddns_dnspod.sh"
        ;;
    *)
        echo "未选择任何DNS服务商"
        ;;
esac

# informlog中不能带空格，否则不能被识别
source "${CF_DDNS_DIR}/cf_push.sh"

exit 0
