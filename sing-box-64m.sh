#!/bin/bash

# =========================
# sing-box 多协议定制安装脚本 (64M小鸡低内存稳定优化版)
# 支持协议: vless-reality | vmess-ws(argo) | hysteria2 | tuic5 | anytls | socks5 | ss2022
# 功能特性:
#   1. 64M内存防OOM优化 (自动Swap兜底 / GOMEMLIMIT内存限制 / 按需启停Argo / 精简规则集)
#   2. 支持自定义选择安装生成哪些协议节点
#   3. 支持随时删除任意指定协议节点 (含核心四协议与扩展协议)
#   4. 支持随时恢复、添加指定协议节点及一键恢复四合一
#   5. 支持重新设置入站IP (自定义节点连接IP/域名 + 修改服务端监听地址)
#   6. 支持彻底卸载并恢复系统初始状态 (清理服务/防火墙/NAT规则/Nginx配置/Swap)
# =========================

export LANG=en_US.UTF-8

# 定义颜色
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
skyblue="\e[1;36m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue() { echo -e "\e[1;36m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }

# 定义常量与持久化文件路径
server_name="sing-box"
work_dir="/etc/sing-box"
conf_dir="${work_dir}/conf"
client_dir="${work_dir}/url.txt"
sub_file="${work_dir}/sub.txt"
meta_file="${work_dir}/meta.conf"
ports_file="${work_dir}/ports.list"
swap_file="/swapfile_sb"

export vless_port=${PORT:-$(shuf -i 10000-60000 -n 1)}
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export ARGO_PORT=${ARGO_PORT:-'8001'}
export CFPORT=${CFPORT:-'443'}

# 检查是否为root下运行
[[ $EUID -ne 0 ]] && red "请在root用户下运行脚本，可输入 sudo -i 回车切换到root用户" && exit 1

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# =========================
# 64M 内存防崩溃与 Swap 兜底优化
# =========================
optimize_low_memory() {
    local mem_total
    mem_total=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 256)
    local swap_total
    swap_total=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)

    # 内核内存分配策略优化，防止 Go 虚拟地址空间申请被拒
    sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 || true
    sysctl -w vm.vfs_cache_pressure=200 >/dev/null 2>&1 || true

    if [ "$mem_total" -le 192 ] && [ "$swap_total" -lt 64 ]; then
        yellow "检测到当前可用物理内存较小 (${mem_total}MB)，正在尝试创建 128MB 临时虚拟内存(Swap)防崩溃..."
        if [ ! -f "$swap_file" ]; then
            dd if=/dev/zero of="$swap_file" bs=1M count=128 status=none 2>/dev/null || true
            chmod 600 "$swap_file" 2>/dev/null || true
            mkswap "$swap_file" >/dev/null 2>&1 || true
            if swapon "$swap_file" >/dev/null 2>&1; then
                sysctl -w vm.swappiness=60 >/dev/null 2>&1 || true
                if ! grep -q "$swap_file" /etc/fstab 2>/dev/null; then
                    echo "$swap_file swap swap defaults 0 0" >> /etc/fstab
                fi
                green "128MB Swap 创建并启用成功！"
            else
                rm -f "$swap_file" >/dev/null 2>&1 || true
                yellow "当前虚拟化架构(如LXC/OpenVZ)不支持挂载Swap，已启用 Go 内存硬限制模式保障运行。"
            fi
        fi
    fi
}

# =========================
# 元数据读写函数 (保证删除/恢复协议时参数一致)
# =========================
save_meta() {
    local key="$1"
    local val="$2"
    mkdir -p "$work_dir"
    touch "$meta_file"
    if grep -q "^${key}=" "$meta_file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$meta_file"
    else
        echo "${key}=\"${val}\"" >> "$meta_file"
    fi
}

load_meta() {
    [ -f "$meta_file" ] && source "$meta_file"
}

# =========================
# 修复后的服务状态检查函数
# =========================
get_service_file() {
    local sname="$1"
    case "$sname" in
        sing-box) echo "${work_dir}/${server_name}" ;;
        argo)     echo "${work_dir}/argo" ;;
        nginx)    command -v nginx 2>/dev/null || echo "/usr/sbin/nginx" ;;
        *)        echo "" ;;
    esac
}

# 返回纯文本状态: running | not running | not installed
check_service_raw() {
    local service_name="$1"
    local service_file="${2:-$(get_service_file "$service_name")}"

    if [ -z "$service_file" ] || [ ! -f "$service_file" ]; then
        echo "not installed"
        return 2
    fi

    if command_exists rc-service; then
        if rc-service "${service_name}" status 2>/dev/null | grep -q "started"; then
            echo "running"; return 0
        else
            echo "not running"; return 1
        fi
    else
        if systemctl is-active "${service_name}" 2>/dev/null | grep -q "^active$"; then
            echo "running"; return 0
        else
            echo "not running"; return 1
        fi
    fi
}

check_service() {
    local st
    st=$(check_service_raw "$1" "$2")
    local ret=$?
    case "$st" in
        "running")       green "running" ;;
        "not running")   yellow "not running" ;;
        "not installed") red "not installed" ;;
    esac
    return $ret
}

check_singbox() { check_service "sing-box" "${work_dir}/${server_name}"; }
check_argo()    { check_service "argo" "${work_dir}/argo"; }
check_nginx()   { check_service "nginx" "$(command -v nginx 2>/dev/null)"; }

# =========================
# 低内存友好的依赖包管理
# =========================
manage_packages() {
    if [ $# -lt 2 ]; then
        red "Unspecified package name or action"
        return 1
    fi

    local action=$1
    shift

    # 针对64M小鸡优化：仅更新软件源索引，绝不执行全量 upgrade 防止OOM
    if [ "$action" == "install" ]; then
        local need_update=0
        for pkg in "$@"; do
            command_exists "$pkg" || need_update=1
        done
        if [ "$need_update" -eq 1 ]; then
            yellow "正在更新软件源索引 (低内存轻量模式)..."
            if command_exists apt; then
                DEBIAN_FRONTEND=noninteractive apt-get update -y -o Acquire::Languages=none >/dev/null 2>&1 || true
            elif command_exists apk; then
                apk update >/dev/null 2>&1 || true
            fi
        fi
    fi

    for package in "$@"; do
        if [ "$action" == "install" ]; then
            if command_exists "$package"; then
                continue
            fi
            # coreutils 特殊检测
            if [ "$package" == "coreutils" ] && command_exists base64 && command_exists shuf; then
                continue
            fi
            yellow "正在安装 ${package}..."
            if command_exists apt; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$package" >/dev/null 2>&1
            elif command_exists dnf; then
                dnf install -y "$package" >/dev/null 2>&1
            elif command_exists yum; then
                yum install -y "$package" >/dev/null 2>&1
            elif command_exists apk; then
                apk add --no-cache "$package" >/dev/null 2>&1
            else
                red "Unknown system!"
                return 1
            fi
        elif [ "$action" == "uninstall" ]; then
            if ! command_exists "$package"; then
                continue
            fi
            yellow "正在卸载 ${package}..."
            if command_exists apt; then
                DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y "$package" >/dev/null 2>&1
                DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1
            elif command_exists dnf; then
                dnf remove -y "$package" >/dev/null 2>&1
            elif command_exists yum; then
                yum remove -y "$package" >/dev/null 2>&1
            elif command_exists apk; then
                apk del "$package" >/dev/null 2>&1
            fi
        fi
    done
    return 0
}

# =========================
# 获取公网IP与ISP信息
# =========================
detect_public_ip() {
    local ip v6
    ip=$(curl -4 -sm 3 ip.sb || curl -4 -sm 3 api.ipify.org || curl -4 -sm 3 ifconfig.me)
    v6=$(curl -6 -sm 3 ip.sb || curl -6 -sm 3 api64.ipify.org)
    if [ -z "$ip" ]; then
        [ -n "$v6" ] && echo "[${v6}]" || echo "127.0.0.1"
    else
        if curl -4 -sm 2 http://ipinfo.io/org 2>/dev/null | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
            [ -n "$v6" ] && echo "[${v6}]" || echo "$ip"
        else
            echo "$ip"
        fi
    fi
}

get_realip() {
    load_meta
    if [ -n "$CUSTOM_NODE_IP" ]; then
        echo "$CUSTOM_NODE_IP"
    else
        local detected
        detected=$(detect_public_ip)
        save_meta "CUSTOM_NODE_IP" "$detected"
        echo "$detected"
    fi
}

get_isp_name() {
    load_meta
    if [ -n "$ISP_NAME" ]; then
        echo "$ISP_NAME"
        return
    fi
    local isp
    isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' | \
        awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | \
        sed 's/ /_/g')
    [ -z "$isp" ] && isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://ipapi.co/json" | tr -d '\n' | \
        awk -F\" '{c="";o="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="org")o=$(x+2)};if(c&&o)print c"-"o}' | \
        sed 's/ /_/g')
    [ -z "$isp" ] && isp=$(hostname 2>/dev/null || echo "SingBox")
    save_meta "ISP_NAME" "$isp"
    echo "$isp"
}

