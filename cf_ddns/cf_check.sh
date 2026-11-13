#!/bin/bash
# ==============================================================================
# 用于CloudflareSpeedTestDDNS运行环境检测和必要软件初始化安装 (基于 main 分支改造)
# ==============================================================================

DATA_DIR="${DATA_DIR:-/opt/cloudfastddns}"
CF_DDNS_DIR="${DATA_DIR}/cf_ddns"
mkdir -p "${CF_DDNS_DIR}"

# 若直接以 --init-only 独立运行且未传入 PROXY，尝试从 config.conf 读取
if [ -z "${PROXY+x}" ] && [ -f "${DATA_DIR}/config.conf" ]; then
    sed -i 's/\r$//' "${DATA_DIR}/config.conf" 2>/dev/null || true
    # shellcheck disable=SC1091
    source "${DATA_DIR}/config.conf" 2>/dev/null || true
fi

# 读取配置文件中的 PROXY，若未设置则默认使用 https://gh-proxy.com/
if [ -z "${PROXY+x}" ]; then
    PROXY="https://gh-proxy.com/"
fi
# 若填写了代理且末尾没有 /，自动补齐 /
if [ -n "${PROXY}" ] && [[ "${PROXY}" != */ ]]; then
    PROXY="${PROXY}/"
fi

flag_file="${DATA_DIR}/.ran_before"
CloudflareST="${CF_DDNS_DIR}/cfst"
informlog="${CF_DDNS_DIR}/informlog"
cf_push="${CF_DDNS_DIR}/cf_push.sh"

# 仅在刚部署首次运行时进行环境检测与 cfst 拉取；已存在则绝不重复下载
if [ ! -e "$flag_file" ] || [ ! -f "${CloudflareST}" ]; then
    echo "首次部署初始化：正在检查运行环境与 cfst 组件..."

    packages=""
    command -v bash &> /dev/null || packages="$packages bash"
    command -v jq &> /dev/null   || packages="$packages jq"
    command -v wget &> /dev/null || packages="$packages wget"
    command -v curl &> /dev/null || packages="$packages curl"
    command -v tar &> /dev/null  || packages="$packages tar"
    command -v sed &> /dev/null  || packages="$packages sed"
    command -v awk &> /dev/null  || packages="$packages gawk"
    command -v tr &> /dev/null   || packages="$packages coreutils"

    if [ -n "$packages" ]; then
        echo "The following packages are required: $packages"
        if grep -qi "alpine" /etc/os-release 2>/dev/null; then
            apk update && apk add --no-cache $packages
        elif grep -qi "openwrt" /etc/os-release 2>/dev/null; then
            opkg update && opkg install $packages coreutils-timeout
        elif grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null; then
            apt-get update && apt-get install $packages -y
        elif grep -qi "centos\|red hat\|fedora" /etc/os-release 2>/dev/null; then
            yum install $packages -y
        else
            echo "未能检测出你的系统：$(uname)，请自行安装$packages这些软件。"
            exit 1
        fi
    fi

    # 检测 cfst 是否已存在，不存在则拉取
    if [ ! -f "${CloudflareST}" ]; then
        LATEST_URL="https://api.github.com/repos/XIU2/CloudflareSpeedTest/releases/latest"
        VERSION=$(curl -sL --connect-timeout 10 --max-time 15 "$LATEST_URL" | grep '"tag_name"' | head -n 1 | cut -d '"' -f 4)
        if [[ ! "$VERSION" =~ ^v[0-9]+ ]]; then
            VERSION="v2.3.5"
        fi
        echo "获取到 XIU2/CloudflareSpeedTest 版本: ${VERSION}，使用代理: ${PROXY:-无}"

        TMP_DIR="${CF_DDNS_DIR}/tmp"
        rm -rf "${TMP_DIR}" && mkdir -p "${TMP_DIR}"

        get_arch=$(uname -m)
        if [[ $get_arch =~ "x86_64" ]] || [[ $get_arch =~ "amd64" ]]; then
            echo "this is x86_64"
            CFST_ARCH="amd64"
        elif [[ $get_arch =~ "aarch64" ]] || [[ $get_arch =~ "arm64" ]]; then
            echo "this is arm64"
            CFST_ARCH="arm64"
        elif [[ $get_arch =~ "mips64" ]]; then
            echo "this is mips64"
            CFST_ARCH="mips64"
        else
            echo "找不到匹配的cfst程序($get_arch)，请自行下载'https://github.com/XIU2/CloudflareSpeedTest'，并解压至'${CF_DDNS_DIR}/'文件夹中。"
            echo "找不到匹配的cfst程序，请自行下载并解压至'${CF_DDNS_DIR}/'文件夹中。" > "$informlog"
            source "$cf_push"
            exit 1
        fi

        URL="https://github.com/XIU2/CloudflareSpeedTest/releases/download/${VERSION}/cfst_linux_${CFST_ARCH}.tar.gz"
        DOWNLOAD_URL="${PROXY}${URL}"
        TAR_FILE="${TMP_DIR}/cfst_linux_${CFST_ARCH}.tar.gz"

        echo "正在下载: ${DOWNLOAD_URL}"
        if ! curl -fSL --connect-timeout 15 --max-time 180 -o "${TAR_FILE}" "${DOWNLOAD_URL}"; then
            echo "通过代理下载失败，尝试直接从 GitHub 下载: ${URL}"
            curl -fSL --connect-timeout 15 --max-time 180 -o "${TAR_FILE}" "${URL}"
        fi

        if [ -f "${TAR_FILE}" ] && tar -tzf "${TAR_FILE}" >/dev/null 2>&1; then
            tar -zxf "${TAR_FILE}" -C "${TMP_DIR}/"
            # 适配新版 cfst_linux_amd64/cfst 子目录结构及顶层结构
            FOUND_CFST=$(find "${TMP_DIR}" -type f \( -name "cfst" -o -name "CloudflareST" \) | head -n 1)
            FOUND_IP=$(find "${TMP_DIR}" -type f -name "ip.txt" | head -n 1)
            FOUND_IPV6=$(find "${TMP_DIR}" -type f -name "ipv6.txt" | head -n 1)

            if [ -n "${FOUND_CFST}" ] && [ -f "${FOUND_CFST}" ]; then
                mv -f "${FOUND_CFST}" "${CloudflareST}"
                chmod +x "${CloudflareST}"
            fi
            [ -n "${FOUND_IP}" ] && [ -f "${FOUND_IP}" ] && mv -f "${FOUND_IP}" "${CF_DDNS_DIR}/ip.txt"
            [ -n "${FOUND_IPV6}" ] && [ -f "${FOUND_IPV6}" ] && mv -f "${FOUND_IPV6}" "${CF_DDNS_DIR}/ipv6.txt"
            rm -rf "${TMP_DIR}"
        else
            echo "下载或解压 cfst_linux_${CFST_ARCH}.tar.gz 失败，请检查网络或代理设置 (${PROXY})！"
            rm -rf "${TMP_DIR}"
            exit 1
        fi
    fi

    if [ ! -f "${CloudflareST}" ]; then
        echo "错误：未找到 ${CloudflareST} 可执行文件，初始化失败！"
        exit 1
    fi

    if [[ ! -x "${CloudflareST}" ]]; then
        chmod +x "${CloudflareST}"
    fi

    touch "$flag_file"
    echo "初始化完成！"
