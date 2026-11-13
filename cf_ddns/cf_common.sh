#!/bin/bash
# ==============================================================================
# CloudFastDDNS 公共函数库 (cf_common.sh)
# 供 cf_check.sh / cf_ddns_cloudflare*.sh / cf_ddns_dnspod.sh 复用
# ==============================================================================

strip_crlf_file() {
  local target="$1"
  if [ -f "$target" ] && grep -q $'\r' "$target" 2>/dev/null; then
    sed -i 's/\r$//' "$target" 2>/dev/null || true
  fi
}

source_clean_config() {
  local cfg="$1"
  strip_crlf_file "$cfg"
  # shellcheck disable=SC1090
  source "$cfg"
}

init_informlog() {
  mkdir -p "$(dirname "$informlog")"
  : > "$informlog"
}

log_inform() {
  local msg="$1"
  printf '%s\n' "$msg"
  printf '%s\n' "$msg" >> "$informlog"
}

_is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

_is_ufloat() {
  [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

init_cfst_defaults() {
  local min_dn="${1:-1}"
  _is_uint "$min_dn" || min_dn=1
  [ "$min_dn" -lt 1 ] && min_dn=1

  case "${IP_PR_IP:-0}" in
    0|1|2) ;;
    *) IP_PR_IP=0 ;;
  esac

  if ! _is_uint "${CFST_TP:-}" || [ "$CFST_TP" -lt 1 ] || [ "$CFST_TP" -gt 65535 ]; then
    CFST_TP=443
  fi
  if ! _is_uint "${CFST_DT:-}" || [ "$CFST_DT" -lt 1 ]; then
    CFST_DT=10
  fi
  if ! _is_uint "${CFST_N:-}" || [ "$CFST_N" -lt 1 ]; then
    CFST_N=200
  fi
  if ! _is_uint "${CFST_T:-}" || [ "$CFST_T" -lt 1 ]; then
    CFST_T=4
  fi
  if ! _is_uint "${CFST_DN:-}" || [ "$CFST_DN" -lt 1 ]; then
    CFST_DN=10
  fi
  if ! _is_uint "${CFST_TL:-}" || [ "$CFST_TL" -lt 1 ]; then
    CFST_TL=300
  fi
  if ! _is_uint "${CFST_TLL:-}"; then
    CFST_TLL=0
  fi
  if ! _is_ufloat "${CFST_TLR:-}"; then
    CFST_TLR="0.2"
  fi
  if ! _is_ufloat "${CFST_SL:-}"; then
    CFST_SL="5"
  fi

  if [ "$CFST_DN" -lt "$min_dn" ]; then
    CFST_DN="$min_dn"
  fi
  CFST_P="$CFST_DN"
}

_download_pr_ip_list() {
  local key="$1"
  local url="$2"
  local label="$3"
  local ts_file="${CF_DDNS_DIR}/.pr_ip_timestamp"
  local pr_file="${CF_DDNS_DIR}/pr_ip.txt"
  local tmp_file="${CF_DDNS_DIR}/pr_ip.txt.tmp"
  local now_ts exp_ts

  now_ts=$(date +%s)
  exp_ts=$(jq -r ".${key} // 0" "$ts_file" 2>/dev/null || echo 0)
  _is_uint "$exp_ts" || exp_ts=0

  if [ ! -s "$pr_file" ] || [ "$exp_ts" -le "$now_ts" ]; then
    rm -f "$tmp_file"
    if curl -sSfL --connect-timeout 15 --max-time 60 -o "$tmp_file" "$url" && [ -s "$tmp_file" ]; then
      mv -f "$tmp_file" "$pr_file"
      printf '{"%s":"%s"}\n' "$key" "$((now_ts + 86400))" > "$ts_file"
      echo "已更新${label}的反向代理列表"
    else
      rm -f "$tmp_file"
      if [ -s "$pr_file" ]; then
        echo "[警告] 更新${label}反向代理列表失败，继续使用本地缓存: $pr_file"
      else
        echo "[错误] 下载${label}反向代理列表失败且无可用缓存，请检查网络！"
        return 1
      fi
    fi
  fi
  return 0
}