# =========================
# 防火墙放行与清理管理
# =========================
allow_port() {
    local has_ufw=0 has_firewalld=0 has_iptables=0 has_ip6tables=0
    command_exists ufw && has_ufw=1
    command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1 && has_firewalld=1
    command_exists iptables && has_iptables=1
    command_exists ip6tables && has_ip6tables=1

    mkdir -p "$work_dir"
    touch "$ports_file"

    for rule in "$@"; do
        local port=${rule%/*}
        local proto=${rule#*/}
        [ -z "$port" ] || [ -z "$proto" ] && continue

        grep -qxF "${port}/${proto}" "$ports_file" 2>/dev/null || echo "${port}/${proto}" >> "$ports_file"

        [ "$has_ufw" -eq 1 ] && ufw allow in "${port}/${proto}" >/dev/null 2>&1
        [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1
        [ "$has_iptables" -eq 1 ] && (iptables -C INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null)
        [ "$has_ip6tables" -eq 1 ] && (ip6tables -C INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || ip6tables -I INPUT 1 -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null)
    done

    [ "$has_firewalld" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1
}

clean_firewall_rules() {
    if [ -f "$ports_file" ]; then
        while IFS= read -r rule; do
            [ -z "$rule" ] && continue
            local port=${rule%/*}
            local proto=${rule#*/}
            command_exists ufw && ufw delete allow in "${port}/${proto}" >/dev/null 2>&1 || true
            command_exists firewall-cmd && firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || true
            command_exists iptables && iptables -D INPUT -p "${proto}" --dport "${port}" -j ACCEPT >/dev/null 2>&1 || true
            command_exists ip6tables && ip6tables -D INPUT -p "${proto}" --dport "${port}" -j ACCEPT >/dev/null 2>&1 || true
        done < "$ports_file"
        command_exists firewall-cmd && firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    # 清理 Hysteria2 端口跳跃 NAT 规则
    load_meta
    if [ -n "$HY2_MPORT_MIN" ] && [ -n "$HY2_MPORT_MAX" ] && [ -n "$HY2_PORT" ]; then
        command_exists iptables && iptables -t nat -D PREROUTING -p udp --dport "${HY2_MPORT_MIN}:${HY2_MPORT_MAX}" -j DNAT --to-destination ":${HY2_PORT}" >/dev/null 2>&1 || true
        command_exists ip6tables && ip6tables -t nat -D PREROUTING -p udp --dport "${HY2_MPORT_MIN}:${HY2_MPORT_MAX}" -j DNAT --to-destination ":${HY2_PORT}" >/dev/null 2>&1 || true
    fi
}

# =========================
# 通用服务管理函数
# =========================
manage_service() {
    local service_name="$1"
    local action="$2"

    if [ -z "$service_name" ] || [ -z "$action" ]; then
        red "缺少服务名或操作参数\n"; return 1
    fi

    local status
    status=$(check_service_raw "$service_name")

    case "$action" in
        "start")
            [ "$status" == "running" ] && { yellow "${service_name} 正在运行\n"; return 0; }
            [ "$status" == "not installed" ] && { yellow "${service_name} 尚未安装!\n"; return 1; }
            if command_exists rc-service; then rc-service "$service_name" start >/dev/null 2>&1
            elif command_exists systemctl; then systemctl daemon-reload && systemctl start "$service_name" >/dev/null 2>&1; fi
            ;;
        "stop")
            [ "$status" == "not installed" ] && return 2
            [ "$status" == "not running" ] && return 0
            if command_exists rc-service; then rc-service "$service_name" stop >/dev/null 2>&1
            elif command_exists systemctl; then systemctl stop "$service_name" >/dev/null 2>&1; fi
            ;;
        "restart")
            [ "$status" == "not installed" ] && { yellow "${service_name} 尚未安装！\n"; return 1; }
            if command_exists rc-service; then rc-service "$service_name" restart >/dev/null 2>&1
            elif command_exists systemctl; then systemctl daemon-reload && systemctl restart "$service_name" >/dev/null 2>&1; fi
            ;;
    esac
}

start_singbox()   { manage_service "sing-box" "start"; }
stop_singbox()    { manage_service "sing-box" "stop"; }
restart_singbox() { manage_service "sing-box" "restart"; }
start_argo()      { manage_service "argo" "start"; }
stop_argo()       { manage_service "argo" "stop"; }
restart_argo()    { manage_service "argo" "restart"; }
start_nginx()     { manage_service "nginx" "start"; }
restart_nginx()   { manage_service "nginx" "restart"; }

# =========================
# 协议存在性与 JSON 构造函数
# =========================
proto_exists() {
    local tag="$1"
    [ -f "${conf_dir}/inbounds.json" ] && jq -e --arg tag "$tag" '.inbounds[] | select(.tag == $tag)' "${conf_dir}/inbounds.json" >/dev/null 2>&1
}

# 向 inbounds.json 添加或更新单个协议 (内部核心函数)
add_proto_to_inbounds() {
    local proto_key="$1"
    local interactive="${2:-0}"
    local inbounds_file="${conf_dir}/inbounds.json"
    load_meta
    local listen_ip="${LISTEN_IP:-::}"

    case "$proto_key" in
        vless|vless-reality)
            if proto_exists "vless-reality"; then
                [ "$interactive" -eq 1 ] && yellow "vless-reality 已存在，无需重复添加。"
                return 0
            fi
            local port="${VLESS_PORT:-$(shuf -i 10000-60000 -n 1)}"
            if [ "$interactive" -eq 1 ]; then
                reading "请输入 vless-reality 端口 (回车默认 ${port}): " input_p
                [ -n "$input_p" ] && port="$input_p"
            fi
            save_meta "VLESS_PORT" "$port"
            local sni="${REALITY_SNI:-www.iij.ad.jp}"
            save_meta "REALITY_SNI" "$sni"

            jq --arg listen "$listen_ip" \
               --argjson port "$port" \
               --arg uuid "$UUID" \
               --arg sni "$sni" \
               --arg pk "$PRIVATE_KEY" \
               '.inbounds += [{
                   "type": "vless",
                   "tag": "vless-reality",
                   "listen": $listen,
                   "listen_port": $port,
                   "users": [{"uuid": $uuid, "flow": "xtls-rprx-vision"}],
                   "tls": {
                       "enabled": true,
                       "server_name": $sni,
                       "reality": {
                           "enabled": true,
                           "handshake": {"server": $sni, "server_port": 443},
                           "private_key": $pk,
                           "short_id": [""]
                       }
                   }
               }]' "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
            allow_port "${port}/tcp"
            ;;

        vmess|vmess-ws)
            if proto_exists "vmess-ws"; then
                [ "$interactive" -eq 1 ] && yellow "vmess-ws 已存在，无需重复添加。"
                return 0
            fi
            local port="${VMESS_PORT:-8001}"
            if [ "$interactive" -eq 1 ]; then
                reading "请输入 vmess-ws (Argo) 本地监听端口 (回车默认 ${port}): " input_p
                [ -n "$input_p" ] && port="$input_p"
            fi
            save_meta "VMESS_PORT" "$port"

            jq --arg listen "$listen_ip" \
               --argjson port "$port" \
               --arg uuid "$UUID" \
               '.inbounds += [{
                   "type": "vmess",
                   "tag": "vmess-ws",
                   "listen": $listen,
                   "listen_port": $port,
                   "users": [{"uuid": $uuid}],
                   "transport": {
                       "type": "ws",
                       "path": "/vmess-argo",
                       "early_data_header_name": "Sec-WebSocket-Protocol"
                   }
               }]' "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
            allow_port "${port}/tcp"
            sync_argo_service
            ;;

        hy2|hysteria2)
            if proto_exists "hysteria2"; then
                [ "$interactive" -eq 1 ] && yellow "hysteria2 已存在，无需重复添加。"
                return 0
            fi
            local port="${HY2_PORT:-$(shuf -i 10000-60000 -n 1)}"
            if [ "$interactive" -eq 1 ]; then
                reading "请输入 hysteria2 端口 (回车默认 ${port}): " input_p
                [ -n "$input_p" ] && port="$input_p"
            fi
            save_meta "HY2_PORT" "$port"

            jq --arg listen "$listen_ip" \
               --argjson port "$port" \
               --arg uuid "$UUID" \
               --arg cert "${work_dir}/cert.pem" \
               --arg key "${work_dir}/private.key" \
               '.inbounds += [{
                   "type": "hysteria2",
                   "tag": "hysteria2",
                   "listen": $listen,
                   "listen_port": $port,
                   "users": [{"password": $uuid}],
                   "ignore_client_bandwidth": false,
                   "masquerade": "https://bing.com",
                   "tls": {
                       "enabled": true,
                       "alpn": ["h3"],
                       "min_version": "1.3",
                       "max_version": "1.3",
                       "certificate_path": $cert,
                       "key_path": $key
                   }
               }]' "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
            allow_port "${port}/udp"
            ;;

        tuic|tuic5)
            if proto_exists "tuic"; then
                [ "$interactive" -eq 1 ] && yellow "tuic 已存在，无需重复添加。"
                return 0
            fi
            local port="${TUIC_PORT:-$(shuf -i 10000-60000 -n 1)}"
            if [ "$interactive" -eq 1 ]; then
                reading "请输入 tuic 端口 (回车默认 ${port}): " input_p
                [ -n "$input_p" ] && port="$input_p"
            fi
            save_meta "TUIC_PORT" "$port"

            jq --arg listen "$listen_ip" \
               --argjson port "$port" \
               --arg uuid "$UUID" \
               --arg cert "${work_dir}/cert.pem" \
               --arg key "${work_dir}/private.key" \
               '.inbounds += [{
                   "type": "tuic",
                   "tag": "tuic",
                   "listen": $listen,
                   "listen_port": $port,
                   "users": [{"uuid": $uuid, "password": $uuid}],
                   "congestion_control": "bbr",
                   "tls": {
                       "enabled": true,
                       "alpn": ["h3"],
                       "certificate_path": $cert,
                       "key_path": $key
                   }
               }]' "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
            allow_port "${port}/udp"
            ;;

        anytls)
            if proto_exists "anytls"; then
                [ "$interactive" -eq 1 ] && yellow "anytls 已存在，无需重复添加。"
                return 0
            fi
            local port="${ANYTLS_PORT:-$(shuf -i 10000-60000 -n 1)}"
            if [ "$interactive" -eq 1 ]; then
                reading "请输入 AnyTLS 监听端口 (回车默认 ${port}): " input_p
                [ -n "$input_p" ] && port="$input_p"
            fi
            save_meta "ANYTLS_PORT" "$port"

            jq --arg listen "$listen_ip" \
               --argjson port "$port" \
               --arg pass "$UUID" \
               --arg cert "${work_dir}/cert.pem" \
               --arg key "${work_dir}/private.key" \
               '.inbounds += [{
                   "type": "anytls",
                   "tag": "anytls",
                   "listen": $listen,
                   "listen_port": $port,
                   "users": [{"password": $pass}],
                   "tls": {
                       "enabled": true,
                       "certificate_path": $cert,
                       "key_path": $key
                   }
               }]' "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
            allow_port "${port}/tcp"
            ;;

        socks|socks5|socks5-in)
            if proto_exists "socks5-in"; then
                [ "$interactive" -eq 1 ] && yellow "socks5 已存在，无需重复添加。"
                return 0
            fi
            local port="${SOCKS_PORT:-$(shuf -i 10000-60000 -n 1)}"
            local sk_user="${SOCKS_USER:-${UUID:0:8}}"
            local sk_pass="${SOCKS_PASS:-${UUID: -12}}"
            if [ "$interactive" -eq 1 ]; then
                reading "请输入 Socks5 端口 (回车默认 ${port}): " input_p
                [ -n "$input_p" ] && port="$input_p"
                reading "请输入 Socks5 用户名 (回车默认 ${sk_user}): " input_u
                [ -n "$input_u" ] && sk_user="$input_u"
                reading "请输入 Socks5 密码 (回车默认 ${sk_pass}): " input_pw
                [ -n "$input_pw" ] && sk_pass="$input_pw"
            fi
            save_meta "SOCKS_PORT" "$port"
            save_meta "SOCKS_USER" "$sk_user"
            save_meta "SOCKS_PASS" "$sk_pass"

            jq --arg listen "$listen_ip" \
               --argjson port "$port" \
               --arg user "$sk_user" \
               --arg pass "$sk_pass" \
               '.inbounds += [{
                   "type": "socks",
                   "tag": "socks5-in",
                   "listen": $listen,
                   "listen_port": $port,
                   "users": [{"username": $user, "password": $pass}]
               }]' "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
            allow_port "${port}/tcp" "${port}/udp"
            ;;

        ss|ss2022|shadowsocks-2022)
            if proto_exists "shadowsocks-2022"; then
                [ "$interactive" -eq 1 ] && yellow "shadowsocks-2022 已存在，无需重复添加。"
                return 0
            fi
            local port="${SS_PORT:-$(shuf -i 10000-60000 -n 1)}"
            local ss_method="${SS_METHOD:-2022-blake3-aes-128-gcm}"
            local key_len=16
            if [ "$interactive" -eq 1 ]; then
                reading "请输入 Shadowsocks-2022 端口 (回车默认 ${port}): " input_p
                [ -n "$input_p" ] && port="$input_p"
                echo ""
                green "请选择加密方式:"
                green "1. 2022-blake3-aes-128-gcm       (默认，16字节密钥)"
                green "2. 2022-blake3-aes-256-gcm       (32字节密钥)"
                green "3. 2022-blake3-chacha20-poly1305 (32字节密钥)"
                reading "请输入选择 (默认1): " m_choice
                case "$m_choice" in
                    2) ss_method="2022-blake3-aes-256-gcm"; key_len=32 ;;
                    3) ss_method="2022-blake3-chacha20-poly1305"; key_len=32 ;;
                    *) ss_method="2022-blake3-aes-128-gcm"; key_len=16 ;;
                esac
            fi
            local ss_key
            ss_key=$(dd if=/dev/urandom bs=1 count=${key_len} 2>/dev/null | base64 -w0)
            save_meta "SS_PORT" "$port"
            save_meta "SS_METHOD" "$ss_method"
            save_meta "SS_KEY" "$ss_key"

            jq --arg listen "$listen_ip" \
               --argjson port "$port" \
               --arg method "$ss_method" \
               --arg key "$ss_key" \
               '.inbounds += [{
                   "type": "shadowsocks",
                   "tag": "shadowsocks-2022",
                   "listen": $listen,
                   "listen_port": $port,
                   "method": $method,
                   "password": $key,
                   "multiplex": {"enabled": true}
               }]' "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
            allow_port "${port}/tcp" "${port}/udp"
            ;;
    esac
}

