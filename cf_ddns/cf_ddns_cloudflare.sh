#!/bin/bash
#		版本：20231004 (基于 lee1080/CloudflareSpeedTestDDNS main 分支)
#         用于cfst调用，更新hosts和更新cloudflare DNS（一个域名单IP模式）。

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

# 验证 cf 账号信息是否正确
if [ "$IP_TO_CF" = "1" ]; then
  cf_verify_account "${hostname[0]}" || {
    source "$cf_push"
    exit 1
  }
else
  echo "未配置 Cloudflare 账号"
fi

# 初始化并校验 CFST 参数（单IP模式至少测出与域名数量相当的 IP）
init_cfst_defaults "$num"

# 执行 cfst 测速
run_cfst_speedtest || {
  log_inform "[错误] 测速执行失败，已保留旧 DNS 解析记录！"
  source "$cf_push"
  exit 1
}

if [ ! -f "$CSV_FILE" ]; then
  log_inform "[警告] 未获取到有效测速 IP（结果文件为空；当前下载速度下限 CFST_SL=${CFST_SL} MB/s，可适当调低 CFST_SL 或检查 CFST_URL），保留旧 DNS 解析记录！"
  return 0 2>/dev/null || exit 0
fi

total_rows=$(awk 'END {print NR-1}' "$CSV_FILE")
if [ "${total_rows:-0}" -le 0 ]; then
  log_inform "[警告] 未获取到有效测速 IP（测速结果为空；当前下载速度下限 CFST_SL=${CFST_SL} MB/s），保留旧 DNS 解析记录！"
  return 0 2>/dev/null || exit 0
fi

# 开始循环每个域名更新解析
echo "正在更新域名解析，请稍等 (模式: 一个域名单IP)..."
rm -f "${CF_DDNS_DIR}/hosts_new"

x=0
while [[ ${x} -lt $num ]]; do
  CDNhostname=${hostname[$x]}
  if [ "$((x + 1))" -le "$total_rows" ]; then
    ipAddr=$(sed -n "$((x + 2)),1p" "$CSV_FILE" | awk -F, '{print $1}' | tr -d '\r')
    ipSpeed=$(sed -n "$((x + 2)),1p" "$CSV_FILE" | awk -F, '{print $6}' | tr -d '\r')
  else
    ipAddr=""
    ipSpeed=""
  fi

  # 没有可用的测速 IP 则不删除旧记录，跳过更新！
  if [[ "$ipSpeed" == "0.00" || -z "$ipSpeed" || -z "$ipAddr" ]]; then
    log_inform "第$((x + 1))个---域名 [${CDNhostname}] 无可用优选 IP（测速为0或可用 IP 不足，当前 CFST_SL=${CFST_SL} MB/s），跳过更新，保留旧解析记录！"
  else
    if [ "$IP_TO_HOSTS" = 1 ]; then
      echo "$ipAddr $CDNhostname" >> "${CF_DDNS_DIR}/hosts_new"
    fi

    if [ "$IP_TO_CF" = 1 ]; then
      cf_resolve_zone_id "$CDNhostname"
      dz_id="$CF_ZONE_ID"
      if [[ -z "$dz_id" || "$dz_id" == "null" ]]; then
        log_inform "[错误] 域名 [${CDNhostname}] 获取空间 Zone ID 失败${CF_LAST_API_ERR:+ (${CF_LAST_API_ERR})}，跳过！"
      else
        url="https://api.cloudflare.com/client/v4/zones/$dz_id/dns_records"
        cf_delete_old_records "$url" "$CDNhostname"

        # 写入新的优选 IP
        recordType="A"
        [[ "$ipAddr" =~ ":" ]] && recordType="AAAA"
        data="{\"type\":\"$recordType\",\"name\":\"$CDNhostname\",\"content\":\"$ipAddr\",\"ttl\":60,\"proxied\":false}"
        res=$(curl -sm10 -X POST "$url" \
          -H "X-Auth-Email:$x_email" \
          -H "X-Auth-Key:$api_key" \
          -H "Content-Type:application/json" \
          -d "$data")

        if [[ $(echo "$res" | jq -r '.success // false' 2>/dev/null) == "true" ]]; then
          log_inform "  + [成功] ${CDNhostname} (${recordType}) -> ${ipAddr}"
        else
          err_msg=$(echo "$res" | jq -r '.errors[0].message // "未知错误"' 2>/dev/null)
          log_inform "  x [失败] ${CDNhostname} 更新失败: ${err_msg}"
        fi
      fi
    fi
  fi
  x=$((x + 1))
  sleep 1
done

update_etc_hosts
