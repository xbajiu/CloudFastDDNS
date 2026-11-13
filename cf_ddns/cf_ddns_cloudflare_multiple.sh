#!/bin/bash
#		版本：20231004 (基于 lee1080/CloudflareSpeedTestDDNS main 分支)
#         用于cfst调用，更新hosts和更新cloudflare DNS（一个域名解析多个IP）。

DATA_DIR="${DATA_DIR:-/opt/cloudfastddns}"
CF_DDNS_DIR="${DATA_DIR}/cf_ddns"
CloudflareST="${CF_DDNS_DIR}/cfst"
informlog="${CF_DDNS_DIR}/informlog"
cf_push="${CF_DDNS_DIR}/cf_push.sh"
CSV_FILE="${CF_DDNS_DIR}/result.csv"

# shellcheck disable=SC1091
source "${CF_DDNS_DIR}/cf_common.sh"

init_informlog
num=${#hostname[*]}

if [ "$num" -eq 0 ]; then
  log_inform "[错误] 未配置任何需要 DDNS 的域名 (hostname 为空)，请先在配置中添加域名！"
  source "$cf_push"
  exit 1
fi

# 验证 Cloudflare 账号信息
if [ "$IP_TO_CF" = "1" ]; then
  cf_verify_account "${hostname[0]}" || {
    source "$cf_push"
    exit 1
  }
else
  echo "未配置 Cloudflare 账号"
fi

# 一个域名多IP：每个域名解析的IP数量 (默认3)
if [[ ! "${MULTI_IP_NUM:-}" =~ ^[0-9]+$ ]] || [ "${MULTI_IP_NUM:-0}" -lt 1 ]; then
  MULTI_IP_NUM=3
fi

# 初始化并校验 CFST 参数（若 CFST_DN 小于需要解析的 IP 数，自动提高）
init_cfst_defaults "$MULTI_IP_NUM"

# 执行 cfst 测速
run_cfst_speedtest || {
  log_inform "[错误] 测速执行失败，已保留旧 DNS 解析记录！"
  source "$cf_push"
  exit 1
}

# 1. 首先解析测速结果，提取速度大于0的有效优选IP
declare -a ips
if [[ -f "$CSV_FILE" ]]; then
  total=$(awk -F, 'END {print NR-1}' "$CSV_FILE")
  x=0
  while [[ ${x} -lt ${total} ]] && [[ ${#ips[@]} -lt ${MULTI_IP_NUM} ]]; do
    ipAddr=$(sed -n "$((x + 2)),1p" "$CSV_FILE" | awk -F, '{print $1}' | tr -d '\r')
    ipSpeed=$(sed -n "$((x + 2)),1p" "$CSV_FILE" | awk -F, '{print $6}' | tr -d '\r')
    if [[ "$ipSpeed" == "0.00" || -z "$ipSpeed" ]]; then
      echo "第$((x + 1))个---${ipAddr} 测速为0或不可用，跳过！"
    elif [[ -n "$ipAddr" ]]; then
      ips+=("$ipAddr")
    fi
    x=$((x + 1))
  done
fi

# 2. 检查是否有可用测速结果：没有可用的就绝对不删除旧的DNS解析记录！
if [[ ${#ips[@]} -eq 0 ]]; then
  log_inform "[警告] 未获取到有效可用测速 IP（测速为0或结果为空；当前下载速度下限 CFST_SL=${CFST_SL} MB/s），保留旧 DNS 解析记录，不执行删除与更新！"
  return 0 2>/dev/null || exit 0
fi

echo "成功获取到 ${#ips[@]} 个可用优选 IP: ${ips[*]}"
if [[ ${#ips[@]} -lt ${MULTI_IP_NUM} ]]; then
  echo "[提示] 期望每域名解析 ${MULTI_IP_NUM} 个 IP，本次共有 ${#ips[@]} 个 IP 满足测速条件（受 CFST_SL=${CFST_SL} MB/s、CFST_TL=${CFST_TL} ms 等过滤参数限制；如需更多可用 IP，可适当调低 CFST_SL 或检查 CFST_URL）。"
fi

# 3. 为单个域名删除所有旧的 A/AAAA 记录，并添加多条新优选 IP 解析记录
updateDNSRecords() {
  local fullname="$1"
  cf_resolve_zone_id "$fullname"
  local dz_id="$CF_ZONE_ID"
  if [[ -z "$dz_id" || "$dz_id" == "null" ]]; then
    log_inform "[错误] 域名 [${fullname}] 获取空间 Zone ID 失败${CF_LAST_API_ERR:+ (${CF_LAST_API_ERR})}，请检查该域名是否托管在当前 Cloudflare 账号！"
    return 1
  fi

  local url="https://api.cloudflare.com/client/v4/zones/$dz_id/dns_records"
  cf_delete_old_records "$url" "$fullname"

  # 依次写入新的优选 IP
  local added_count=0
  for ip in "${ips[@]}"; do
    local record_type="A"
    [[ "$ip" =~ ":" ]] && record_type="AAAA"
    local data="{\"type\":\"$record_type\",\"name\":\"$fullname\",\"content\":\"$ip\",\"ttl\":60,\"proxied\":false}"
    local add_res
    add_res=$(curl -sm10 -X POST "$url" \
      -H "X-Auth-Email: $x_email" \
      -H "X-Auth-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$data")
    if [[ $(echo "$add_res" | jq -r '.success // false' 2>/dev/null) == "true" ]]; then
      log_inform "  + [成功] ${fullname} (${record_type}) -> ${ip}"
      added_count=$((added_count + 1))
    else
      local err_msg
      err_msg=$(echo "$add_res" | jq -r '.errors[0].message // "未知错误"' 2>/dev/null)
      log_inform "  x [失败] ${fullname} (${record_type}) -> ${ip}: ${err_msg}"
    fi
    sleep 1
  done
  log_inform "域名 [${fullname}] 优选 IP 解析更新完毕，共添加 ${added_count} 条记录。"
}

echo "正在更新域名解析，请稍等 (模式: 一个域名多IP，每域名 ${#ips[@]} 个IP)..."
rm -f "${CF_DDNS_DIR}/hosts_new"

for CDNhostname in "${hostname[@]}"; do
  if [ "$IP_TO_HOSTS" = 1 ]; then
    echo "${ips[0]} $CDNhostname" >> "${CF_DDNS_DIR}/hosts_new"
  fi
  if [ "$IP_TO_CF" = 1 ]; then
    updateDNSRecords "$CDNhostname"
  fi
done

update_etc_hosts