# 从 inbounds.json 删除指定协议标签
remove_proto_from_inbounds() {
    local tag="$1"
    local inbounds_file="${conf_dir}/inbounds.json"
    if ! proto_exists "$tag"; then
        yellow "协议 [$tag] 当前未启用，无需删除。"
        return 1
    fi

    jq --arg tag "$tag" 'del(.inbounds[] | select(.tag == $tag))' \
        "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"

    # 如果删除了 vmess-ws，自动停止 argo 释放 35M+ 内存
    if [ "$tag" == "vmess-ws" ]; then
        stop_argo
        if command_exists systemctl; then
            systemctl disable argo >/dev/null 2>&1 || true
        elif command_exists rc-update; then
            rc-update del argo default >/dev/null 2>&1 || true
        fi
        yellow "已自动停止 Argo 隧道服务以节省内存。"
    fi
    return 0
}

# =========================
# 动态重建 url.txt 与 sub.txt (核心同步引擎)
# =========================
rebuild_urls() {
    local inbounds_file="${conf_dir}/inbounds.json"
    [ ! -f "$inbounds_file" ] && return 1

    load_meta
    local server_ip
    server_ip=$(get_realip)
    local isp
    isp=$(get_isp_name)
    local cfip="${CFIP_SAVED:-${CFIP}}"
    local cfport="${CFPORT_SAVED:-${CFPORT}}"

    > "$client_dir"

    # 1. vless-reality
    if proto_exists "vless-reality"; then
        local v_port v_uuid v_sni
        v_port=$(jq -r '.inbounds[] | select(.tag == "vless-reality") | .listen_port' "$inbounds_file")
        v_uuid=$(jq -r '.inbounds[] | select(.tag == "vless-reality") | .users[0].uuid' "$inbounds_file")
        v_sni=$(jq -r '.inbounds[] | select(.tag == "vless-reality") | .tls.server_name' "$inbounds_file")
        echo "vless://${v_uuid}@${server_ip}:${v_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${v_sni}&fp=firefox&pbk=${PUBLIC_KEY}&type=tcp&headerType=none#${isp}" >> "$client_dir"
        echo "" >> "$client_dir"
    fi

    # 2. vmess-ws (Argo)
    if proto_exists "vmess-ws"; then
        local m_uuid argodomain
        m_uuid=$(jq -r '.inbounds[] | select(.tag == "vmess-ws") | .users[0].uuid' "$inbounds_file")
        argodomain="${ARGO_DOMAIN}"
        if [ -z "$argodomain" ] && [ -f "${work_dir}/argo.log" ]; then
            argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -1)
        fi
        [ -z "$argodomain" ] && argodomain="argo-pending.trycloudflare.com"
        save_meta "ARGO_DOMAIN" "$argodomain"

        local vmess_json
        vmess_json="{ \"v\": \"2\", \"ps\": \"${isp}\", \"add\": \"${cfip}\", \"port\": \"${cfport}\", \"id\": \"${m_uuid}\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess-argo?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"firefox\", \"allowInsecure\": \"false\"}"
        echo "vmess://$(printf '%s' "$vmess_json" | base64 -w0 2>/dev/null || printf '%s' "$vmess_json" | base64 | tr -d '\n')" >> "$client_dir"
        echo "" >> "$client_dir"
    fi

    # 3. hysteria2
    if proto_exists "hysteria2"; then
        local h_port h_pass mport_str=""
        h_port=$(jq -r '.inbounds[] | select(.tag == "hysteria2") | .listen_port' "$inbounds_file")
        h_pass=$(jq -r '.inbounds[] | select(.tag == "hysteria2") | .users[0].password' "$inbounds_file")
        if [ -n "$HY2_MPORT_MIN" ] && [ -n "$HY2_MPORT_MAX" ]; then
            mport_str="&mport=${h_port},${HY2_MPORT_MIN}-${HY2_MPORT_MAX}"
        fi
        echo "hysteria2://${h_pass}@${server_ip}:${h_port}/?sni=www.bing.com&insecure=1&pinSHA256=${FINGERPRINT}&alpn=h3&obfs=none${mport_str}#${isp}" >> "$client_dir"
        echo "" >> "$client_dir"
    fi

    # 4. tuic
    if proto_exists "tuic"; then
        local t_port t_uuid t_pass
        t_port=$(jq -r '.inbounds[] | select(.tag == "tuic") | .listen_port' "$inbounds_file")
        t_uuid=$(jq -r '.inbounds[] | select(.tag == "tuic") | .users[0].uuid' "$inbounds_file")
        t_pass=$(jq -r '.inbounds[] | select(.tag == "tuic") | .users[0].password' "$inbounds_file")
        echo "tuic://${t_uuid}:${t_pass}@${server_ip}:${t_port}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${isp}" >> "$client_dir"
        echo "" >> "$client_dir"
    fi

    # 5. anytls
    if proto_exists "anytls"; then
        local a_port a_pass
        a_port=$(jq -r '.inbounds[] | select(.tag == "anytls") | .listen_port' "$inbounds_file")
        a_pass=$(jq -r '.inbounds[] | select(.tag == "anytls") | .users[0].password' "$inbounds_file")
        echo "anytls://${a_pass}@${server_ip}:${a_port}?insecure=1&sni=bing.com#${isp}" >> "$client_dir"
        echo "" >> "$client_dir"
    fi

    # 6. socks5-in
    if proto_exists "socks5-in"; then
        local s_port s_user s_pass s_auth
        s_port=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .listen_port' "$inbounds_file")
        s_user=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .users[0].username' "$inbounds_file")
        s_pass=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .users[0].password' "$inbounds_file")
        s_auth=$(printf '%s:%s' "$s_user" "$s_pass" | base64 -w0 2>/dev/null || printf '%s:%s' "$s_user" "$s_pass" | base64 | tr -d '\n')
        echo "socks://${s_auth}@${server_ip}:${s_port}#${isp}" >> "$client_dir"
        echo "" >> "$client_dir"
    fi

    # 7. shadowsocks-2022
    if proto_exists "shadowsocks-2022"; then
        local ss_port ss_method ss_key ss_auth
        ss_port=$(jq -r '.inbounds[] | select(.tag == "shadowsocks-2022") | .listen_port' "$inbounds_file")
        ss_method=$(jq -r '.inbounds[] | select(.tag == "shadowsocks-2022") | .method' "$inbounds_file")
        ss_key=$(jq -r '.inbounds[] | select(.tag == "shadowsocks-2022") | .password' "$inbounds_file")
        ss_auth=$(printf '%s:%s' "$ss_method" "$ss_key" | base64 -w0 2>/dev/null || printf '%s:%s' "$ss_method" "$ss_key" | base64 | tr -d '\n')
        echo "ss://${ss_auth}@${server_ip}:${ss_port}#${isp}" >> "$client_dir"
        echo "" >> "$client_dir"
    fi

    # 去除多余空行并生成 Base64 订阅
    sed -i '/^$/N;/^\n$/D' "$client_dir" 2>/dev/null || true
    base64 -w0 "$client_dir" > "$sub_file" 2>/dev/null || base64 "$client_dir" | tr -d '\n\r' > "$sub_file"
    chmod 644 "$sub_file" 2>/dev/null || true
}

update_sub() {
    rebuild_urls
}

# =========================
# 安装前选择自定义生成协议
# =========================
select_install_protocols() {
    if [ -n "$SELECTED_PROTOS" ]; then
        return 0
    fi
    clear
    purple "=== 自定义选择要生成的协议节点 (支持64M小鸡按需精简) ==="
    echo ""
    green "  1. vless-reality       (推荐，极低内存，TCP直连)"
    green "  2. vmess-ws + Argo隧道 (套CF隧道，需额外运行argo进程约占30M内存)"
    green "  3. hysteria2           (UDP高速协议，适合高丢包线路)"
    green "  4. tuic v5             (UDP低延迟协议)"
    green "  5. AnyTLS              (新式TLS伪装协议)"
    green "  6. Socks5              (基础代理协议)"
    green "  7. Shadowsocks-2022    (轻量级SS2022加密协议)"
    skyblue "--------------------------------------------------------"
    yellow "提示: 可输入多个编号用空格或逗号隔开 (例如: 1 3 或 1,3,7)"
    yellow "      64M极小内存机器如果不套CF隧道，强烈建议不选 2 (省去argo进程)"
    yellow "      直接按回车键默认生成 [1 2 3 4] 标准四合一协议"
    echo ""
    reading "请输入要生成的协议编号 (直接回车默认 1 2 3 4): " proto_input

    if [ -z "$proto_input" ] || [ "$proto_input" == "all" ]; then
        SELECTED_PROTOS="1 2 3 4"
    else
        SELECTED_PROTOS=$(echo "$proto_input" | tr ',' ' ')
    fi
}