fi

# 若仅执行容器首次部署初始化 (--init-only)，到此退出
if [ "${1:-}" = "--init-only" ]; then
    exit 0
fi

# 初始化推送日志
if [ -e "${informlog}" ]; then
    rm -f "${informlog}"
fi

# 检测是否配置DDNS或更新HOSTS任意一个 (完全遵循 main 分支逻辑)
if [[ -z "${dnspod_token}" ]]; then
    IP_TO_DNSPOD=0
else
    IP_TO_DNSPOD=1
fi

if [[ -z "${api_key}" ]]; then
    IP_TO_CF=0
else
    IP_TO_CF=1
fi

if [ "$IP_TO_HOSTS" = "true" ]; then
    IP_TO_HOSTS=1
else
    IP_TO_HOSTS=0
fi

if [ "${DNS_PROVIDER:-1}" = "1" ] && [ "$IP_TO_CF" -eq 0 ] && [ "$IP_TO_HOSTS" -eq 0 ]; then
    echo "当前选择 Cloudflare，但未填写 Global API Key（且未开启更新 hosts）！！！"
    echo "当前选择 Cloudflare，但未填写 Global API Key（且未开启更新 hosts）！！！" > "$informlog"
    source "$cf_push"
    exit 1
elif [ "${DNS_PROVIDER:-1}" = "2" ] && [ "$IP_TO_DNSPOD" -eq 0 ] && [ "$IP_TO_HOSTS" -eq 0 ]; then
    echo "当前选择 DNSPod，但未填写 dnspod_token（且未开启更新 hosts）！！！"
    echo "当前选择 DNSPod，但未填写 dnspod_token（且未开启更新 hosts）！！！" > "$informlog"
    source "$cf_push"
    exit 1
elif [ $IP_TO_DNSPOD -eq 1 ] || [ $IP_TO_CF -eq 1 ] || [ $IP_TO_HOSTS -eq 1 ]; then
    echo "配置获取成功！"
else
    echo "HOSTS和cf_ddns均未配置！！！"
    echo "HOSTS和cf_ddns均未配置！！！" > "$informlog"
    source "$cf_push"
    exit 1
fi
