#!/bin/bash
#		版本：20231004 (基于 lee1080/CloudflareSpeedTestDDNS main 分支)
#         用于cfst调用，更新hosts和更新dnspod DNS。

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

declare -a DNSPOD_DOMAINS=()

if [ "$IP_TO_DNSPOD" = "1" ]; then
  response=$(curl -sSf -X POST "https://dnsapi.cn/Domain.List" \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "login_token=${dnspod_token}&format=json&offset=0&length=100")

  status_code=$(echo "${response}" | jq -r '.status.code // empty' 2>/dev/null)
  if [ "${status_code}" = "1" ]; then
    echo "dnspod Token有效"
    while IFS= read -r dname; do
      [ -n "$dname" ] && DNSPOD_DOMAINS+=("$dname")
    done <<< "$(echo "${response}" | jq -r '.domains[]?.name // empty' 2>/dev/null)"
  else
    err_msg=$(echo "${response}" | jq -r '.status.message // "请检查配置填写是否正确"' 2>/dev/null)
    log_inform "dnspod Token无效: ${err_msg}"
    source "$cf_push"
    exit 1
  fi
else
  echo "未配置dnspod Token"
fi

# LINEChoice
case "${LINE:-0}" in
  1) LINE="电信" ;;
  2) LINE="联通" ;;
  3) LINE="移动" ;;
  4) LINE="铁通" ;;
  5) LINE="广电" ;;
  6) LINE="教育网" ;;
  7) LINE="境内" ;;
  8) LINE="境外" ;;
  *) LINE="默认" ;;
esac

# 初始化并校验 CFST 参数
init_cfst_defaults "$num"

# 执行 cfst 测速
run_cfst_speedtest || {
  log_inform "[错误] 测速执行失败，已保留旧 DNS 解析记录！"
  source "$cf_push"
  exit 1
}

if [ ! -f "$CSV_FILE" ]; then
  log_inform "[警告] 未获取到有效测速 IP（结果文件为空；当前下载速度下限 CFST_SL=${CFST_SL} MB/s），保留旧 DNS 解析记录！"
  return 0 2>/dev/null || exit 0
fi

total_rows=$(awk 'END {print NR-1}' "$CSV_FILE")
if [ "${total_rows:-0}" -le 0 ]; then
  log_inform "[警告] 未获取到有效测速 IP（测速结果为空；当前下载速度下限 CFST_SL=${CFST_SL} MB/s），保留旧 DNS 解析记录！"
  return 0 2>/dev/null || exit 0
fi

DNSPOD_DOMAIN=""
DNSPOD_SUBDOMAIN=""

dnspod_split_domain() {
  local fullname="$1"
  local candidate=""
  DNSPOD_DOMAIN=""
  DNSPOD_SUBDOMAIN=""

  # 1. 优先从已获取的 DNSPod 域名列表中匹配最长后缀（兼容 .eu.org / .com.cn / 根域名 / 多级子域名）
  local best_match=""
  local d
  for d in "${DNSPOD_DOMAINS[@]}"; do
    if [ "$fullname" = "$d" ] || [[ "$fullname" == *".${d}" ]]; then
      if [ "${#d}" -gt "${#best_match}" ]; then
        best_match="$d"
      fi
    fi
  done

  if [ -n "$best_match" ]; then
    DNSPOD_DOMAIN="$best_match"
    if [ "$fullname" = "$best_match" ]; then
      DNSPOD_SUBDOMAIN="@"
    else
      DNSPOD_SUBDOMAIN="${fullname%.$best_match}"
    fi
    return 0
  fi

  # 2. 若账号下域名超过 100 个，逐级向上调用 Domain.Info 精确匹配主域名
  candidate="$fullname"
  while [ -n "$candidate" ] && [[ "$candidate" == *.* ]]; do
    local info_res info_code
    info_res=$(curl -sm10 -X POST "https://dnsapi.cn/Domain.Info" \
      --data-urlencode "login_token=$dnspod_token" \
      --data-urlencode "format=json" \
      --data-urlencode "domain=$candidate")
    info_code=$(echo "$info_res" | jq -r '.status.code // empty' 2>/dev/null)
    if [ "$info_code" = "1" ]; then
      DNSPOD_DOMAIN="$candidate"
      if [ "$fullname" = "$candidate" ]; then
        DNSPOD_SUBDOMAIN="@"
      else
        DNSPOD_SUBDOMAIN="${fullname%.$candidate}"
      fi
      return 0
    fi
    candidate=$(echo "$candidate" | cut -d '.' -f 2-)
  done

  return 1
}