# =========================
# 下载并初始化配置
# =========================
install_singbox() {
    optimize_low_memory
    clear
    purple "正在安装 sing-box 中，请稍候..."
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64' | 'amd64')  ARCH='amd64' ;;
        'x86' | 'i686' | 'i386') ARCH='386' ;;
        'aarch64' | 'arm64') ARCH='arm64' ;;
        'armv7l')  ARCH='armv7' ;;
        's390x')   ARCH='s390x' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac

    mkdir -p "${work_dir}" "${conf_dir}"
    chmod 755 "${work_dir}"

    curl -sLo "${work_dir}/qrencode" "https://$ARCH.eooce.com/qrencode"
    curl -sLo "${work_dir}/sing-box" "https://$ARCH.eooce.com/sb"
    curl -sLo "${work_dir}/argo" "https://$ARCH.eooce.com/bot"
    chown root:root "${work_dir}"
    chmod +x "${work_dir}/${server_name}" "${work_dir}/argo" "${work_dir}/qrencode"

    nginx_port=$((vless_port + 1))
    tuic_port=$((vless_port + 2))
    hy2_port=$((vless_port + 3))
    uuid=$(cat /proc/sys/kernel/random/uuid)
    password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)
    output=$("${work_dir}/sing-box" generate reality-keypair)
    private_key=$(echo "${output}" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "${output}" | awk '/PublicKey:/ {print $2}')

    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key" >/dev/null 2>&1
    openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com" >/dev/null 2>&1
    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g')

    # 保存核心元数据，便于后续随时删除/恢复/修改协议
    save_meta "UUID" "$uuid"
    save_meta "SUB_PASSWORD" "$password"
    save_meta "NGINX_PORT" "$nginx_port"
    save_meta "VLESS_PORT" "$vless_port"
    save_meta "VMESS_PORT" "$ARGO_PORT"
    save_meta "HY2_PORT" "$hy2_port"
    save_meta "TUIC_PORT" "$tuic_port"
    save_meta "PRIVATE_KEY" "$private_key"
    save_meta "PUBLIC_KEY" "$public_key"
    save_meta "FINGERPRINT" "$fingerprint"
    save_meta "REALITY_SNI" "www.iij.ad.jp"
    save_meta "CFIP_SAVED" "$CFIP"
    save_meta "CFPORT_SAVED" "$CFPORT"
    save_meta "LISTEN_IP" "::"

    allow_port "${nginx_port}/tcp" >/dev/null 2>&1

    dns_strategy=$(ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && echo "prefer_ipv4" || \
        (ping -c 1 -W 2 2001:4860:4860::8888 >/dev/null 2>&1 && echo "prefer_ipv6" || echo "prefer_ipv4"))

    cat > "${conf_dir}/log.json" << EOF
{
  "log": {
    "disabled": false,
    "level": "error",
    "output": "$work_dir/sb.log",
    "timestamp": true
  }
}
EOF

    cat > "${conf_dir}/ntp.json" << EOF
{
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "60m"
  }
}
EOF

    cat > "${conf_dir}/dns.json" << EOF
{
  "dns": {
    "servers": [
      {
        "tag": "local",
        "type": "local"
      }
    ],
    "strategy": "$dns_strategy"
  }
}
EOF

    # 初始化空 inbounds 数组，按用户选择的协议动态填充
    echo '{"inbounds": []}' > "${conf_dir}/inbounds.json"

    for item in $SELECTED_PROTOS; do
        case "$item" in
            1|vless)   add_proto_to_inbounds "vless-reality" 0 ;;
            2|vmess)   add_proto_to_inbounds "vmess-ws" 0 ;;
            3|hy2)     add_proto_to_inbounds "hysteria2" 0 ;;
            4|tuic)    add_proto_to_inbounds "tuic" 0 ;;
            5|anytls)  add_proto_to_inbounds "anytls" 0 ;;
            6|socks5)  add_proto_to_inbounds "socks5-in" 0 ;;
            7|ss2022)  add_proto_to_inbounds "shadowsocks-2022" 0 ;;
        esac
    done

    cat > "${conf_dir}/outbounds.json" << EOF
{
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    cat > "${conf_dir}/endpoints.json" << EOF
{
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "wireguard-out",
      "mtu": 1280,
      "address": [
        "172.16.0.2/32",
        "2606:4700:110:8dfe:d141:69bb:6b80:925/128"
      ],
      "private_key": "YFYOAdbw1bKTHlNNi+aEjBM3BO7unuFC5rOkMRAz9XY=",
      "peers": [
        {
          "address": "engage.cloudflareclient.com",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "reserved": [78, 135, 76]
        }
      ]
    }
  ]
}
EOF

    # 64M内存优化：默认不加载9个远程二进制规则集，仅在配置WARP分流时按需写入
    cat > "${conf_dir}/route.json" << EOF
{
  "route": {
    "rule_set": [],
    "rules": [],
    "final": "direct"
  }
}
EOF
}

# =========================
# 守护进程配置 (含64M内存 GOMEMLIMIT 限制与按需启停)
# =========================
main_systemd_services() {
    load_meta
    local argo_p="${VMESS_PORT:-8001}"

    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
Environment="GOGC=30"
Environment="GOMEMLIMIT=26MiB"
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/sing-box/sing-box run -C /etc/sing-box/conf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
Environment="GOGC=20"
Environment="GOMEMLIMIT=24MiB"
TimeoutStartSec=0
ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --url http://localhost:${argo_p} --no-autoupdate --edge-ip-version auto --protocol http2 > /etc/sing-box/argo.log 2>&1"
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    if [ -f /etc/centos-release ]; then
        bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range' 2>/dev/null || true
    fi

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box

    # 仅在启用了 vmess-ws 时启动 argo，节省64M小鸡内存
    if proto_exists "vmess-ws"; then
        systemctl enable argo >/dev/null 2>&1
        systemctl restart argo
    else
        systemctl stop argo >/dev/null 2>&1 || true
        systemctl disable argo >/dev/null 2>&1 || true
    fi
}

alpine_openrc_services() {
    load_meta
    local argo_p="${VMESS_PORT:-8001}"

    cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run
description="sing-box service"
export GOGC=30
export GOMEMLIMIT=26MiB
command="/etc/sing-box/sing-box"
command_args="run -C /etc/sing-box/conf"
command_background=true
pidfile="/var/run/sing-box.pid"
EOF

    cat > /etc/init.d/argo << EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel"
export GOGC=20
export GOMEMLIMIT=24MiB
command="/bin/sh"
command_args="-c '/etc/sing-box/argo tunnel --url http://localhost:${argo_p} --no-autoupdate --edge-ip-version auto --protocol http2 > /etc/sing-box/argo.log 2>&1'"
command_background=true
pidfile="/var/run/argo.pid"
EOF

    chmod +x /etc/init.d/sing-box /etc/init.d/argo
    rc-update add sing-box default >/dev/null 2>&1
    rc-service sing-box restart >/dev/null 2>&1

    if proto_exists "vmess-ws"; then
        rc-update add argo default >/dev/null 2>&1
        rc-service argo restart >/dev/null 2>&1
    else
        rc-service argo stop >/dev/null 2>&1 || true
        rc-update del argo default >/dev/null 2>&1 || true
    fi
}

# 当单独恢复/添加 vmess-ws 时同步开启 argo
sync_argo_service() {
    if proto_exists "vmess-ws"; then
        if command_exists systemctl; then
            [ ! -f /etc/systemd/system/argo.service ] && main_systemd_services
            systemctl enable argo >/dev/null 2>&1
            systemctl restart argo >/dev/null 2>&1
        elif command_exists rc-update; then
            [ ! -f /etc/init.d/argo ] && alpine_openrc_services
            rc-update add argo default >/dev/null 2>&1
            rc-service argo restart >/dev/null 2>&1
        fi
        get_quick_tunnel
    fi
}

# =========================
# 生成节点和订阅链接展示
# =========================
get_info() {
    yellow "\n正在检测 IP 与生成订阅信息，请稍等...\n"
    load_meta
    local server_ip
    server_ip=$(get_realip)
    local isp
    isp=$(get_isp_name)

    if proto_exists "vmess-ws"; then
        local argodomain=""
        for i in {1..5}; do
            if [ -f "${work_dir}/argo.log" ]; then
                argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -1)
            fi
            [ -n "$argodomain" ] && break
            purple "第 $i 次等待获取 Argo 临时域名中..."
            sleep 2
        done
        if [ -n "$argodomain" ]; then
            save_meta "ARGO_DOMAIN" "$argodomain"
            green "\nArgoDomain：${purple}${argodomain}${re}\n"
        fi
    fi

    rebuild_urls
    check_nodes
}

