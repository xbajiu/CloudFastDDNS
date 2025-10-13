#!/bin/bash
# cf_push.sh - CloudflareSpeedTestDDNS 推送优化版本
# 支持 Telegram / PushPlus / Server 酱 / PushDeer / 企业微信 / Synology Chat
# 仅在配置对应推送参数时执行

LOG_FILE="./log/informlog"

# 检查日志文件是否存在
if [[ ! -f "$LOG_FILE" ]]; then
    echo "日志文件不存在: $LOG_FILE"
    exit 1
fi

# 读取日志内容
message_text=$(sed "$ ! s/$/\\\n/ " "$LOG_FILE" | tr -d '\n')
P_message_text=$(sed "$ ! s/$/\\%0A/ " "$LOG_FILE")  # URL编码换行，用于部分服务

###########################
# Telegram 推送
###########################
if [[ -n "$telegramBotToken" && -n "$telegramBotUserId" ]]; then
    tgapi="${Proxy_TG:-https://api.telegram.org}"
    TGURL="$tgapi/bot${telegramBotToken}/sendMessage"
    res=$(timeout 20s curl -s -X POST "$TGURL" \
        -H "Content-type:application/json" \
        -d '{"chat_id":"'"$telegramBotUserId"'", "parse_mode":"HTML", "text":"'"$message_text"'"}')
    if [[ $? -eq 124 ]]; then
        echo 'TG_api请求超时,请检查网络'
    else
        [[ $(echo "$res" | jq -r ".ok") = "true" ]] && echo "TG推送成功" || echo "TG推送失败"
    fi
fi

###########################
# PushPlus 推送
###########################
if [[ -n "$PushPlusToken" ]]; then
    res=$(timeout 20s curl -s -X POST "http://www.pushplus.plus/send" \
        -d "token=${PushPlusToken}" -d "title=cf优选ip推送" -d "content=${P_message_text}" -d "template=html")
    [[ $(echo "$res" | jq -r ".code") = 200 ]] && echo "PushPlus推送成功" || echo "PushPlus推送失败"
fi

###########################
# Server 酱 推送
###########################
if [[ -n "$ServerSendKey" ]]; then
    res=$(timeout 20s curl -s -X POST "https://sctapi.ftqq.com/${ServerSendKey}.send?title=cf优选ip推送" \
        -d "desp=${message_text}")
    [[ $(echo "$res" | jq -r ".code") = 0 ]] && echo "Server 酱推送成功" || echo "Server 酱推送失败"
fi

###########################
# PushDeer 推送
###########################
if [[ -n "$PushDeerPushKey" ]]; then
    res=$(timeout 20s curl -s -X POST "https://api2.pushdeer.com/message/push?pushkey=${PushDeerPushKey}" \
        -d "text=## cf优选ip推送" -d "desp=${P_message_text}")
    [[ $(echo "$res" | jq -r ".code") = 0 ]] && echo "PushDeer推送成功" || echo "PushDeer推送失败"
fi

###########################
# 企业微信 推送
###########################
if [[ -n "$CORPID" && -n "$SECRET" ]]; then
    token_res=$(timeout 10s curl -s -G "https://qyapi.weixin.qq.com/cgi-bin/gettoken" \
        --data-urlencode "corpid=${CORPID}" \
        --data-urlencode "corpsecret=${SECRET}")
    access_token=$(echo "$token_res" | jq -r '.access_token')
    if [[ -n "$access_token" && "$access_token" != "null" ]]; then
        curl -s -X POST "https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token=$access_token" \
            -H "Content-Type: application/json" \
            -d "{
                \"touser\": \"${TOUSER:-@all}\",
                \"msgtype\": \"text\",
                \"agentid\": ${AGENTID:-1000002},
                \"text\": {\"content\": \"$message_text\"},
                \"safe\":0
            }"
        echo "企业微信推送完成"
    else
        echo "获取企业微信 access_token 失败"
    fi
fi

###########################
# Synology Chat 推送
###########################
if [[ -n "$Synology_Chat_URL" ]]; then
    res=$(timeout 20s curl -s -X POST "$Synology_Chat_URL" \
        -H "Content-Type: application/json" \
        -d "{
            \"method\": \"incoming\",
            \"version\": \"2\",
            \"payload\": {\"text\": \"$message_text\"}
        }")
    [[ $(echo "$res" | jq -r ".success") = "true" ]] && echo "Synology Chat推送成功" || echo "Synology Chat推送失败"
fi
