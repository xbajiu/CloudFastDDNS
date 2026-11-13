#!/bin/bash
#		版本：20231004 (基于 lee1080/CloudflareSpeedTestDDNS main 分支)
#         用于CloudflareSpeedTestDDNS执行情况推送。

DATA_DIR="${DATA_DIR:-/opt/cloudfastddns}"
CF_DDNS_DIR="${DATA_DIR}/cf_ddns"
informlog="${CF_DDNS_DIR}/informlog"

if [ ! -s "$informlog" ]; then
   echo "无推送摘要内容，跳过消息推送"
   return 0 2>/dev/null || exit 0
fi

raw_msg=$(cat "$informlog")

_normalize_proxy_base() {
   local raw="${1:-}"
   raw="${raw#https://}"
   raw="${raw#http://}"
   raw="${raw%/}"
   printf '%s' "$raw"
}

# 检测是否配置TG推送
if [[ -z "${telegramBotToken:-}" ]]; then
   echo "未配置TG推送"
else
   tg_host=$(_normalize_proxy_base "${Proxy_TG:-}")
   if [[ -n "$tg_host" ]]; then
      TG_web="https://${tg_host}/bot${telegramBotToken}/sendMessage"
   else
      TG_web="https://api.telegram.org/bot${telegramBotToken}/sendMessage"
   fi
   tg_payload=$(jq -nc --arg chat_id "$telegramBotUserId" --arg text "$raw_msg" '{chat_id: $chat_id, text: $text}')
   res=$(timeout 20s curl -s -X POST "$TG_web" -H "Content-Type: application/json" -d "$tg_payload")
   rc=$?
   if [ "$rc" -eq 124 ]; then
      echo 'TG_api请求超时,请检查网络是否能够访问TG'
   else
      resSuccess=$(echo "$res" | jq -r ".ok // empty" 2>/dev/null)
      if [[ "$resSuccess" == "true" ]]; then
         echo "TG推送成功"
      else
         echo "TG推送失败，请检查TG机器人token和ID是否正确"
      fi
   fi
fi

# 检测是否配置PushPlus推送
if [[ -z "${PushPlusToken:-}" ]]; then
   echo "未配置PushPlus推送"