# 开始循环每个域名
echo "正在更新域名解析，请稍等..."
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

  if [[ "$ipSpeed" == "0.00" || -z "$ipSpeed" || -z "$ipAddr" ]]; then
    log_inform "第$((x + 1))个---[${CDNhostname}] 无可用优选 IP（测速为0或可用 IP 不足，当前 CFST_SL=${CFST_SL} MB/s），跳过更新，保留旧解析！"
  else
    if [ "$IP_TO_HOSTS" = 1 ]; then
      echo "$ipAddr $CDNhostname" >> "${CF_DDNS_DIR}/hosts_new"
    fi

    if [ "$IP_TO_DNSPOD" = 1 ]; then
      if ! dnspod_split_domain "$CDNhostname"; then
        log_inform "[错误] 域名 [${CDNhostname}] 未在当前 DNSPod 账号下找到对应的主域名，跳过！"
      else
        domain="$DNSPOD_DOMAIN"
        sub_domain="$DNSPOD_SUBDOMAIN"

        recordType="A"
        [[ "$ipAddr" =~ ":" ]] && recordType="AAAA"

        response=$(curl -sm10 -X POST "https://dnsapi.cn/Record.List" \
          --data-urlencode "login_token=$dnspod_token" \
          --data-urlencode "format=json" \
          --data-urlencode "domain=$domain" \
          --data-urlencode "sub_domain=$sub_domain" \
          --data-urlencode "record_type=$recordType" \
          --data-urlencode "record_line=$LINE")
        status=$(echo "$response" | jq -r '.status.code // empty' 2>/dev/null)

        if [ "$status" = "1" ]; then
          record_id=$(echo "$response" | jq -r '.records[0].id // empty' 2>/dev/null)
          update_response=$(curl -sm10 -X POST "https://dnsapi.cn/Record.Modify" \
            --data-urlencode "login_token=$dnspod_token" \
            --data-urlencode "format=json" \
            --data-urlencode "domain=$domain" \
            --data-urlencode "record_id=$record_id" \
            --data-urlencode "sub_domain=$sub_domain" \
            --data-urlencode "record_line=$LINE" \
            --data-urlencode "record_type=$recordType" \
            --data-urlencode "value=$ipAddr")
          update_status=$(echo "$update_response" | jq -r '.status.code // empty' 2>/dev/null)
          if [ "$update_status" = "1" ]; then
            log_inform "  + [成功] ${CDNhostname} (${recordType}) -> ${ipAddr}"
          else
            err_msg=$(echo "$update_response" | jq -r '.status.message // "未知错误"' 2>/dev/null)
            log_inform "  x [失败] ${CDNhostname} 更新失败: ${err_msg}"
          fi
        elif [ "$status" = "10" ]; then
          create_response=$(curl -sm10 -X POST "https://dnsapi.cn/Record.Create" \
            --data-urlencode "login_token=$dnspod_token" \
            --data-urlencode "format=json" \
            --data-urlencode "domain=$domain" \
            --data-urlencode "sub_domain=$sub_domain" \
            --data-urlencode "record_line=$LINE" \
            --data-urlencode "record_type=$recordType" \
            --data-urlencode "value=$ipAddr")
          create_status=$(echo "$create_response" | jq -r '.status.code // empty' 2>/dev/null)
          if [ "$create_status" = "1" ]; then
            log_inform "  + [成功] ${CDNhostname} (${recordType}) 成功创建并更新 -> ${ipAddr}"
          else
            err_msg=$(echo "$create_response" | jq -r '.status.message // "未知错误"' 2>/dev/null)
            log_inform "  x [失败] ${CDNhostname} 创建失败: ${err_msg}"
          fi
        else
          err_msg=$(echo "$response" | jq -r '.status.message // "查询记录失败"' 2>/dev/null)
          log_inform "  x [失败] ${CDNhostname} 查询解析记录失败: ${err_msg}"
        fi
      fi
    fi
  fi
  x=$((x + 1))
  sleep 2
done

update_etc_hosts