# =========================
# 低内存版 Nginx 订阅服务配置
# =========================
add_nginx_conf() {
    if ! command_exists nginx; then
        red "nginx未安装，跳过订阅服务配置"
        return 1
    fi
    load_meta
    local n_port="${NGINX_PORT:-8080}"
    local s_pass="${SUB_PASSWORD:-sub}"

    manage_service "nginx" "stop" >/dev/null 2>&1 || true
    pkill nginx >/dev/null 2>&1 || true

    mkdir -p /etc/nginx/conf.d
    [[ -f "/etc/nginx/conf.d/sing-box.conf" ]] && cp /etc/nginx/conf.d/sing-box.conf /etc/nginx/conf.d/sing-box.conf.bak.sb

    cat > /etc/nginx/conf.d/sing-box.conf << EOF
server {
    listen $n_port;
    listen [::]:$n_port;
    server_name _;

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    location = /$s_pass {
        alias /etc/sing-box/sub.txt;
        default_type 'text/plain; charset=utf-8';
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }

    location / { return 404; }
}
EOF

    if [ -f "/etc/nginx/nginx.conf" ] && [ ! -f "/etc/nginx/nginx.conf.bak.sb" ]; then
        cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.sb >/dev/null 2>&1
    fi

    # 针对 64M 内存优化 Nginx：仅开启 1 个 worker 进程，内存占用 < 2MB
    local nginx_user="www-data"
    id -u nginx >/dev/null 2>&1 && nginx_user="nginx"
    cat > /etc/nginx/nginx.conf << EOF
user $nginx_user;
worker_processes 1;
error_log /var/log/nginx/error.log crit;
pid /run/nginx.pid;

events {
    worker_connections 128;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    access_log    off;
    sendfile      on;
    keepalive_timeout 30;
    include /etc/nginx/conf.d/*.conf;
}
EOF

    if nginx -t >/dev/null 2>&1; then
        start_nginx >/dev/null 2>&1 || restart_nginx >/dev/null 2>&1
        green "Nginx 轻量级订阅服务已启动"
    else
        [[ -f "/etc/nginx/nginx.conf.bak.sb" ]] && cp "/etc/nginx/nginx.conf.bak.sb" /etc/nginx/nginx.conf >/dev/null 2>&1
        restart_nginx >/dev/null 2>&1
    fi
}

get_current_uuid() {
    load_meta
    if [ -n "$UUID" ]; then
        echo "$UUID"
        return
    fi
    local inbounds_file="${conf_dir}/inbounds.json"
    if [ -f "$inbounds_file" ]; then
        local u
        u=$(jq -r '.inbounds[] | (.users[0].uuid // .users[0].password // empty)' "$inbounds_file" 2>/dev/null | head -1)
        echo "$u"
    fi
}

# 创建本地持久快捷指令 (修复原版覆盖本地修改的问题)
create_shortcut() {
    local current_script
    current_script=$(readlink -f "$0" 2>/dev/null)
    if [ -f "$current_script" ]; then
        cp -f "$current_script" "$work_dir/sb.sh"
    else
        cat "$0" > "$work_dir/sb.sh" 2>/dev/null || true
    fi
    chmod +x "$work_dir/sb.sh"
    ln -sf "$work_dir/sb.sh" /usr/bin/sb
    [ -s /usr/bin/sb ] && green "\n快捷指令 sb 创建成功 (输入 sb 即可呼出本管理面板)\n"
}

change_hosts() {
    sh -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range' 2>/dev/null || true
    if [ ! -f "${work_dir}/hosts.bak" ] && [ -f /etc/hosts ]; then
        cp /etc/hosts "${work_dir}/hosts.bak"
    fi
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts 2>/dev/null || true
    sed -i '2s/.*/::1         localhost/' /etc/hosts 2>/dev/null || true
}

# =========================
# 功能5：彻底卸载并恢复初始状态
# =========================
perform_full_uninstall() {
    local remove_nginx_choice="$1"
    yellow "\n正在停止所有相关服务并清理守护进程..."

    if command_exists rc-service; then
        rc-service sing-box stop >/dev/null 2>&1 || true
        rc-service argo stop >/dev/null 2>&1 || true
        rc-update del sing-box default >/dev/null 2>&1 || true
        rc-update del argo default >/dev/null 2>&1 || true
        rm -f /etc/init.d/sing-box /etc/init.d/argo
    elif command_exists systemctl; then
        systemctl stop sing-box >/dev/null 2>&1 || true
        systemctl stop argo >/dev/null 2>&1 || true
        systemctl disable sing-box >/dev/null 2>&1 || true
        systemctl disable argo >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    pkill -9 -f "${work_dir}/sing-box" >/dev/null 2>&1 || true
    pkill -9 -f "${work_dir}/argo" >/dev/null 2>&1 || true

    yellow "正在清理防火墙放行规则及端口跳跃 NAT 规则..."
    clean_firewall_rules

    # 恢复 /etc/hosts
    if [ -f "${work_dir}/hosts.bak" ]; then
        cp -f "${work_dir}/hosts.bak" /etc/hosts >/dev/null 2>&1 || true
    fi

    # 恢复或卸载 Nginx
    rm -f /etc/nginx/conf.d/sing-box.conf /etc/nginx/conf.d/sing-box.conf.bak* 2>/dev/null || true
    if [ -f "/etc/nginx/nginx.conf.bak.sb" ]; then
        mv -f /etc/nginx/nginx.conf.bak.sb /etc/nginx/nginx.conf >/dev/null 2>&1 || true
    fi

    if [[ "$remove_nginx_choice" =~ ^[yY]$ ]]; then
        if command_exists rc-service; then
            rc-service nginx stop >/dev/null 2>&1 || true
            rc-update del nginx default >/dev/null 2>&1 || true
        elif command_exists systemctl; then
            systemctl stop nginx >/dev/null 2>&1 || true
            systemctl disable nginx >/dev/null 2>&1 || true
        fi
        manage_packages uninstall nginx
    else
        command_exists nginx && restart_nginx >/dev/null 2>&1 || true
    fi

    # 卸载并移除脚本创建的临时 Swap
    if [ -f "$swap_file" ]; then
        yellow "正在卸载并清理临时虚拟内存 ($swap_file)..."
        swapoff "$swap_file" >/dev/null 2>&1 || true
        sed -i "\|$swap_file|d" /etc/fstab 2>/dev/null || true
        rm -f "$swap_file" >/dev/null 2>&1 || true
    fi

    # 删除工作目录与快捷命令
    rm -rf "${work_dir}" >/dev/null 2>&1 || true
    rm -f /usr/bin/sb >/dev/null 2>&1 || true

    green "\nsing-box、Argo隧道、防火墙规则及配置文件已彻底卸载，系统已恢复初始状态！\n"
}

uninstall_singbox() {
    clear
    red "=== 彻底卸载 sing-box 并恢复初始状态 ==="
    echo ""
    yellow "此操作将彻底清除以下内容并还原系统初始状态："
    yellow " 1. 停止并删除 sing-box 及 argo 系统服务"
    yellow " 2. 清理脚本添加的所有防火墙端口规则与 NAT 端口跳跃规则"
    yellow " 3. 还原 /etc/nginx/nginx.conf 备份及 /etc/hosts 备份"
    yellow " 4. 清理脚本创建的临时 Swap 文件 (/swapfile_sb)"
    yellow " 5. 删除 /etc/sing-box 目录与 /usr/bin/sb 快捷指令"
    echo ""
    reading "确定要彻底卸载并恢复初始状态吗? (y/n): " choice
    case "${choice}" in
        y|Y)
            reading "是否同时卸载 Nginx 软件包？(输入 y 卸载，直接回车仅恢复Nginx原配置): " ng_choice
            perform_full_uninstall "${ng_choice:-n}"
            exit 0
            ;;
        *)
            purple "已取消卸载操作\n"
            ;;
    esac
}

# 静默安装与静默卸载
auto_install() {
    if [ "$(check_service_raw sing-box)" == "running" ]; then
        yellow "sing-box 已经安装并正在运行，跳过安装流程。"
        exit 0
    fi
    green "开始无交互式安装 sing-box (64M低内存优化版)..."
    SELECTED_PROTOS="${PROTOS:-1 2 3 4}"
    manage_packages install nginx jq tar openssl lsof coreutils curl
    install_singbox
    if command_exists systemctl; then
        main_systemd_services
    elif command_exists rc-update; then
        alpine_openrc_services
        change_hosts
    else
        red "不支持的 init 系统，安装中止。"; exit 1
    fi
    sleep 3
    get_info
    add_nginx_conf
    create_shortcut
    green "\nsing-box 安装完成\n"
}

auto_uninstall() {
    green "开始无交互式彻底卸载 sing-box..."
    perform_full_uninstall "y"
}

# =========================
# 功能3：重新设置入站 IP (节点入站连接IP + 服务端监听IP)
# =========================
reset_inbound_ip_menu() {
    if [ "$(check_service_raw sing-box)" == "not installed" ]; then
        yellow "sing-box 尚未安装！"; sleep 1; return
    fi
    load_meta
    local cur_node_ip
    cur_node_ip=$(get_realip)
    local cur_listen_ip="${LISTEN_IP:-::}"

    clear
    green "=== 重新设置入站 IP / 监听地址 ==="
    echo ""
    echo -e " 当前节点连接 IP/域名 : ${purple}${cur_node_ip}${re}"
    echo -e " 当前服务端监听地址   : ${skyblue}${cur_listen_ip}${re}"
    echo ""
    green "1. 自定义设置节点入站 IP 或域名 (用于NAT小鸡/DDNS/指定公网IP)"
    skyblue "--------------------------------------------------------"
    green "2. 自动重新检测并设置为公网 IPv4"
    skyblue "--------------------------------------------------------"
    green "3. 自动重新检测并设置为公网 IPv6"
    skyblue "--------------------------------------------------------"
    green "4. 修改服务端 inbounds.json 监听地址 (:: 双栈 / 0.0.0.0 / 指定网卡IP)"
    skyblue "--------------------------------------------------------"
    purple "0. 返回上一级菜单"
    skyblue "--------------------------------------------------------"
    reading "请输入选择: " ip_choice

    case "$ip_choice" in
        1)
            echo ""
            yellow "提示: 若输入 IPv6 地址请加上中括号，例如 [2001:db8::1]；IPv4 或域名直接输入即可。"
            reading "请输入新的入站连接 IP 或域名: " custom_ip
            if [ -z "$custom_ip" ]; then
                red "输入不能为空！"; sleep 1; return
            fi
            # 若输入的是裸IPv6则自动补齐方括号
            if [[ "$custom_ip" == *":"* ]] && [[ "$custom_ip" != "["* ]]; then
                custom_ip="[${custom_ip}]"
            fi
            save_meta "CUSTOM_NODE_IP" "$custom_ip"
            rebuild_urls
            green "\n节点入站 IP/域名已成功重置为: ${purple}${custom_ip}${re}\n"
            check_nodes
            ;;
        2)
            local new_ipv4
            new_ipv4=$(curl -4 -sm 3 ip.sb || curl -4 -sm 3 api.ipify.org)
            if ! printf '%s' "$new_ipv4" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
                red "\n错误: 未能检测到有效的公网 IPv4 地址\n"; sleep 2; return
            fi
            save_meta "CUSTOM_NODE_IP" "$new_ipv4"
            rebuild_urls
            green "\n已将节点入站 IP 重置为 IPv4: ${purple}${new_ipv4}${re}\n"
            check_nodes
            ;;
        3)
            local new_ipv6
            new_ipv6=$(curl -6 -sm 3 ip.sb || curl -6 -sm 3 api64.ipify.org)
            if ! printf '%s' "$new_ipv6" | grep -Eq '^[0-9a-fA-F:]+$'; then
                red "\n错误: 当前服务器没有检测到可用的公网 IPv6\n"; sleep 2; return
            fi
            save_meta "CUSTOM_NODE_IP" "[${new_ipv6}]"
            rebuild_urls
            green "\n已将节点入站 IP 重置为 IPv6: ${purple}[${new_ipv6}]${re}\n"
            check_nodes
            ;;
        4)
            echo ""
            green "请选择服务端入站监听地址 (listen):"
            green "  1. ::        (同时监听 IPv4 和 IPv6，默认推荐)"
            green "  2. 0.0.0.0   (仅监听 IPv4，适合禁用IPv6的64M小鸡)"
            green "  3. 自定义网卡监听 IP"
            reading "请输入选择 (默认1): " l_choice
            local new_listen="::"
            case "$l_choice" in
                2) new_listen="0.0.0.0" ;;
                3)
                    reading "请输入服务端要绑定的网卡 IP: " input_lip
                    [ -n "$input_lip" ] && new_listen="$input_lip"
                    ;;
                *) new_listen="::" ;;
            esac
            save_meta "LISTEN_IP" "$new_listen"
            local inbounds_file="${conf_dir}/inbounds.json"
            jq --arg lip "$new_listen" '(.inbounds[].listen) = $lip' \
                "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
            restart_singbox
            green "\n服务端入站监听地址已修改为: ${purple}${new_listen}${re}，并已重启 sing-box 生效！\n"
            ;;
        0) return ;;
        *) red "无效的选项！" ;;
    esac
}