run_cfst_speedtest() {
  local ip_file=""

  if [ "${IP_PR_IP:-0}" != "0" ]; then
    echo "当前工作模式为反代 IP (线路 ${IP_PR_IP})"
    if [ "$IP_PR_IP" = "1" ]; then
      _download_pr_ip_list "pr1_expires" "https://cf.vbar.fun/pr_ip.txt" "线路1" || return 1
    else
      _download_pr_ip_list "pr2_expires" "https://cf.vbar.fun/zip_baipiao_eu_org/pr_ip.txt" "线路2" || return 1
    fi
    ip_file="${CF_DDNS_DIR}/pr_ip.txt"
  elif [ "${IP_ADDR:-ipv4}" = "ipv6" ]; then
    ip_file="${CF_DDNS_DIR}/ipv6.txt"
    if [ ! -f "$ip_file" ]; then
      echo "当前工作模式为ipv6，但该目录下没有【ipv6.txt】，请配置【ipv6.txt】。下载地址：https://github.com/XIU2/CloudflareSpeedTest/releases"
      return 2
    fi
    echo "当前工作模式为ipv6"
  else
    ip_file="${CF_DDNS_DIR}/ip.txt"
    if [ ! -f "$ip_file" ]; then
      echo "当前工作模式为ipv4，但该目录下没有【ip.txt】，请配置【ip.txt】。"
      return 2
    fi
    echo "当前工作模式为ipv4"
  fi

  if [ ! -f "$CloudflareST" ]; then
    echo "[错误] 未找到 cfst 可执行程序: $CloudflareST"
    return 1
  fi
  chmod +x "$CloudflareST" 2>/dev/null || true

  local -a cfst_args=()
  if [[ "${CFST_URL:-}" == http* ]]; then
    cfst_args+=(-url "$CFST_URL")
  fi
  cfst_args+=(
    -t "$CFST_T"
    -n "$CFST_N"
    -dn "$CFST_DN"
    -tl "$CFST_TL"
    -dt "$CFST_DT"
    -tp "$CFST_TP"
  )
  if [ "$IP_PR_IP" = "0" ]; then
    cfst_args+=(-tll "$CFST_TLL")
  fi
  cfst_args+=(
    -sl "$CFST_SL"
    -p "$CFST_P"
    -tlr "$CFST_TLR"
  )

  local stm_lower
  stm_lower=$(printf '%s' "${CFST_STM:-}" | tr '[:upper:]' '[:lower:]')
  if [[ -n "$stm_lower" && "$stm_lower" != "false" && "$stm_lower" != "tcping" ]]; then
    cfst_args+=(-httping)
    local clean_code="${httping_code//[[:space:]]/}"
    if [[ -n "$clean_code" ]]; then
      cfst_args+=(-httping-code "$clean_code")
    fi
    local clean_colo="${cfcolo//[[:space:]]/}"
    if [[ -n "$clean_colo" ]]; then
      cfst_args+=(-cfcolo "$clean_colo")
    fi
  fi

  cfst_args+=(-f "$ip_file" -o "$CSV_FILE")

  "$CloudflareST" "${cfst_args[@]}"
  local cfst_rc=$?

  if [ -f "$CSV_FILE" ]; then
    cp -f "$CSV_FILE" "${DATA_DIR}/result.csv" 2>/dev/null || true
  fi

  if [ "$cfst_rc" -ne 0 ]; then
    echo "[错误] cfst 测速异常退出 (退出码: ${cfst_rc})"
    return "$cfst_rc"
  fi

  echo "测速完毕"
  return 0
}

update_etc_hosts() {
  if [ "$IP_TO_HOSTS" = 1 ] && [ -s "${CF_DDNS_DIR}/hosts_new" ]; then
    if [ ! -f "/etc/hosts.old_cfstddns_bak" ]; then
      cp /etc/hosts /etc/hosts.old_cfstddns_bak
    else
      # Docker 中 /etc/hosts 为挂载文件，不可 rm 删除，需覆盖写入内容
      cat /etc/hosts.old_cfstddns_bak > /etc/hosts
    fi
    cat "${CF_DDNS_DIR}/hosts_new" >> /etc/hosts
    log_inform "hosts已更新"
    rm -f "${CF_DDNS_DIR}/hosts_new"
  fi
}

CF_ZONE_ID=""
CF_LAST_API_ERR=""