else
   pp_html=$(printf '%s' "$raw_msg" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' | awk '{printf "%s%s", (NR>1?"<br>":""), $0}')
   res=$(timeout 20s curl -s -X POST "http://www.pushplus.plus/send" \
      --data-urlencode "token=${PushPlusToken}" \
      --data-urlencode "title=cf优选ip推送" \
      --data-urlencode "content=${pp_html}" \
      --data-urlencode "template=html")
   rc=$?
   if [ "$rc" -eq 124 ]; then
      echo 'PushPlus请求超时，请检查网络是否正常'
   else
      resCode=$(echo "$res" | jq -r ".code // empty" 2>/dev/null)
      if [[ "$resCode" == "200" ]]; then
         echo "PushPlus推送成功"
      else
         echo "PushPlus推送失败，请检查PushPlusToken是否填写正确"
      fi
   fi
fi

# 检测是否配置Server酱推送
if [[ -z "${ServerSendKey:-}" ]]; then
   echo "未配置Server酱推送"
else
   res=$(timeout 20s curl -s -X POST "https://sctapi.ftqq.com/${ServerSendKey}.send" \
      --data-urlencode "title=cf优选ip推送" \
      --data-urlencode "desp=${raw_msg}")
   rc=$?
   if [ "$rc" -eq 124 ]; then
      echo 'Server酱请求超时,请检查网络是否可用'
   else
      resSuccess=$(echo "$res" | jq -r ".code // empty" 2>/dev/null)
      if [[ "$resSuccess" == "0" ]]; then
         echo "Server酱推送成功"
      else
         echo "Server酱推送失败，请检查Server酱SendKey是否填写正确"
      fi
   fi
fi

# 检测是否配置PushDeer推送
if [[ -z "${PushDeerPushKey:-}" ]]; then
   echo "未配置PushDeer推送"
else
   res=$(timeout 20s curl -s -X POST "https://api2.pushdeer.com/message/push" \
      --data-urlencode "pushkey=${PushDeerPushKey}" \
      --data-urlencode "text=cf优选ip推送" \
      --data-urlencode "desp=${raw_msg}" \
      --data-urlencode "type=text")
   rc=$?
   if [ "$rc" -eq 124 ]; then
      echo 'PushDeer_api请求超时,请检查网络是否正常'
   else
      resSuccess=$(echo "$res" | jq -r ".code // empty" 2>/dev/null)
      if [[ "$resSuccess" == "0" ]]; then
         echo "PushDeer推送成功"
      else
         echo "PushDeer推送失败，请检查PushDeerPushKey是否填写正确"
      fi
   fi
fi

# 检测是否配置企业微信推送
if [[ -z "${CORPID:-}" ]]; then
   echo "未配置企业微信推送"
else
   wx_host=$(_normalize_proxy_base "${Proxy_WX:-}")
   if [[ -n "$wx_host" ]]; then
      WX_tk_URL="https://${wx_host}/cgi-bin/gettoken"
      WX_Push_URL="https://${wx_host}/cgi-bin/message/send?access_token="
   else
      WX_tk_URL="https://qyapi.weixin.qq.com/cgi-bin/gettoken"
      WX_Push_URL="https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token="
   fi
   res=$(timeout 20s curl -s -G "$WX_tk_URL" --data-urlencode "corpid=$CORPID" --data-urlencode "corpsecret=$SECRET")
   rc=$?
   if [ "$rc" -eq 124 ]; then
      echo '企业微信_api请求超时,请检查网络是否正常'
   else
      resSuccess=$(echo "$res" | jq -r ".errcode // empty" 2>/dev/null)
      if [[ "$resSuccess" == "0" ]]; then
         echo "获取access_token成功"
         ACCESS_TOKEN=$(echo "$res" | jq -r ".access_token")
         WX_P_URL="${WX_Push_URL}${ACCESS_TOKEN}"
         wx_touser="${USERID:-@all}"
         wx_payload=$(jq -nc --arg touser "$wx_touser" --arg agentid "$AGENTID" --arg content "$raw_msg" \
            '{touser: $touser, msgtype: "text", agentid: $agentid, text: {content: $content}}')
         res2=$(timeout 20s curl -s -H "Content-Type: application/json;charset=utf-8" -X POST -d "$wx_payload" "$WX_P_URL")
         rc2=$?
         if [ "$rc2" -eq 124 ]; then
            echo '企业微信_api请求超时,请检查网络是否正常'
         else
            res2Success=$(echo "$res2" | jq -r ".errcode // empty" 2>/dev/null)
            if [[ "$res2Success" == "0" ]]; then
               echo "企业微信推送成功"
            else
               echo "企业微信推送失败，请检查AGENTID和USERID是否填写正确"
            fi
         fi
      else
         echo "获取access_token失败，请检查CORPID和SECRET是否填写正确"
      fi
   fi
fi

# 检测是否配置Synology Chat推送
if [[ -z "${Synology_Chat_URL:-}" ]]; then
   echo "未配置Synology Chat推送"
else
   synology_payload=$(jq -nc --arg text "$raw_msg" '{text: $text}')
   res=$(timeout 20s curl -s -X POST \
     "$Synology_Chat_URL" \
     --data-urlencode "payload=${synology_payload}")
   rc=$?
   if [ "$rc" -eq 124 ]; then
      echo 'Synology_Chat请求超时,请检查网络是否正常'
   else
      resSuccess=$(echo "$res" | jq -r ".success // empty" 2>/dev/null)
      if [[ "$resSuccess" == "true" ]]; then
         echo "Synology_Chat推送成功"
      else
         echo "Synology_Chat推送失败，请检查Synology_Chat_URL是否填写正确"
      fi
   fi
fi

return 0 2>/dev/null || exit 0