# =========================
# 修改节点配置菜单
# =========================
change_config() {
    if [ "$(check_service_raw sing-box)" == "not installed" ]; then
        yellow "sing-box 尚未安装！"; sleep 1; return
    fi

    clear; echo ""
    green "=== 修改节点配置 ===\n"
    green "sing-box当前状态: $(check_singbox)\n"
    green "1. 修改各协议监听端口"
    skyblue "------------"
    green "2. 修改全局 UUID / 密码"
    skyblue "------------"
    green "3. 修改 Reality 伪装域名 (SNI)"
    skyblue "------------"
    green "4. 添加 hysteria2 端口跳跃"
    skyblue "------------"
    green "5. 删除 hysteria2 端口跳跃"
    skyblue "------------"
    green "6. 修改 vmess-argo 优选域名/IP"
    skyblue "------------"
    green "7. 重新设置入站 IP (自定义IP/域名/切换IPv4与IPv6/修改监听地址)"
    skyblue "------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice
    local inbounds_file="${conf_dir}/inbounds.json"
    load_meta

    case "${choice}" in
        1)
            echo ""
            green "1. 修改 vless-reality 端口"
            green "2. 修改 hysteria2 端口"
            green "3. 修改 tuic 端口"
            green "4. 修改 vmess-argo 端口"
            green "5. 修改 AnyTLS 端口"
            green "6. 修改 Socks5 端口"
            green "7. 修改 Shadowsocks-2022 端口"
            purple "0. 返回上一级"
            reading "请输入选择: " p_choice
            local target_tag="" proto_type="tcp" meta_key=""
            case "$p_choice" in
                1) target_tag="vless-reality"; proto_type="tcp"; meta_key="VLESS_PORT" ;;
                2) target_tag="hysteria2";     proto_type="udp"; meta_key="HY2_PORT" ;;
                3) target_tag="tuic";          proto_type="udp"; meta_key="TUIC_PORT" ;;
                4) target_tag="vmess-ws";      proto_type="tcp"; meta_key="VMESS_PORT" ;;
                5) target_tag="anytls";        proto_type="tcp"; meta_key="ANYTLS_PORT" ;;
                6) target_tag="socks5-in";     proto_type="both"; meta_key="SOCKS_PORT" ;;
                7) target_tag="shadowsocks-2022"; proto_type="both"; meta_key="SS_PORT" ;;
                0) change_config; return ;;
                *) red "无效选择"; return ;;
            esac

            if ! proto_exists "$target_tag"; then
                red "\n当前未启用 [$target_tag] 协议，请先在「协议管理」中添加或恢复该协议！\n"
                return
            fi

            reading "\n请输入新的端口 (回车随机生成): " new_port
            [ -z "$new_port" ] && new_port=$(shuf -i 10000-60000 -n 1)
            jq --arg tag "$target_tag" --argjson port "$new_port" \
               '(.inbounds[] | select(.tag == $tag).listen_port) = $port' \
               "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
            save_meta "$meta_key" "$new_port"

            if [ "$proto_type" == "both" ]; then
                allow_port "${new_port}/tcp" "${new_port}/udp" >/dev/null 2>&1
            else
                allow_port "${new_port}/${proto_type}" >/dev/null 2>&1
            fi

            if [ "$target_tag" == "vmess-ws" ]; then
                if command_exists rc-service && [ -f /etc/init.d/argo ]; then
                    sed -i "s/localhost:[0-9]\{1,\}/localhost:${new_port}/g" /etc/init.d/argo
                elif [ -f /etc/systemd/system/argo.service ]; then
                    sed -i "s/localhost:[0-9]\{1,\}/localhost:${new_port}/g" /etc/systemd/system/argo.service
                fi
                get_quick_tunnel
            fi

            restart_singbox
            rebuild_urls
            green "\n[${target_tag}] 端口已修改为：${purple}${new_port}${re}\n"
            ;;
        2)
            reading "\n请输入新的UUID (直接回车随机生成): " new_uuid
            [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
            save_meta "UUID" "$new_uuid"
            jq --arg uuid "$new_uuid" \
               '(.inbounds[] | select(.users != null) | .users[] | select(.uuid != null).uuid) = $uuid |
                (.inbounds[] | select(.tag != "socks5-in" and .users != null) | .users[] | select(.password != null).password) = $uuid' \
               "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
            restart_singbox
            rebuild_urls
            green "\nUUID已修改为：${purple}${new_uuid}${re}\n"
            ;;
        3)
            if ! proto_exists "vless-reality"; then
                red "\nvless-reality 协议当前未启用！\n"; return
            fi
            green "\n1. www.joom.com\n2. www.stengg.com\n3. www.wedgehr.com\n4. www.cerebrium.ai\n5. www.nazhumi.com\n"
            reading "\n请输入新的Reality伪装域名 (可自定义输入,回车默认1): " new_sni
            case "$new_sni" in
                ""|"1") new_sni="www.joom.com" ;;
                "2") new_sni="www.stengg.com" ;;
                "3") new_sni="www.wedgehr.com" ;;
                "4") new_sni="www.cerebrium.ai" ;;
                "5") new_sni="www.nazhumi.com" ;;
            esac
            save_meta "REALITY_SNI" "$new_sni"
            jq --arg sni "$new_sni" \
               '(.inbounds[] | select(.tag == "vless-reality") | .tls.server_name) = $sni |
                (.inbounds[] | select(.tag == "vless-reality") | .tls.reality.handshake.server) = $sni' \
               "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
            restart_singbox
            rebuild_urls
            green "\nReality SNI 已修改为：${purple}${new_sni}${re}\n"
            ;;
        4)
            if ! proto_exists "hysteria2"; then
                red "\nhysteria2 协议当前未启用！\n"; return
            fi
            reading "请输入跳跃起始端口 (回车默认随机): " min_port
            [ -z "$min_port" ] && min_port=$(shuf -i 50000-64000 -n 1)
            reading "请输入跳跃结束端口 (回车默认 $((min_port + 100))): " max_port
            [ -z "$max_port" ] && max_port=$((min_port + 100))
            local listen_port
            listen_port=$(jq -r '.inbounds[] | select(.tag == "hysteria2").listen_port' "$inbounds_file")

            # 先清理旧规则
            if [ -n "$HY2_MPORT_MIN" ] && [ -n "$HY2_MPORT_MAX" ]; then
                command_exists iptables && iptables -t nat -D PREROUTING -p udp --dport "${HY2_MPORT_MIN}:${HY2_MPORT_MAX}" -j DNAT --to-destination ":${listen_port}" >/dev/null 2>&1 || true
                command_exists ip6tables && ip6tables -t nat -D PREROUTING -p udp --dport "${HY2_MPORT_MIN}:${HY2_MPORT_MAX}" -j DNAT --to-destination ":${listen_port}" >/dev/null 2>&1 || true
            fi

            command_exists iptables && iptables -t nat -A PREROUTING -p udp --dport "${min_port}:${max_port}" -j DNAT --to-destination ":${listen_port}" >/dev/null 2>&1
            command_exists ip6tables && ip6tables -t nat -A PREROUTING -p udp --dport "${min_port}:${max_port}" -j DNAT --to-destination ":${listen_port}" >/dev/null 2>&1

            save_meta "HY2_MPORT_MIN" "$min_port"
            save_meta "HY2_MPORT_MAX" "$max_port"
            rebuild_urls
            green "\nhysteria2 端口跳跃已开启：${purple}${min_port}-${max_port}${re}\n"
            ;;
        5)
            load_meta
            local listen_port="${HY2_PORT}"
            if [ -n "$HY2_MPORT_MIN" ] && [ -n "$HY2_MPORT_MAX" ]; then
                command_exists iptables && iptables -t nat -D PREROUTING -p udp --dport "${HY2_MPORT_MIN}:${HY2_MPORT_MAX}" -j DNAT --to-destination ":${listen_port}" >/dev/null 2>&1 || true
                command_exists ip6tables && ip6tables -t nat -D PREROUTING -p udp --dport "${HY2_MPORT_MIN}:${HY2_MPORT_MAX}" -j DNAT --to-destination ":${listen_port}" >/dev/null 2>&1 || true
            fi
            save_meta "HY2_MPORT_MIN" ""
            save_meta "HY2_MPORT_MAX" ""
            rebuild_urls
            green "\nhysteria2 端口跳跃已删除\n"
            ;;
        6) change_cfip ;;
        7) reset_inbound_ip_menu ;;
        0) return ;;
        *) red "无效的选项！\n" ;;
    esac
}

# =========================
# 功能1/2/4：全协议管理中心 (支持全部7种协议的添加、删除、恢复)
# =========================
show_all_proto_status() {
    local inbounds_file="${conf_dir}/inbounds.json"
    echo ""
    green "=== 当前协议节点启用状态 ==="
    local protos=("vless-reality:VLESS-Reality" "vmess-ws:VMess-WS(Argo)" "hysteria2:Hysteria2" "tuic:TUIC-v5" "anytls:AnyTLS" "socks5-in:Socks5" "shadowsocks-2022:Shadowsocks-2022")
    local idx=1
    for item in "${protos[@]}"; do
        local tag="${item%%:*}"
        local name="${item##*:}"
        if proto_exists "$tag"; then
            local p
            p=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .listen_port' "$inbounds_file")
            printf " %d. %-18s : ${green}已启用${re} (端口: ${skyblue}%s${re})\n" "$idx" "$name" "$p"
        else
            printf " %d. %-18s : ${yellow}未启用 / 已删除${re}\n" "$idx" "$name"
        fi
        idx=$((idx + 1))
    done
    echo ""
}

