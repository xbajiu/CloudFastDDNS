# 作者: xbajiu
FROM alpine:latest

RUN apk update && \
    apk add --no-cache bash jq wget curl tar sed gawk coreutils dcron tzdata && \
    cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone && \
    apk del tzdata && \
    rm -rf /var/cache/apk/*

WORKDIR /app
COPY . /app

RUN chmod +x /app/start.sh && \
    chmod +x /app/cf_ddns/*.sh || true

RUN mkdir -p /app/log && \
    touch /app/log/run.log /app/log/informlog && \
    chmod -R 755 /app/log

CMD ["/bin/sh", "-c", "stdbuf -oL -eL /bin/bash /app/start.sh > /dev/null 2>&1 & exec tail -n 0 -F /app/log/run.log"]
