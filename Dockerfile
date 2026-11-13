FROM alpine:3.19

LABEL maintainer="cloudfastddns" \
      description="CloudFastDDNS - Dockerized CloudflareSpeedTest DDNS with Web UI on port 9909"

# 构建阶段一次性安装运行所需全部系统环境，避免容器重启重复拉取依赖
RUN apk update && \
    apk add --no-cache \
        python3 \
        bash \
        jq \
        wget \
        curl \
        tar \
        sed \
        gawk \
        coreutils \
        dcron \
        procps \
        ca-certificates \
        tzdata && \
    cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone && \
    rm -rf /var/cache/apk/*

ENV TZ=Asia/Shanghai \
    DATA_DIR=/opt/cloudfastddns \
    APP_DIR=/app \
    PORT=9909 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY config.conf /app/config.conf
COPY start.sh /app/start.sh
COPY entrypoint.sh /app/entrypoint.sh
COPY cf_ddns/ /app/cf_ddns/
COPY web/ /app/web/

RUN sed -i 's/\r$//' /app/start.sh /app/entrypoint.sh /app/cf_ddns/*.sh /app/config.conf && \
    chmod +x /app/start.sh /app/entrypoint.sh /app/cf_ddns/*.sh /app/web/server.py && \
    mkdir -p /opt/cloudfastddns

VOLUME ["/opt/cloudfastddns"]

EXPOSE 9909

ENTRYPOINT ["/bin/bash", "/app/entrypoint.sh"]