manage_protocols() {
    if [ "$(check_service_raw sing-box)" == "not installed" ]; then
        yellow "sing-box 尚未安装！请先安装 sing-box。"; sleep 2; return
    fi

    clear
    green "=== 协议节点管理中心 (添加 / 恢复 / 删除指定协议) ==="
    show_all_proto_status

    green "1. 恢复 / 添加指定协议节点 (支持7种协议任选)"
    skyblue "------------------------------------------------"
    red   "2. 删除指定协议节点 (支持删除任意已启用协议，释放端口与内存)"
    skyblue "------------------------------------------------"
    green "3. 一键恢复默认四合一协议 (vless + vmess + hy2 + tuic)"
    skyblue "------------------------------------------------"
    green "4. 重新自定义保留哪些协议 (重新勾选协议组合)"
    skyblue "------------------------------------------------"
    green "5. 重新设置入站 IP / 监听地址"
    skyblue "------------------------------------------------"
    purple "0. 返回主菜单"
    skyblue "------------------------------------------------"
    reading "请输入选择: " proto_choice
    echo ""

    case "${proto_choice}" in
        1)
            green "请选择要【恢复 / 添加】的协议 (可输入多个编号用空格隔开，如: 1 3):"
            echo "  1. vless-reality"
            echo "  2. vmess-ws (Argo)"
            echo "  3. hysteria2"
            echo "  4. tuic v5"
            echo "  5. AnyTLS"
            echo "  6. Socks5"
            echo "  7. Shadowsocks-2022"
            reading "请输入协议编号: " add_inputs
            [ -z "$add_inputs" ] && return
            local count_inputs
            count_inputs=$(echo "$add_inputs" | wc -w)
            local is_inter=1
            [ "$count_inputs" -gt 1 ] && is_inter=0

            for num in $(echo "$add_inputs" | tr ',' ' '); do
                case "$num" in
                    1) add_proto_to_inbounds "vless-reality" "$is_inter" ;;
                    2) add_proto_to_inbounds "vmess-ws" "$is_inter" ;;
                    3) add_proto_to_inbounds "hysteria2" "$is_inter" ;;
                    4) add_proto_to_inbounds "tuic" "$is_inter" ;;
                    5) add_proto_to_inbounds "anytls" "$is_inter" ;;
                    6) add_proto_to_inbounds "socks5-in" "$is_inter" ;;
                    7) add_proto_to_inbounds "shadowsocks-2022" "$is_inter" ;;
                    *) red "忽略无效编号: $num" ;;
                esac
            done
            restart_singbox
            rebuild_urls
            green "\n指定协议已恢复/添加并更新订阅！\n"
            ;;
        2)
            red "请选择要【删除】的协议 (可输入多个编号用空格隔开，如: 2 4):"
            echo "  1. vless-reality"
            echo "  2. vmess-ws (Argo) [删除后将自动停止Argo进程节省内存]"
            echo "  3. hysteria2"
            echo "  4. tuic v5"
            echo "  5. AnyTLS"
            echo "  6. Socks5"
            echo "  7. Shadowsocks-2022"
            reading "请输入要删除的协议编号: " del_inputs
            [ -z "$del_inputs" ] && return
            for num in $(echo "$del_inputs" | tr ',' ' '); do
                case "$num" in
                    1) remove_proto_from_inbounds "vless-reality" && green "已删除 vless-reality" ;;
                    2) remove_proto_from_inbounds "vmess-ws" && green "已删除 vmess-ws" ;;
                    3) remove_proto_from_inbounds "hysteria2" && green "已删除 hysteria2" ;;
                    4) remove_proto_from_inbounds "tuic" && green "已删除 tuic" ;;
                    5) remove_proto_from_inbounds "anytls" && green "已删除 AnyTLS" ;;
                    6) remove_proto_from_inbounds "socks5-in" && green "已删除 Socks5" ;;
                    7) remove_proto_from_inbounds "shadowsocks-2022" && green "已删除 Shadowsocks-2022" ;;
                    *) red "忽略无效编号: $num" ;;
                esac
            done
            restart_singbox
            rebuild_urls
            green "\n所选协议节点已删除，订阅链接已同步更新！\n"
            ;;
        3)
            yellow "正在恢复默认四合一协议 (vless-reality / vmess-ws / hysteria2 / tuic)..."
            add_proto_to_inbounds "vless-reality" 0
            add_proto_to_inbounds "vmess-ws" 0
            add_proto_to_inbounds "hysteria2" 0
            add_proto_to_inbounds "tuic" 0
            restart_singbox
            rebuild_urls
            green "\n默认四合一协议已全部恢复并更新订阅！\n"
            ;;
        4)
            SELECTED_PROTOS=""
            select_install_protocols
            echo '{"inbounds": []}' > "${conf_dir}/inbounds.json"
            for item in $SELECTED_PROTOS; do
                case "$item" in
                    1) add_proto_to_inbounds "vless-reality" 0 ;;
                    2) add_proto_to_inbounds "vmess-ws" 0 ;;
                    3) add_proto_to_inbounds "hysteria2" 0 ;;
                    4) add_proto_to_inbounds "tuic" 0 ;;
                    5) add_proto_to_inbounds "anytls" 0 ;;
                    6) add_proto_to_inbounds "socks5-in" 0 ;;
                    7) add_proto_to_inbounds "shadowsocks-2022" 0 ;;
                esac
            done
            if ! proto_exists "vmess-ws"; then
                stop_argo
            fi
            restart_singbox
            rebuild_urls
            green "\n已按新选择重新生成协议节点！\n"
            ;;
        5)
            reset_inbound_ip_menu
            ;;
        0) return ;;
        *) red "无效的选项！" ;;
    esac
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回协议管理菜单...\033[0m\n'
    manage_protocols
}

# =========================
# 订阅管理、服务管理、Argo管理、WARP分流
# =========================
disable_open_sub() {
    if [ "$(check_service_raw sing-box)" == "not installed" ]; then
        yellow "sing-box 尚未安装！"; sleep 1; return
    fi
    load_meta
    clear; echo ""
    green "=== 管理节点订阅 ===\n"
    green "1. 关闭节点订阅 (停止Nginx节省内存)"
    skyblue "------------"
    green "2. 开启/刷新节点订阅"
    skyblue "------------"
    green "3. 更换订阅端口"
    skyblue "------------"
    green "4. 重启订阅服务"
    skyblue "------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1)
            manage_service "nginx" "stop"
            green "\n已关闭节点订阅服务\n"
            ;;
        2)
            local server_ip
            server_ip=$(get_realip)
            local password
            password=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 24)
            save_meta "SUB_PASSWORD" "$password"
            add_nginx_conf
            local sub_port="${NGINX_PORT:-8080}"
            green "\n已开启节点订阅\n新的节点订阅链接：http://${server_ip}:${sub_port}/${password}\n"
            ;;
        3)
            reading "请输入新的订阅端口 (1-65535, 直接回车随机生成): " sub_port
            [ -z "$sub_port" ] && sub_port=$(shuf -i 10000-60000 -n 1)
            save_meta "NGINX_PORT" "$sub_port"
            allow_port "${sub_port}/tcp" >/dev/null 2>&1
            add_nginx_conf
            local server_ip
            server_ip=$(get_realip)
            green "\n订阅端口更换成功\n新的订阅链接为：${purple}http://${server_ip}:${sub_port}/${SUB_PASSWORD}${re}\n"
            ;;
        4) restart_nginx && green "\nNginx 订阅服务已重启\n" ;;
        0) return ;;
        *) red "无效的选项！" ;;
    esac
}

manage_singbox() {
    clear; echo ""
    green "=== sing-box 管理 ===\n"
    green "sing-box当前状态: $(check_singbox)\n"
    green "1. 启动 sing-box 服务"
    skyblue "-------------------"
    green "2. 停止 sing-box 服务"
    skyblue "-------------------"
    green "3. 重启 sing-box 服务"
    skyblue "-------------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "\n请输入选择: " choice
    case "${choice}" in
        1) start_singbox && green "sing-box 已启动" ;;
        2) stop_singbox && yellow "sing-box 已停止" ;;
        3) restart_singbox && green "sing-box 已重启" ;;
        0) return ;;
        *) red "无效的选项！" ;;
    esac
}

manage_argo() {
    clear; echo ""
    green "=== Argo 隧道管理 ===\n"
    green "Argo当前状态: $(check_argo)\n"
    green "1. 启动 Argo 服务"
    skyblue "------------"
    green "2. 停止 Argo 服务"
    skyblue "------------"
    green "3. 重启并重新获取 Argo 临时域名"
    skyblue "------------"
    green "4. 添加 Argo 固定隧道"
    skyblue "----------------"
    green "5. 切换回 Argo 临时隧道"
    skyblue "------------------"
    purple "0. 返回主菜单"
    skyblue "-----------"
    reading "\n请输入选择: " choice
    load_meta
    local argo_p="${VMESS_PORT:-8001}"

    case "${choice}" in
        1) start_argo && green "Argo 已启动" ;;
        2) stop_argo && yellow "Argo 已停止" ;;
        3)
            get_quick_tunnel
            rebuild_urls
            ;;
        4)
            clear
            yellow "\n固定隧道可为 json 或 token，固定隧道本地端口为 ${argo_p}\n"
            reading "请输入你的 Argo 固定域名: " argo_domain
            [ -z "$argo_domain" ] && { red "域名不能为空"; return; }
            save_meta "ARGO_DOMAIN" "$argo_domain"
            reading "请输入你的 Argo 密钥 (token 或 json): " argo_auth
            if [[ "$argo_auth" =~ TunnelSecret ]]; then
                echo "$argo_auth" > "${work_dir}/tunnel.json"
                cat > "${work_dir}/tunnel.yml" << EOF
tunnel: $(cut -d\" -f12 <<< "$argo_auth")
credentials-file: ${work_dir}/tunnel.json
protocol: http2

ingress:
  - hostname: $argo_domain
    service: http://localhost:${argo_p}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
                if command_exists rc-service; then
                    sed -i '/^command_args=/c\command_args="-c '\''/etc/sing-box/argo tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run > /etc/sing-box/argo.log 2>&1'\''"' /etc/init.d/argo
                else
                    sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run > /etc/sing-box/argo.log 2>&1"' /etc/systemd/system/argo.service
                fi
                restart_argo; sleep 2; rebuild_urls
                green "\nArgo 固定隧道已配置完成！\n"
            elif [[ "$argo_auth" =~ ^[A-Z0-9a-z=_-]{100,300}$ ]]; then
                if command_exists rc-service; then
                    sed -i "/^command_args=/c\command_args=\"-c '/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token $argo_auth > /etc/sing-box/argo.log 2>&1'\"" /etc/init.d/argo
                else
                    sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token '"$argo_auth"' > /etc/sing-box/argo.log 2>&1"' /etc/systemd/system/argo.service
                fi
                restart_argo; sleep 2; rebuild_urls
                green "\nArgo Token 固定隧道已配置完成！\n"
            else
                red "输入的密钥格式不匹配！"
            fi
            ;;
        5)
            if command_exists rc-service; then alpine_openrc_services
            else main_systemd_services; fi
            get_quick_tunnel
            rebuild_urls
            ;;
        0) return ;;
        *) red "无效的选项！" ;;
    esac
}

get_quick_tunnel() {
    restart_argo
    yellow "获取临时 Argo 域名中，请稍等...\n"
    sleep 3
    local get_argodomain=""
    if [ -f "${work_dir}/argo.log" ]; then
        for i in {1..6}; do
            get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -1)
            [ -n "$get_argodomain" ] && break
            purple "第 $i 次尝试获取 ArgoDomain 中..."
            sleep 2
        done
    fi
    if [ -n "$get_argodomain" ]; then
        save_meta "ARGO_DOMAIN" "$get_argodomain"
        green "ArgoDomain：${purple}${get_argodomain}${re}\n"
    else
        yellow "暂未从日志中解析到临时域名，请稍后在 Argo 菜单中重试。\n"
    fi
}

change_argo_domain() {
    rebuild_urls
}