cf_resolve_zone_id() {
  local target="$1"
  local zid=""
  local resp=""
  local ok=""
  CF_ZONE_ID=""
  CF_LAST_API_ERR=""

  while [ -n "$target" ] && [[ "$target" == *.* ]]; do
    resp=$(curl -sm10 -X GET "https://api.cloudflare.com/client/v4/zones?name=${target}" \
      -H "X-Auth-Email: $x_email" \
      -H "X-Auth-Key: $api_key" \
      -H "Content-Type: application/json")
    ok=$(echo "$resp" | jq -r '.success // false' 2>/dev/null)
    if [ "$ok" = "true" ]; then
      zid=$(echo "$resp" | jq -r '.result[0].id // empty' 2>/dev/null)
      if [ -n "$zid" ] && [ "$zid" != "null" ]; then
        CF_ZONE_ID="$zid"
        return 0
      fi
    else
      CF_LAST_API_ERR=$(echo "$resp" | jq -r '.errors[0].message // "Cloudflare API 请求失败"' 2>/dev/null)
      return 1
    fi
    target=$(echo "$target" | cut -d '.' -f 2-)
  done
  return 1
}

cf_verify_account() {
  local first_domain="$1"
  if [[ -z "${x_email:-}" ]]; then
    log_inform "Cloudflare 账号邮箱 (x_email) 未填写，请检查配置！"
    return 1
  fi
  cf_resolve_zone_id "$first_domain"
  if [ -z "$CF_ZONE_ID" ]; then
    if [ -n "$CF_LAST_API_ERR" ]; then
      log_inform "Cloudflare 验证失败: ${CF_LAST_API_ERR}"
    else
      log_inform "获取空间 Zone ID 失败，请检查 Cloudflare 账号邮箱、Global API Key 以及域名 [${first_domain}] 是否已托管！"
    fi
    return 1
  fi

  local res res_ok
  res=$(curl -sm10 -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}" \
    -H "X-Auth-Email: $x_email" \
    -H "X-Auth-Key: $api_key" \
    -H "Content-Type: application/json")
  res_ok=$(echo "$res" | jq -r '.success // false' 2>/dev/null)
  if [[ "$res_ok" != "true" ]]; then
    local err_msg
    err_msg=$(echo "$res" | jq -r '.errors[0].message // "账号或密钥无效"' 2>/dev/null)
    log_inform "登录错误，检查 cloudflare 账号邮箱和 Global API Key 是否正确 (${err_msg})!"
    return 1
  fi
  echo "Cloudflare 账号及域名空间验证成功"
  return 0
}

cf_delete_old_records() {
  local url="$1"
  local fullname="$2"
  local response records rec_len

  log_inform "正在获取并清理域名 [${fullname}] 的旧 DNS 解析记录..."
  response=$(curl -sm10 -X GET "${url}?name=${fullname}&per_page=100" \
    -H "X-Auth-Email: $x_email" \
    -H "X-Auth-Key: $api_key" \
    -H "Content-Type: application/json")

  if [[ $(echo "$response" | jq -r '.success // false' 2>/dev/null) != "true" ]]; then
    log_inform "  - [提示] 查询旧 DNS 记录超时或失败，直接写入新优选记录"
    return 0
  fi

  records=$(echo "$response" | jq -c '[.result[] | select(.type == "A" or .type == "AAAA")]' 2>/dev/null)
  rec_len=$(echo "$records" | jq 'length' 2>/dev/null || echo 0)
  if [[ "$rec_len" -gt 0 ]]; then
    local record record_id rec_type rec_ip del_res
    while IFS= read -r record; do
      [ -z "$record" ] && continue
      record_id=$(echo "$record" | jq -r '.id')
      rec_type=$(echo "$record" | jq -r '.type')
      rec_ip=$(echo "$record" | jq -r '.content')
      del_res=$(curl -sm10 -X DELETE "${url}/${record_id}" \
        -H "X-Auth-Email: $x_email" \
        -H "X-Auth-Key: $api_key")
      if [[ $(echo "$del_res" | jq -r '.success // false' 2>/dev/null) == "true" ]]; then
        log_inform "  - 已成功删除旧记录: ${fullname} (${rec_type}) -> ${rec_ip}"
      else
        log_inform "  - [警告] 删除旧记录失败: ${fullname} (${rec_type}) -> ${rec_ip}"
      fi
    done <<< "$(printf '%s\n' "$records" | jq -c '.[]')"
  else
    log_inform "  - 域名 [${fullname}] 当前无旧 A/AAAA 记录，直接添加新解析"
  fi
}