check_nodes() {
    if [ ! -f "${client_dir}" ]; then
        red "节点信息文件不存在，请先安装 sing-box"; return 1
    fi
    load_meta
    local server_ip
    server_ip=$(get_realip)
    local sub_port="${NGINX_PORT:-8080}"
    local lujing="${SUB_PASSWORD:-sub}"
    local base64_url="http://${server_ip}:${sub_port}/${lujing}"

    clear; echo ""
    green "=== 当前已生成的节点信息 (入站IP: ${server_ip}) ===\n"

    if [ ! -s "${client_dir}" ]; then
        yellow "当前没有任何启用的协议节点，请前往「9. 协议管理」添加或恢复协议。\n"
        return 0
    fi

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo -e "${purple}${line}${re}\n"
    done < "${client_dir}"

    yellow "温馨提醒: 如果 hysteria2 或 tuic 不通，请将客户端「跳过证书验证」设为 true\n"
    green "=== 订阅链接 ===\n"
    green "V2rayN / Shadowrocket / Nekobox / Karing 通用订阅链接:\n${purple}${base64_url}${re}\n"
    [ -x "${work_dir}/qrencode" ] && "${work_dir}/qrencode" "${base64_url}"
    yellow "\n=========================================================================================="
    green "\nClash / Mihomo 订阅链接:\n${purple}https://sublink.eooce.com/clash?config=${base64_url}${re}\n"
    yellow "=========================================================================================="
    green "\nSing-box 订阅链接:\n${purple}https://sublink.eooce.com/singbox?config=${base64_url}${re}\n"
    yellow "==========================================================================================\n"
}

change_cfip() {
    clear
    yellow "修改 vmess-argo 优选域名/IP\n"
    green "1: cf.090227.xyz  2: cf.877774.xyz  3: cf.877771.xyz  4: cdns.doon.eu.org  5: cf.zhetengsha.eu.org  6: time.is\n"
    reading "请输入优选选项(1-6) 或 自定义输入 域名:端口 (回车默认1): " cfip_input
    local cfip cfport
    case "$cfip_input" in
        ""|"1") cfip="cf.090227.xyz";       cfport="443" ;;
        "2")    cfip="cf.877774.xyz";       cfport="443" ;;
        "3")    cfip="cf.877771.xyz";       cfport="443" ;;
        "4")    cfip="cdns.doon.eu.org";    cfport="443" ;;
        "5")    cfip="cf.zhetengsha.eu.org"; cfport="443" ;;
        "6")    cfip="time.is";             cfport="443" ;;
        *)
            if [[ "$cfip_input" =~ : ]]; then
                cfip="${cfip_input%%:*}"
                cfport="${cfip_input##*:}"
            else
                cfip="$cfip_input"; cfport="443"
            fi
            ;;
    esac
    save_meta "CFIP_SAVED" "$cfip"
    save_meta "CFPORT_SAVED" "$cfport"
    rebuild_urls
    green "\nvmess 节点优选地址已更新为：${purple}${cfip}:${cfport}${re}\n"
}

# =========================
# WARP 与分流管理 (按需加载规则集，节省内存)
# =========================
get_rule_url() {
    case "$1" in
        gemini)   echo "https://main.ssss.nyc.mn/gemini.srs" ;;
        claude)   echo "https://main.ssss.nyc.mn/claude.srs" ;;
        openai)   echo "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/openai.srs" ;;
        tiktok)   echo "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/tiktok.srs" ;;
        twitter)  echo "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/twitter.srs" ;;
        google)   echo "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/google.srs" ;;
        telegram) echo "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/telegram.srs" ;;
        youtube)  echo "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/youtube.srs" ;;
        netflix)  echo "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/netflix.srs" ;;
    esac
}

warp_manage() {
    if [ "$(check_service_raw sing-box)" == "not installed" ]; then
        yellow "sing-box 尚未安装！"; sleep 1; return
    fi
    route_file="${conf_dir}/route.json"
    outbound_file="${conf_dir}/outbounds.json"

    clear; echo ""
    green "=== WARP / 代理分流管理 (按需加载规则节省内存) ===\n"
    green "当前已启用的分流规则集:"
    jq -r '.route.rules[]? | select(.rule_set != null) | .rule_set[]?' "$route_file" 2>/dev/null | sort -u | while read -r tag; do
        [ -n "$tag" ] && echo -e " - ${skyblue}$tag${re}"
    done
    echo ""
    green "1. 添加分流服务 (默认走WARP)"
    red   "2. 删除分流服务"
    green "3. 恢复默认直连出站 (清空分流规则释放内存)"
    purple "0. 返回主菜单"
    reading "请输入选择: " choice
    case "${choice}" in
        1)
            clear
            green "选择要分流的服务:\n1. OpenAI  2. Claude  3. Gemini  4. Google  5. Tiktok  6. Twitter  7. YouTube  8. Netflix  9. Telegram\n0. 返回"
            reading "请输入编号: " r_choice
            local r_tag=""
            case "$r_choice" in
                1) r_tag="openai" ;; 2) r_tag="claude" ;; 3) r_tag="gemini" ;;
                4) r_tag="google" ;; 5) r_tag="tiktok" ;; 6) r_tag="twitter" ;;
                7) r_tag="youtube" ;; 8) r_tag="netflix" ;; 9) r_tag="telegram" ;;
                *) return ;;
            esac
            local r_url
            r_url=$(get_rule_url "$r_tag")
            # 按需添加 rule_set 与 rule
            jq --arg tag "$r_tag" --arg url "$r_url" '
                if ([.route.rule_set[]? | select(.tag == $tag)] | length) == 0 then
                    .route.rule_set += [{"tag": $tag, "type": "remote", "format": "binary", "url": $url, "download_detour": "direct"}]
                else . end |
                if ([.route.rules[]? | select(.outbound == "wireguard-out")] | length) == 0 then
                    .route.rules += [{"rule_set": [$tag], "outbound": "wireguard-out"}]
                else
                    (.route.rules[] | select(.outbound == "wireguard-out").rule_set) |= (. + [$tag] | unique)
                end
            ' "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"
            restart_singbox
            green "\n已启用 ${r_tag} 分流！\n"; sleep 1; warp_manage
            ;;
        2)
            reading "请输入要删除的规则名称 (如 openai): " del_tag
            [ -z "$del_tag" ] && return
            jq --arg tag "$del_tag" '
                del(.route.rule_set[]? | select(.tag == $tag)) |
                del(.route.rules[]? | select(.rule_set != null) | .rule_set[] | select(. == $tag)) |
                .route.rules = [.route.rules[]? | select(.rule_set != null and (.rule_set | length) > 0)]
            ' "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"
            restart_singbox
            green "\n已删除 ${del_tag} 分流规则并释放内存！\n"; sleep 1; warp_manage
            ;;
        3)
            cat > "${route_file}" << 'EOF'
{
  "route": {
    "rule_set": [],
    "rules": [],
    "final": "direct"
  }
}
EOF
            restart_singbox
            green "\n已清空所有远程规则集并恢复服务器直连出站！\n"; sleep 1
            ;;
        0) return ;;
    esac
}

# =========================
# 主菜单
# =========================
menu() {
    singbox_status=$(check_singbox 2>/dev/null)
    nginx_status=$(check_nginx 2>/dev/null)
    argo_status=$(check_argo 2>/dev/null)

    clear; echo ""
    purple "=== sing-box 多协议定制管理面板 (64M低内存稳定版) ==="
    echo ""
    purple "--- Argo 状态: ${argo_status}"
    purple "-- Nginx 状态: ${nginx_status}"
    purple "sing-box 状态: ${singbox_status}"
    echo ""
    green "1. 安装 sing-box (支持自定义选择生成哪些协议)"
    red   "2. 彻底卸载 sing-box 并恢复初始状态"
    echo "=========================================="
    green "3. sing-box 服务管理"
    green "4. Argo 隧道管理"
    echo "=========================================="
    green "5. 查看节点信息与订阅链接"
    green "6. 修改节点配置 (端口/UUID/SNI/端口跳跃)"
    green "7. 重新设置入站 IP (连接IP/域名/IPv4/IPv6/监听网卡)"
    green "8. 管理节点订阅 (开启/关闭/换端口)"
    echo "=========================================="
    green "9. 协议管理中心 (删除指定协议 / 恢复或添加指定协议)"
    green "10. WARP 分流管理"
    echo "=========================================="
    red   "0. 退出脚本"
    echo "=========================================="
}

trap 'red "\n已退出脚本"; exit 0' INT

case "$1" in
    -i | --install)
        auto_install
        exit 0
        ;;
    -u | --uninstall)
        auto_uninstall
        exit 0
        ;;
    -c | --check)
        check_nodes
        exit 0
        ;;
    -r | --restart)
        get_quick_tunnel
        rebuild_urls
        exit 0
        ;;
    -h | --help)
        echo ""
        green "用法: sb [参数]"
        green "  -i, --install     无交互安装 sing-box (可通过 PROTOS='1 3' 指定协议)"
        green "  -c, --check       查看节点信息和订阅链接"
        green "  -r, --restart     重新获取 Argo 临时隧道并更新订阅"
        green "  -u, --uninstall   无交互彻底卸载并恢复初始状态"
        green "  不带参数          进入交互式管理主菜单"
        echo ""
        exit 0
        ;;
    "")
        while true; do
            menu
            reading "请输入选择 (0-10): " choice
            echo ""
            need_pause=true
            case "${choice}" in
                1)
                    if [ "$(check_service_raw sing-box)" == "running" ]; then
                        yellow "sing-box 已经安装！如需增删协议请选「9. 协议管理中心」，重装请先选「2. 彻底卸载」。\n"
                    else
                        SELECTED_PROTOS=""
                        select_install_protocols
                        manage_packages install nginx jq tar openssl lsof coreutils curl
                        install_singbox
                        if command_exists systemctl; then
                            main_systemd_services
                        elif command_exists rc-update; then
                            alpine_openrc_services
                            change_hosts
                        else
                            red "不支持的 init 系统"; exit 1
                        fi
                        sleep 3
                        get_info
                        add_nginx_conf
                        create_shortcut
                    fi
                    ;;
                2)  uninstall_singbox;       need_pause=false ;;
                3)  manage_singbox;          need_pause=true ;;
                4)  manage_argo;             need_pause=true ;;
                5)  check_nodes;             need_pause=true ;;
                6)  change_config;           need_pause=true ;;
                7)  reset_inbound_ip_menu;   need_pause=true ;;
                8)  disable_open_sub;        need_pause=true ;;
                9)  manage_protocols;        need_pause=false ;;
                10) warp_manage;             need_pause=false ;;
                0)  exit 0 ;;
                *)  red "无效的选项，请输入 0-10"; need_pause=true ;;
            esac
            [ "$need_pause" = true ] && read -n 1 -s -r -p $'\033[1;91m按任意键返回主菜单...\033[0m'
        done
        ;;
    *)
        red "未知参数: $1 (输入 sb -h 查看帮助)"
        exit 1
        ;;
esac
