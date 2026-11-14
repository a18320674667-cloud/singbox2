#!/bin/bash

# =========================
# sing-box 64M极简低内存多协议脚本 (纯Base64输出版)
# 支持协议: vless-reality | vmess-ws(argo) | hysteria2 | tuic5 | anytls | socks5 | ss2022
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

# 定义路径常量
server_name="sing-box"
work_dir="/etc/sing-box"
conf_dir="${work_dir}/conf"
client_dir="${work_dir}/url.txt"
sub_file="${work_dir}/sub.txt"
meta_file="${work_dir}/meta.conf"
ports_file="${work_dir}/ports.list"
swap_file="/swapfile_sb"

export CFIP=${CFIP:-'cdns.doon.eu.org'}
export CFPORT=${CFPORT:-'443'}

# 检查 root 权限
[[ $EUID -ne 0 ]] && red "请在 root 用户下运行脚本 (输入 sudo -i 切换)" && exit 1

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 兼容 Alpine(BusyBox) 与 Debian 的 Base64 不换行编码函数
b64_encode() {
    base64 -w0 2>/dev/null || base64 | tr -d '\n\r'
}

# 兼容随机端口生成
rand_port() {
    shuf -i 10000-60000 -n 1 2>/dev/null || echo $(( (RANDOM % 50000) + 10000 ))
}

# =========================
# 自动绑定 sb 快捷键 (脚本启动即生效)
# =========================
bind_sb_shortcut() {
    mkdir -p "$work_dir"
    local script_path=""
    if [ -f "$0" ]; then
        script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
    fi
    if [ -n "$script_path" ] && [ -f "$script_path" ] && [[ "$script_path" != *"/dev/fd/"* ]]; then
        if [ "$script_path" != "${work_dir}/sb.sh" ]; then
            cp -f "$script_path" "${work_dir}/sb.sh" 2>/dev/null || true
        fi
        chmod +x "${work_dir}/sb.sh" 2>/dev/null || true
        ln -sf "${work_dir}/sb.sh" /usr/bin/sb 2>/dev/null || true
        ln -sf "${work_dir}/sb.sh" /usr/local/bin/sb 2>/dev/null || true
    fi
}

# 启动时立即绑定 sb 快捷键
bind_sb_shortcut

# =========================
# 64M 内存防崩溃与内核网络优化
# =========================
optimize_low_memory() {
    local mem_total
    mem_total=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 256)
    local swap_total
    swap_total=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)

    # 开启双栈兼容与内存超分配许可
    sysctl -w net.ipv6.bindv6only=0 >/dev/null 2>&1 || true
    sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 || true
    sysctl -w vm.vfs_cache_pressure=200 >/dev/null 2>&1 || true

    if [ "$mem_total" -le 192 ] && [ "$swap_total" -lt 64 ]; then
        yellow "检测到物理内存较小 (${mem_total}MB)，尝试创建 128MB Swap 防崩溃..."
        if [ ! -f "$swap_file" ]; then
            dd if=/dev/zero of="$swap_file" bs=1M count=128 status=none 2>/dev/null || true
            chmod 600 "$swap_file" 2>/dev/null || true
            mkswap "$swap_file" >/dev/null 2>&1 || true
            if swapon "$swap_file" >/dev/null 2>&1; then
                sysctl -w vm.swappiness=60 >/dev/null 2>&1 || true
                grep -q "$swap_file" /etc/fstab 2>/dev/null || echo "$swap_file swap swap defaults 0 0" >> /etc/fstab
                green "128MB Swap 启用成功！"
            else
                rm -f "$swap_file" >/dev/null 2>&1 || true
                yellow "当前容器不支持挂载 Swap，将通过 GOMEMLIMIT 内存硬限制保障稳定运行。"
            fi
        fi
    fi
}

# =========================
# 元数据持久化读写
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
# 服务状态检测与管理
# =========================
get_service_file() {
    case "$1" in
        sing-box) echo "${work_dir}/${server_name}" ;;
        argo)     echo "${work_dir}/argo" ;;
        *)        echo "" ;;
    esac
}

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

manage_service() {
    local service_name="$1"
    local action="$2"
    local status
    status=$(check_service_raw "$service_name")

    case "$action" in
        "start")
            [ "$status" == "running" ] && return 0
            [ "$status" == "not installed" ] && { yellow "${service_name} 尚未安装!\n"; return 1; }
            if command_exists rc-service; then rc-service "$service_name" start >/dev/null 2>&1
            elif command_exists systemctl; then systemctl daemon-reload && systemctl start "$service_name" >/dev/null 2>&1; fi
            ;;
        "stop")
            [ "$status" == "not installed" ] || [ "$status" == "not running" ] && return 0
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

# =========================
# 极简依赖安装 (去除 Nginx，绝不执行全量 upgrade)
# =========================
manage_packages() {
    local action=$1
    shift
    if [ "$action" == "install" ]; then
        local need_update=0
        for pkg in "$@"; do
            if [ "$pkg" == "coreutils" ] && command_exists base64; then continue; fi
            command_exists "$pkg" || need_update=1
        done
        if [ "$need_update" -eq 1 ]; then
            yellow "正在检查并安装基础依赖工具..."
            if command_exists apt-get; then
                DEBIAN_FRONTEND=noninteractive apt-get update -y -o Acquire::Languages=none >/dev/null 2>&1 || true
            elif command_exists apk; then
                apk update >/dev/null 2>&1 || true
            fi
        fi
        for package in "$@"; do
            if [ "$package" == "coreutils" ] && command_exists base64; then continue; fi
            command_exists "$package" && continue
            if command_exists apt-get; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$package" >/dev/null 2>&1
            elif command_exists dnf; then
                dnf install -y "$package" >/dev/null 2>&1
            elif command_exists yum; then
                yum install -y "$package" >/dev/null 2>&1
            elif command_exists apk; then
                apk add --no-cache "$package" >/dev/null 2>&1
            fi
        done
    fi
}

# =========================
# IPv4 / IPv6 检测与入站模式配置
# =========================
detect_ipv4() {
    local ip
    ip=$(curl -4 -sm 3 ip.sb || curl -4 -sm 3 api.ipify.org || curl -4 -sm 3 ifconfig.me)
    if printf '%s' "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        echo "$ip"
    else
        echo ""
    fi
}

detect_ipv6() {
    local v6
    v6=$(curl -6 -sm 3 ip.sb || curl -6 -sm 3 api64.ipify.org || curl -6 -sm 3 ifconfig.me)
    if printf '%s' "$v6" | grep -Eq '^[0-9a-fA-F:]+$'; then
        echo "$v6"
    else
        echo ""
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
    [ -z "$isp" ] && isp=$(hostname 2>/dev/null | sed 's/ /_/g' || echo "Node")
    save_meta "ISP_NAME" "$isp"
    echo "$isp"
}

# 交互式设置入站 IP 与监听栈 (IPv4 / IPv6 / 双栈)
configure_inbound_stack_and_ip() {
    yellow "\n正在检测服务器 IPv4 / IPv6 地址..."
    local auto_v4 auto_v6
    auto_v4=$(detect_ipv4)
    auto_v6=$(detect_ipv6)

    echo ""
    green "=== 设置入站网络模式 (IPv4 / IPv6 / 双栈) ==="
    echo -e " 检测到公网 IPv4 : ${skyblue}${auto_v4:-未检测到}${re}"
    echo -e " 检测到公网 IPv6 : ${skyblue}${auto_v6:-未检测到}${re}"
    echo ""
    green "  1. 纯 IPv4 模式       (服务端监听 0.0.0.0，节点使用 IPv4 地址)"
    green "  2. 纯 IPv6 模式       (服务端监听 ::，节点使用 [IPv6] 地址)"
    green "  3. 双栈模式 [v4+v6]   (服务端监听 ::，同时生成 IPv4 和 IPv6 两条节点)"
    green "  4. 双栈监听 + 自定义单入站地址 (服务端监听 ::，手动指定节点连接 IP/域名)"
    skyblue "--------------------------------------------------------"
    reading "请选择入站模式 (1-4，直接回车默认选 3 双栈，若仅单栈则自动适配): " stack_choice

    case "$stack_choice" in
        1)
            save_meta "STACK_MODE" "v4"
            save_meta "LISTEN_IP" "0.0.0.0"
            reading "请输入节点入站 IPv4 地址 (直接回车使用 ${auto_v4:-127.0.0.1}): " input_v4
            save_meta "NODE_IPV4" "${input_v4:-${auto_v4:-127.0.0.1}}"
            ;;
        2)
            save_meta "STACK_MODE" "v6"
            save_meta "LISTEN_IP" "::"
            reading "请输入节点入站 IPv6 地址，无需中括号 (直接回车使用 ${auto_v6:-::1}): " input_v6
            input_v6=$(echo "${input_v6:-${auto_v6:-::1}}" | tr -d '[]')
            save_meta "NODE_IPV6" "$input_v6"
            ;;
        4)
            save_meta "STACK_MODE" "custom"
            save_meta "LISTEN_IP" "::"
            local default_custom="${auto_v4:-${auto_v6}}"
            reading "请输入自定义入站 IP 或域名 (直接回车使用 ${default_custom}): " input_custom
            input_custom="${input_custom:-$default_custom}"
            if [[ "$input_custom" == *":"* ]] && [[ "$input_custom" != "["* ]]; then
                input_custom="[${input_custom}]"
            fi
            save_meta "CUSTOM_NODE_IP" "$input_custom"
            ;;
        *)
            # 默认双栈
            save_meta "LISTEN_IP" "::"
            if [ -n "$auto_v4" ] && [ -n "$auto_v6" ]; then
                save_meta "STACK_MODE" "dual"
                reading "请输入 IPv4 节点地址 (回车默认 ${auto_v4}): " input_v4
                reading "请输入 IPv6 节点地址，无需括号 (回车默认 ${auto_v6}): " input_v6
                save_meta "NODE_IPV4" "${input_v4:-$auto_v4}"
                save_meta "NODE_IPV6" "$(echo "${input_v6:-$auto_v6}" | tr -d '[]')"
            elif [ -n "$auto_v4" ]; then
                yellow "未检测到可用 IPv6，已开启双栈监听 (::) 并使用 IPv4 生成节点。"
                save_meta "STACK_MODE" "v4"
                reading "请输入节点入站 IPv4 地址 (回车默认 ${auto_v4}): " input_v4
                save_meta "NODE_IPV4" "${input_v4:-$auto_v4}"
            elif [ -n "$auto_v6" ]; then
                yellow "未检测到可用 IPv4，已开启双栈监听 (::) 并使用 IPv6 生成节点。"
                save_meta "STACK_MODE" "v6"
                reading "请输入节点入站 IPv6 地址，无需括号 (回车默认 ${auto_v6}): " input_v6
                save_meta "NODE_IPV6" "$(echo "${input_v6:-$auto_v6}" | tr -d '[]')"
            else
                save_meta "STACK_MODE" "custom"
                reading "未能自动检测到公网IP，请手动输入节点入站 IP 或域名: " input_custom
                if [[ "$input_custom" == *":"* ]] && [[ "$input_custom" != "["* ]]; then
                    input_custom="[${input_custom}]"
                fi
                save_meta "CUSTOM_NODE_IP" "${input_custom:-127.0.0.1}"
            fi
            ;;
    esac

    # 如果 inbounds.json 已存在，同步更新其中的 listen 字段
    if [ -f "${conf_dir}/inbounds.json" ]; then
        load_meta
        jq --arg lip "${LISTEN_IP:-::}" '(.inbounds[].listen) = $lip' \
            "${conf_dir}/inbounds.json" > "${conf_dir}/inbounds.json.tmp" && \
            mv "${conf_dir}/inbounds.json.tmp" "${conf_dir}/inbounds.json"
    fi
}

# =========================
# 防火墙放行与清理
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

    load_meta
    if [ -n "$HY2_MPORT_MIN" ] && [ -n "$HY2_MPORT_MAX" ] && [ -n "$HY2_PORT" ]; then
        command_exists iptables && iptables -t nat -D PREROUTING -p udp --dport "${HY2_MPORT_MIN}:${HY2_MPORT_MAX}" -j DNAT --to-destination ":${HY2_PORT}" >/dev/null 2>&1 || true
        command_exists ip6tables && ip6tables -t nat -D PREROUTING -p udp --dport "${HY2_MPORT_MIN}:${HY2_MPORT_MAX}" -j DNAT --to-destination ":${HY2_PORT}" >/dev/null 2>&1 || true
    fi
}

# =========================
# 端口输入与冲突校验函数
# =========================
prompt_custom_port() {
    local proto_title="$1"
    local default_p="$2"
    local chosen_p=""

    while true; do
        reading "请指定 [${proto_title}] 监听端口 (1-65535，直接回车使用 ${default_p}): " chosen_p
        chosen_p="${chosen_p:-$default_p}"

        if [[ ! "$chosen_p" =~ ^[0-9]+$ ]] || [ "$chosen_p" -lt 1 ] || [ "$chosen_p" -gt 65535 ]; then
            yellow "端口无效，请输入 1 到 65535 之间的数字！"
            continue
        fi

        # 检查是否与当前 inbounds.json 中已分配的其他协议端口冲突
        if [ -f "${conf_dir}/inbounds.json" ]; then
            if jq -e --argjson p "$chosen_p" '.inbounds[] | select(.listen_port == $p)' "${conf_dir}/inbounds.json" >/dev/null 2>&1; then
                yellow "端口 ${chosen_p} 已被其他入站协议占用，请换一个端口！"
                default_p=$(rand_port)
                continue
            fi
        fi
        break
    done
    Selected_Port="$chosen_p"
    green " -> [${proto_title}] 端口已设为: ${purple}${Selected_Port}${re}"
}

# =========================
# 按需下载二进制文件
# =========================
get_arch() {
    case "$(uname -m)" in
        'x86_64' | 'amd64')  echo 'amd64' ;;
        'x86' | 'i686' | 'i386') echo '386' ;;
        'aarch64' | 'arm64') echo 'arm64' ;;
        'armv7l')  echo 'armv7' ;;
        's390x')   echo 's390x' ;;
        *) red "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}

ensure_argo_binary() {
    if [ ! -x "${work_dir}/argo" ]; then
        local arch
        arch=$(get_arch)
        yellow "正在下载 Argo (cloudflared) 组件..."
        curl -sLo "${work_dir}/argo" "https://${arch}.eooce.com/bot"
        chmod +x "${work_dir}/argo"
    fi
}

# =========================
# 协议管理底层逻辑 (添加/删除/指定端口)
# =========================
proto_exists() {
    local tag="$1"
    [ -f "${conf_dir}/inbounds.json" ] && jq -e --arg tag "$tag" '.inbounds[] | select(.tag == $tag)' "${conf_dir}/inbounds.json" >/dev/null 2>&1
}

add_proto_to_inbounds() {
    local proto_key="$1"
    local interactive="${2:-1}"
    local inbounds_file="${conf_dir}/inbounds.json"
    load_meta
    local listen_ip="${LISTEN_IP:-::}"

    case "$proto_key" in
        vless|vless-reality)
            if proto_exists "vless-reality"; then
                yellow "vless-reality 已存在，跳过添加。"; return 0
            fi
            local def_port="${VLESS_PORT:-$(rand_port)}"
            if [ "$interactive" -eq 1 ]; then
                prompt_custom_port "VLESS-Reality" "$def_port"
                def_port="$Selected_Port"
            fi
            save_meta "VLESS_PORT" "$def_port"
            local sni="${REALITY_SNI:-www.iij.ad.jp}"
            save_meta "REALITY_SNI" "$sni"

            jq --arg listen "$listen_ip" \
               --argjson port "$def_port" \
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
            allow_port "${def_port}/tcp"
            ;;

        vmess|vmess-ws)
            if proto_exists "vmess-ws"; then
                yellow "vmess-ws 已存在，跳过添加。"; return 0
            fi
            ensure_argo_binary
            local def_port="${VMESS_PORT:-8001}"
            if [ "$interactive" -eq 1 ]; then
                prompt_custom_port "VMess-WS (Argo本地监听)" "$def_port"
                def_port="$Selected_Port"
            fi
            save_meta "VMESS_PORT" "$def_port"

            jq --arg listen "$listen_ip" \
               --argjson port "$def_port" \
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
            allow_port "${def_port}/tcp"
            ;;

        hy2|hysteria2)
            if proto_exists "hysteria2"; then
                yellow "hysteria2 已存在，跳过添加。"; return 0
            fi
            local def_port="${HY2_PORT:-$(rand_port)}"
            if [ "$interactive" -eq 1 ]; then
                prompt_custom_port "Hysteria2 (UDP)" "$def_port"
                def_port="$Selected_Port"
            fi
            save_meta "HY2_PORT" "$def_port"

            jq --arg listen "$listen_ip" \
               --argjson port "$def_port" \
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
            allow_port "${def_port}/udp"
            ;;

        tuic|tuic5)
            if proto_exists "tuic"; then
                yellow "tuic 已存在，跳过添加。"; return 0
            fi
            local def_port="${TUIC_PORT:-$(rand_port)}"
            if [ "$interactive" -eq 1 ]; then
                prompt_custom_port "TUIC-v5 (UDP)" "$def_port"
                def_port="$Selected_Port"
            fi
            save_meta "TUIC_PORT" "$def_port"

            jq --arg listen "$listen_ip" \
               --argjson port "$def_port" \
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
            allow_port "${def_port}/udp"
            ;;

        anytls)
            if proto_exists "anytls"; then
                yellow "AnyTLS 已存在，跳过添加。"; return 0
            fi
            local def_port="${ANYTLS_PORT:-$(rand_port)}"
            if [ "$interactive" -eq 1 ]; then
                prompt_custom_port "AnyTLS (TCP)" "$def_port"
                def_port="$Selected_Port"
            fi
            save_meta "ANYTLS_PORT" "$def_port"

            jq --arg listen "$listen_ip" \
               --argjson port "$def_port" \
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
            allow_port "${def_port}/tcp"
            ;;

        socks|socks5|socks5-in)
            if proto_exists "socks5-in"; then
                yellow "Socks5 已存在，跳过添加。"; return 0
            fi
            local def_port="${SOCKS_PORT:-$(rand_port)}"
            local sk_user="${SOCKS_USER:-${UUID:0:8}}"
            local sk_pass="${SOCKS_PASS:-${UUID: -12}}"
            if [ "$interactive" -eq 1 ]; then
                prompt_custom_port "Socks5" "$def_port"
                def_port="$Selected_Port"
                reading "请输入 Socks5 用户名 (直接回车默认 ${sk_user}): " input_u
                [ -n "$input_u" ] && sk_user="$input_u"
                reading "请输入 Socks5 密码 (直接回车默认 ${sk_pass}): " input_pw
                [ -n "$input_pw" ] && sk_pass="$input_pw"
            fi
            save_meta "SOCKS_PORT" "$def_port"
            save_meta "SOCKS_USER" "$sk_user"
            save_meta "SOCKS_PASS" "$sk_pass"

            jq --arg listen "$listen_ip" \
               --argjson port "$def_port" \
               --arg user "$sk_user" \
               --arg pass "$sk_pass" \
               '.inbounds += [{
                   "type": "socks",
                   "tag": "socks5-in",
                   "listen": $listen,
                   "listen_port": $port,
                   "users": [{"username": $user, "password": $pass}]
               }]' "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
            allow_port "${def_port}/tcp" "${def_port}/udp"
            ;;

        ss|ss2022|shadowsocks-2022)
            if proto_exists "shadowsocks-2022"; then
                yellow "Shadowsocks-2022 已存在，跳过添加。"; return 0
            fi
            local def_port="${SS_PORT:-$(rand_port)}"
            local ss_method="${SS_METHOD:-2022-blake3-aes-128-gcm}"
            local key_len=16
            if [ "$interactive" -eq 1 ]; then
                prompt_custom_port "Shadowsocks-2022" "$def_port"
                def_port="$Selected_Port"
                green "请选择 SS2022 加密方式: 1. aes-128-gcm(默认)  2. aes-256-gcm  3. chacha20-poly1305"
                reading "请输入选择 (回车默认1): " m_choice
                case "$m_choice" in
                    2) ss_method="2022-blake3-aes-256-gcm"; key_len=32 ;;
                    3) ss_method="2022-blake3-chacha20-poly1305"; key_len=32 ;;
                    *) ss_method="2022-blake3-aes-128-gcm"; key_len=16 ;;
                esac
            fi
            local ss_key
            ss_key=$(dd if=/dev/urandom bs=1 count=${key_len} 2>/dev/null | b64_encode)
            save_meta "SS_PORT" "$def_port"
            save_meta "SS_METHOD" "$ss_method"
            save_meta "SS_KEY" "$ss_key"

            jq --arg listen "$listen_ip" \
               --argjson port "$def_port" \
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
            allow_port "${def_port}/tcp" "${def_port}/udp"
            ;;
    esac
}

remove_proto_from_inbounds() {
    local tag="$1"
    local inbounds_file="${conf_dir}/inbounds.json"
    if ! proto_exists "$tag"; then
        yellow "协议 [$tag] 当前未启用，无需删除。"
        return 1
    fi

    jq --arg tag "$tag" 'del(.inbounds[] | select(.tag == $tag))' \
        "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"

    if [ "$tag" == "vmess-ws" ]; then
        stop_argo
        if command_exists systemctl; then
            systemctl disable argo >/dev/null 2>&1 || true
        elif command_exists rc-update; then
            rc-update del argo default >/dev/null 2>&1 || true
        fi
        yellow "已同步停止 Argo 进程释放内存。"
    fi
    return 0
}

# =========================
# 生成节点列表并输出纯 Base64 编码
# =========================
rebuild_urls() {
    local inbounds_file="${conf_dir}/inbounds.json"
    [ ! -f "$inbounds_file" ] && return 1

    load_meta
    local isp
    isp=$(get_isp_name)
    local cfip="${CFIP_SAVED:-${CFIP}}"
    local cfport="${CFPORT_SAVED:-${CFPORT}}"

    # 根据 STACK_MODE 构建要生成节点的入站地址数组与后缀
    local addr_list=()
    local suffix_list=()
    case "${STACK_MODE}" in
        v4)
            local v4="${NODE_IPV4:-$(detect_ipv4)}"
            addr_list=("${v4:-127.0.0.1}")
            suffix_list=("")
            ;;
        v6)
            local v6="${NODE_IPV6:-$(detect_ipv6)}"
            v6=$(echo "$v6" | tr -d '[]')
            addr_list=("[${v6:-::1}]")
            suffix_list=("")
            ;;
        dual)
            local v4="${NODE_IPV4:-$(detect_ipv4)}"
            local v6="${NODE_IPV6:-$(detect_ipv6)}"
            v6=$(echo "$v6" | tr -d '[]')
            [ -n "$v4" ] && { addr_list+=("$v4"); suffix_list+=("-v4"); }
            [ -n "$v6" ] && { addr_list+=("[${v6}]"); suffix_list+=("-v6"); }
            if [ "${#addr_list[@]}" -eq 0 ]; then
                addr_list=("127.0.0.1"); suffix_list=("")
            fi
            ;;
        *)
            local cip="${CUSTOM_NODE_IP:-$(detect_ipv4)}"
            addr_list=("${cip:-127.0.0.1}")
            suffix_list=("")
            ;;
    esac

    > "$client_dir"

    # 1. vless-reality
    if proto_exists "vless-reality"; then
        local v_port v_uuid v_sni
        v_port=$(jq -r '.inbounds[] | select(.tag == "vless-reality") | .listen_port' "$inbounds_file")
        v_uuid=$(jq -r '.inbounds[] | select(.tag == "vless-reality") | .users[0].uuid' "$inbounds_file")
        v_sni=$(jq -r '.inbounds[] | select(.tag == "vless-reality") | .tls.server_name' "$inbounds_file")
        for idx in "${!addr_list[@]}"; do
            echo "vless://${v_uuid}@${addr_list[$idx]}:${v_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${v_sni}&fp=firefox&pbk=${PUBLIC_KEY}&type=tcp&headerType=none#${isp}${suffix_list[$idx]}" >> "$client_dir"
        done
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
        vmess_json="{ \"v\": \"2\", \"ps\": \"${isp}-argo\", \"add\": \"${cfip}\", \"port\": \"${cfport}\", \"id\": \"${m_uuid}\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess-argo?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"firefox\", \"allowInsecure\": \"false\"}"
        echo "vmess://$(printf '%s' "$vmess_json" | b64_encode)" >> "$client_dir"
    fi

    # 3. hysteria2
    if proto_exists "hysteria2"; then
        local h_port h_pass mport_str=""
        h_port=$(jq -r '.inbounds[] | select(.tag == "hysteria2") | .listen_port' "$inbounds_file")
        h_pass=$(jq -r '.inbounds[] | select(.tag == "hysteria2") | .users[0].password' "$inbounds_file")
        if [ -n "$HY2_MPORT_MIN" ] && [ -n "$HY2_MPORT_MAX" ]; then
            mport_str="&mport=${h_port},${HY2_MPORT_MIN}-${HY2_MPORT_MAX}"
        fi
        for idx in "${!addr_list[@]}"; do
            echo "hysteria2://${h_pass}@${addr_list[$idx]}:${h_port}/?sni=www.bing.com&insecure=1&pinSHA256=${FINGERPRINT}&alpn=h3&obfs=none${mport_str}#${isp}${suffix_list[$idx]}" >> "$client_dir"
        done
    fi

    # 4. tuic
    if proto_exists "tuic"; then
        local t_port t_uuid t_pass
        t_port=$(jq -r '.inbounds[] | select(.tag == "tuic") | .listen_port' "$inbounds_file")
        t_uuid=$(jq -r '.inbounds[] | select(.tag == "tuic") | .users[0].uuid' "$inbounds_file")
        t_pass=$(jq -r '.inbounds[] | select(.tag == "tuic") | .users[0].password' "$inbounds_file")
        for idx in "${!addr_list[@]}"; do
            echo "tuic://${t_uuid}:${t_pass}@${addr_list[$idx]}:${t_port}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${isp}${suffix_list[$idx]}" >> "$client_dir"
        done
    fi

    # 5. anytls
    if proto_exists "anytls"; then
        local a_port a_pass
        a_port=$(jq -r '.inbounds[] | select(.tag == "anytls") | .listen_port' "$inbounds_file")
        a_pass=$(jq -r '.inbounds[] | select(.tag == "anytls") | .users[0].password' "$inbounds_file")
        for idx in "${!addr_list[@]}"; do
            echo "anytls://${a_pass}@${addr_list[$idx]}:${a_port}?insecure=1&sni=bing.com#${isp}${suffix_list[$idx]}" >> "$client_dir"
        done
    fi

    # 6. socks5-in
    if proto_exists "socks5-in"; then
        local s_port s_user s_pass s_auth
        s_port=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .listen_port' "$inbounds_file")
        s_user=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .users[0].username' "$inbounds_file")
        s_pass=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .users[0].password' "$inbounds_file")
        s_auth=$(printf '%s:%s' "$s_user" "$s_pass" | b64_encode)
        for idx in "${!addr_list[@]}"; do
            echo "socks://${s_auth}@${addr_list[$idx]}:${s_port}#${isp}${suffix_list[$idx]}" >> "$client_dir"
        done
    fi

    # 7. shadowsocks-2022
    if proto_exists "shadowsocks-2022"; then
        local ss_port ss_method ss_key ss_auth
        ss_port=$(jq -r '.inbounds[] | select(.tag == "shadowsocks-2022") | .listen_port' "$inbounds_file")
        ss_method=$(jq -r '.inbounds[] | select(.tag == "shadowsocks-2022") | .method' "$inbounds_file")
        ss_key=$(jq -r '.inbounds[] | select(.tag == "shadowsocks-2022") | .password' "$inbounds_file")
        ss_auth=$(printf '%s:%s' "$ss_method" "$ss_key" | b64_encode)
        for idx in "${!addr_list[@]}"; do
            echo "ss://${ss_auth}@${addr_list[$idx]}:${ss_port}#${isp}${suffix_list[$idx]}" >> "$client_dir"
        done
    fi

    # 编码为纯 Base64 字符串写入 sub.txt
    if [ -s "$client_dir" ]; then
        b64_encode < "$client_dir" > "$sub_file"
    else
        > "$sub_file"
    fi
}

# 仅输出纯 Base64 编码
check_nodes() {
    if [ ! -f "${sub_file}" ] || [ ! -s "${sub_file}" ]; then
        red "\n当前没有已生成的节点 Base64 数据，请先安装或添加协议。\n"
        return 1
    fi
    echo ""
    green "==================== 节点 Base64 编码 ===================="
    echo ""
    echo -e "${purple}$(cat "${sub_file}")${re}"
    echo ""
    green "=========================================================="
    echo ""
}

# =========================
# 交互式选择要生成的协议
# =========================
select_install_protocols() {
    echo ""
    purple "=== 选择要生成的协议节点 (支持多选) ==="
    green "  1. vless-reality       (极低内存，TCP直连)"
    green "  2. vmess-ws + Argo隧道 (套CF隧道，需运行argo进程约占25M内存)"
    green "  3. hysteria2           (UDP高速协议)"
    green "  4. tuic v5             (UDP低延迟协议)"
    green "  5. AnyTLS              (新式TLS伪装协议)"
    green "  6. Socks5              (基础代理协议)"
    green "  7. Shadowsocks-2022    (轻量级SS2022加密协议)"
    skyblue "--------------------------------------------------------"
    yellow "提示: 多个协议请用空格或逗号隔开 (例如: 1 3 或 1,3,7)"
    yellow "      直接回车默认生成 [1 3 4] (vless + hy2 + tuic，免Argo极省内存)"
    reading "请输入协议编号 (回车默认 1 3 4): " proto_input

    if [ -z "$proto_input" ]; then
        SELECTED_PROTOS="1 3 4"
    else
        SELECTED_PROTOS=$(echo "$proto_input" | tr ',' ' ')
    fi
}

# =========================
# 安装主流程
# =========================
install_singbox() {
    optimize_low_memory
    clear
    purple "=== 开始配置并安装 sing-box (64M轻量稳定版) ==="

    # 第一步：设置入站模式 (IPv4 / IPv6 / 双栈) 与入站地址
    configure_inbound_stack_and_ip

    # 第二步：选择要生成的协议
    SELECTED_PROTOS=""
    select_install_protocols

    local arch
    arch=$(get_arch)
    mkdir -p "${work_dir}" "${conf_dir}"
    chmod 755 "${work_dir}"

    if [ ! -x "${work_dir}/${server_name}" ]; then
        yellow "\n正在下载 sing-box 核心组件..."
        curl -sLo "${work_dir}/sing-box" "https://${arch}.eooce.com/sb"
        chmod +x "${work_dir}/${server_name}"
    fi

    local uuid output private_key public_key fingerprint
    uuid=$(cat /proc/sys/kernel/random/uuid)
    output=$("${work_dir}/sing-box" generate reality-keypair)
    private_key=$(echo "${output}" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "${output}" | awk '/PublicKey:/ {print $2}')

    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key" >/dev/null 2>&1
    openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com" >/dev/null 2>&1
    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g')

    save_meta "UUID" "$uuid"
    save_meta "PRIVATE_KEY" "$private_key"
    save_meta "PUBLIC_KEY" "$public_key"
    save_meta "FINGERPRINT" "$fingerprint"
    save_meta "REALITY_SNI" "www.iij.ad.jp"
    save_meta "CFIP_SAVED" "$CFIP"
    save_meta "CFPORT_SAVED" "$CFPORT"

    local dns_strategy="prefer_ipv4"
    load_meta
    [ "$STACK_MODE" == "v6" ] && dns_strategy="prefer_ipv6"

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

    # 第三步：逐个协议提示用户指定端口并写入 inbounds.json
    echo '{"inbounds": []}' > "${conf_dir}/inbounds.json"
    echo ""
    purple "=== 请为所选协议设置监听端口 ==="
    for item in $SELECTED_PROTOS; do
        case "$item" in
            1|vless)   add_proto_to_inbounds "vless-reality" 1 ;;
            2|vmess)   add_proto_to_inbounds "vmess-ws" 1 ;;
            3|hy2)     add_proto_to_inbounds "hysteria2" 1 ;;
            4|tuic)    add_proto_to_inbounds "tuic" 1 ;;
            5|anytls)  add_proto_to_inbounds "anytls" 1 ;;
            6|socks5)  add_proto_to_inbounds "socks5-in" 1 ;;
            7|ss2022)  add_proto_to_inbounds "shadowsocks-2022" 1 ;;
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
# 守护进程配置 (带 GOMEMLIMIT 内存硬限制)
# =========================
main_systemd_services() {
    load_meta
    local argo_p="${VMESS_PORT:-8001}"

    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
Environment="GOGC=30"
Environment="GOMEMLIMIT=25MiB"
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

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box

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
export GOMEMLIMIT=25MiB
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

sync_argo_service() {
    if proto_exists "vmess-ws"; then
        ensure_argo_binary
        if command_exists systemctl; then
            main_systemd_services
        elif command_exists rc-update; then
            alpine_openrc_services
        fi
        get_quick_tunnel
    fi
}

get_quick_tunnel() {
    restart_argo
    yellow "正在获取 Argo 临时域名，请稍候..."
    sleep 3
    local get_argodomain=""
    if [ -f "${work_dir}/argo.log" ]; then
        for i in {1..6}; do
            get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -1)
            [ -n "$get_argodomain" ] && break
            sleep 2
        done
    fi
    [ -n "$get_argodomain" ] && save_meta "ARGO_DOMAIN" "$get_argodomain"
}

get_info() {
    if proto_exists "vmess-ws"; then
        get_quick_tunnel
    fi
    rebuild_urls
    clear
    green "sing-box 安装并启动成功！(后续随时输入 sb 即可打开管理菜单)"
    check_nodes
}

# =========================
# 彻底卸载并恢复初始状态
# =========================
perform_full_uninstall() {
    yellow "\n正在停止服务并清理系统配置..."

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

    clean_firewall_rules

    if [ -f "${work_dir}/hosts.bak" ]; then
        cp -f "${work_dir}/hosts.bak" /etc/hosts >/dev/null 2>&1 || true
    fi

    if [ -f "$swap_file" ]; then
        swapoff "$swap_file" >/dev/null 2>&1 || true
        sed -i "\|$swap_file|d" /etc/fstab 2>/dev/null || true
        rm -f "$swap_file" >/dev/null 2>&1 || true
    fi

    rm -rf "${work_dir}" >/dev/null 2>&1 || true
    rm -f /usr/bin/sb /usr/local/bin/sb >/dev/null 2>&1 || true

    green "\nsing-box、Argo、防火墙规则及快捷指令已彻底卸载，系统已恢复初始状态！\n"
}

uninstall_singbox() {
    clear
    red "=== 彻底卸载 sing-box 并恢复初始状态 ==="
    reading "确定要彻底卸载并恢复系统初始状态吗? (y/n): " choice
    case "${choice}" in
        y|Y) perform_full_uninstall; exit 0 ;;
        *)   purple "已取消卸载操作\n" ;;
    esac
}

# =========================
# 协议节点管理中心 (删除/恢复/添加指定协议)
# =========================
show_all_proto_status() {
    local inbounds_file="${conf_dir}/inbounds.json"
    load_meta
    echo ""
    green "=== 当前入站与协议状态 (监听: ${LISTEN_IP:-::} | 模式: ${STACK_MODE:-dual}) ==="
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
        yellow "sing-box 尚未安装！请先选择 1 安装。"; sleep 1; return
    fi

    clear
    green "=== 协议节点管理 (添加 / 恢复 / 删除指定协议) ==="
    show_all_proto_status

    green "1. 恢复 / 添加指定协议节点 (可自定义指定端口)"
    skyblue "------------------------------------------------"
    red   "2. 删除指定协议节点"
    skyblue "------------------------------------------------"
    green "3. 重新选择协议组合并指定端口"
    skyblue "------------------------------------------------"
    purple "0. 返回主菜单"
    skyblue "------------------------------------------------"
    reading "请输入选择: " proto_choice
    echo ""

    case "${proto_choice}" in
        1)
            green "请选择要【恢复 / 添加】的协议 (多个编号用空格隔开，如: 1 3):"
            echo "  1. vless-reality   2. vmess-ws(Argo)   3. hysteria2   4. tuic v5"
            echo "  5. AnyTLS          6. Socks5           7. Shadowsocks-2022"
            reading "请输入协议编号: " add_inputs
            [ -z "$add_inputs" ] && return
            local need_argo_sync=0
            for num in $(echo "$add_inputs" | tr ',' ' '); do
                case "$num" in
                    1) add_proto_to_inbounds "vless-reality" 1 ;;
                    2) add_proto_to_inbounds "vmess-ws" 1; need_argo_sync=1 ;;
                    3) add_proto_to_inbounds "hysteria2" 1 ;;
                    4) add_proto_to_inbounds "tuic" 1 ;;
                    5) add_proto_to_inbounds "anytls" 1 ;;
                    6) add_proto_to_inbounds "socks5-in" 1 ;;
                    7) add_proto_to_inbounds "shadowsocks-2022" 1 ;;
                    *) red "忽略无效编号: $num" ;;
                esac
            done
            restart_singbox
            [ "$need_argo_sync" -eq 1 ] && sync_argo_service
            rebuild_urls
            check_nodes
            ;;
        2)
            red "请选择要【删除】的协议 (多个编号用空格隔开，如: 2 4):"
            echo "  1. vless-reality   2. vmess-ws(Argo)   3. hysteria2   4. tuic v5"
            echo "  5. AnyTLS          6. Socks5           7. Shadowsocks-2022"
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
                esac
            done
            restart_singbox
            rebuild_urls
            check_nodes
            ;;
        3)
            configure_inbound_stack_and_ip
            SELECTED_PROTOS=""
            select_install_protocols
            echo '{"inbounds": []}' > "${conf_dir}/inbounds.json"
            local need_argo_sync=0
            for item in $SELECTED_PROTOS; do
                case "$item" in
                    1) add_proto_to_inbounds "vless-reality" 1 ;;
                    2) add_proto_to_inbounds "vmess-ws" 1; need_argo_sync=1 ;;
                    3) add_proto_to_inbounds "hysteria2" 1 ;;
                    4) add_proto_to_inbounds "tuic" 1 ;;
                    5) add_proto_to_inbounds "anytls" 1 ;;
                    6) add_proto_to_inbounds "socks5-in" 1 ;;
                    7) add_proto_to_inbounds "shadowsocks-2022" 1 ;;
                esac
            done
            if [ "$need_argo_sync" -eq 1 ]; then
                sync_argo_service
            else
                stop_argo
            fi
            restart_singbox
            rebuild_urls
            check_nodes
            ;;
        0) return ;;
    esac
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回协议管理菜单...\033[0m\n'
    manage_protocols
}

# =========================
# 修改节点配置菜单
# =========================
change_config() {
    if [ "$(check_service_raw sing-box)" == "not installed" ]; then
        yellow "sing-box 尚未安装！"; sleep 1; return
    fi

    clear; echo ""
    green "=== 修改节点参数配置 ===\n"
    green "1. 修改已启用协议的监听端口"
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
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice
    local inbounds_file="${conf_dir}/inbounds.json"
    load_meta

    case "${choice}" in
        1)
            echo ""
            green "1. vless-reality  2. hysteria2  3. tuic  4. vmess-argo  5. AnyTLS  6. Socks5  7. SS2022"
            reading "请选择要修改端口的协议编号 (1-7): " p_choice
            local target_tag="" proto_type="tcp" meta_key=""
            case "$p_choice" in
                1) target_tag="vless-reality"; proto_type="tcp"; meta_key="VLESS_PORT" ;;
                2) target_tag="hysteria2";     proto_type="udp"; meta_key="HY2_PORT" ;;
                3) target_tag="tuic";          proto_type="udp"; meta_key="TUIC_PORT" ;;
                4) target_tag="vmess-ws";      proto_type="tcp"; meta_key="VMESS_PORT" ;;
                5) target_tag="anytls";        proto_type="tcp"; meta_key="ANYTLS_PORT" ;;
                6) target_tag="socks5-in";     proto_type="both"; meta_key="SOCKS_PORT" ;;
                7) target_tag="shadowsocks-2022"; proto_type="both"; meta_key="SS_PORT" ;;
                *) return ;;
            esac
            if ! proto_exists "$target_tag"; then
                red "\n当前未启用 [$target_tag] 协议！\n"; return
            fi
            prompt_custom_port "$target_tag" "$(rand_port)"
            local new_port="$Selected_Port"
            jq --arg tag "$target_tag" --argjson port "$new_port" \
               '(.inbounds[] | select(.tag == $tag).listen_port) = $port' \
               "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
            save_meta "$meta_key" "$new_port"
            if [ "$proto_type" == "both" ]; then
                allow_port "${new_port}/tcp" "${new_port}/udp"
            else
                allow_port "${new_port}/${proto_type}"
            fi
            restart_singbox
            rebuild_urls
            check_nodes
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
            check_nodes
            ;;
        3)
            if ! proto_exists "vless-reality"; then
                red "\nvless-reality 未启用！\n"; return
            fi
            green "\n1. www.joom.com  2. www.stengg.com  3. www.wedgehr.com  4. www.cerebrium.ai  5. www.nazhumi.com"
            reading "请输入新的伪装域名或序号 (回车默认1): " new_sni
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
            check_nodes
            ;;
        4)
            if ! proto_exists "hysteria2"; then
                red "\nhysteria2 未启用！\n"; return
            fi
            reading "请输入跳跃起始端口 (回车默认 50000): " min_port
            min_port="${min_port:-50000}"
            reading "请输入跳跃结束端口 (回车默认 $((min_port + 100))): " max_port
            max_port="${max_port:-$((min_port + 100))}"
            local listen_port
            listen_port=$(jq -r '.inbounds[] | select(.tag == "hysteria2").listen_port' "$inbounds_file")
            command_exists iptables && iptables -t nat -A PREROUTING -p udp --dport "${min_port}:${max_port}" -j DNAT --to-destination ":${listen_port}" >/dev/null 2>&1
            command_exists ip6tables && ip6tables -t nat -A PREROUTING -p udp --dport "${min_port}:${max_port}" -j DNAT --to-destination ":${listen_port}" >/dev/null 2>&1
            save_meta "HY2_MPORT_MIN" "$min_port"
            save_meta "HY2_MPORT_MAX" "$max_port"
            rebuild_urls
            check_nodes
            ;;
        5)
            load_meta
            if [ -n "$HY2_MPORT_MIN" ] && [ -n "$HY2_MPORT_MAX" ]; then
                command_exists iptables && iptables -t nat -D PREROUTING -p udp --dport "${HY2_MPORT_MIN}:${HY2_MPORT_MAX}" -j DNAT --to-destination ":${HY2_PORT}" >/dev/null 2>&1 || true
                command_exists ip6tables && ip6tables -t nat -D PREROUTING -p udp --dport "${HY2_MPORT_MIN}:${HY2_MPORT_MAX}" -j DNAT --to-destination ":${HY2_PORT}" >/dev/null 2>&1 || true
            fi
            save_meta "HY2_MPORT_MIN" ""
            save_meta "HY2_MPORT_MAX" ""
            rebuild_urls
            check_nodes
            ;;
        6)
            green "1: cf.090227.xyz  2: cf.877774.xyz  3: cdns.doon.eu.org  4: time.is"
            reading "请输入优选序号(1-4)或自定义 域名:端口 (回车默认1): " cf_in
            local cfip="cf.090227.xyz" cfport="443"
            case "$cf_in" in
                ""|"1") cfip="cf.090227.xyz" ;;
                "2")    cfip="cf.877774.xyz" ;;
                "3")    cfip="cdns.doon.eu.org" ;;
                "4")    cfip="time.is" ;;
                *)
                    if [[ "$cf_in" =~ : ]]; then
                        cfip="${cf_in%%:*}"; cfport="${cf_in##*:}"
                    else
                        cfip="$cf_in"
                    fi
                    ;;
            esac
            save_meta "CFIP_SAVED" "$cfip"
            save_meta "CFPORT_SAVED" "$cfport"
            rebuild_urls
            check_nodes
            ;;
        0) return ;;
    esac
}

# =========================
# 服务管理、Argo管理、WARP分流
# =========================
manage_singbox() {
    clear; echo ""
    green "=== sing-box 服务管理 (状态: $(check_singbox)) ===\n"
    green "1. 启动   2. 停止   3. 重启   0. 返回"
    reading "请输入选择: " choice
    case "$choice" in
        1) start_singbox && green "已启动" ;;
        2) stop_singbox && yellow "已停止" ;;
        3) restart_singbox && green "已重启" ;;
    esac
}

manage_argo() {
    clear; echo ""
    green "=== Argo 隧道管理 (状态: $(check_argo)) ===\n"
    green "1. 启动 Argo   2. 停止 Argo   3. 重新获取临时域名   4. 配置固定隧道   0. 返回"
    reading "请输入选择: " choice
    load_meta
    local argo_p="${VMESS_PORT:-8001}"
    case "$choice" in
        1) ensure_argo_binary; start_argo ;;
        2) stop_argo ;;
        3) ensure_argo_binary; get_quick_tunnel; rebuild_urls; check_nodes ;;
        4)
            ensure_argo_binary
            reading "请输入 Argo 固定域名: " argo_domain
            reading "请输入 Argo Token: " argo_auth
            [ -z "$argo_domain" ] || [ -z "$argo_auth" ] && return
            save_meta "ARGO_DOMAIN" "$argo_domain"
            if command_exists rc-service; then
                sed -i "/^command_args=/c\command_args=\"-c '/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token $argo_auth > /etc/sing-box/argo.log 2>&1'\"" /etc/init.d/argo
            else
                sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token '"$argo_auth"' > /etc/sing-box/argo.log 2>&1"' /etc/systemd/system/argo.service
            fi
            restart_argo; sleep 2; rebuild_urls; check_nodes
            ;;
    esac
}

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
    local route_file="${conf_dir}/route.json"
    clear; echo ""
    green "=== WARP 分流管理 ===\n"
    green "1. 添加分流服务 (走WARP)   2. 清空分流恢复直连 (释放内存)   0. 返回"
    reading "请输入选择: " choice
    case "$choice" in
        1)
            green "1.OpenAI 2.Claude 3.Gemini 4.Google 5.Tiktok 6.Twitter 7.YouTube 8.Netflix 9.Telegram"
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
            green "已启用 ${r_tag} WARP分流！"
            ;;
        2)
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
            green "已清空分流规则并恢复服务器原IP直连！"
            ;;
    esac
}

# =========================
# 主菜单
# =========================
menu() {
    singbox_status=$(check_singbox 2>/dev/null)
    argo_status=$(check_argo 2>/dev/null)

    clear; echo ""
    purple "=== sing-box 64M极简管理面板 (快捷键: sb) ==="
    echo ""
    purple "sing-box 状态: ${singbox_status}   |   Argo 状态: ${argo_status}"
    echo "=========================================================="
    green "1. 安装 / 重装 sing-box (指定协议 + 指定端口 + 设v4/v6/双栈)"
    red   "2. 彻底卸载 sing-box 并恢复初始状态"
    echo "=========================================================="
    green "3. 查看节点 Base64 编码"
    green "4. 协议节点管理 (添加 / 恢复 / 删除指定协议)"
    green "5. 重新设置入站 IP 与监听模式 (IPv4 / IPv6 / 双栈 / 自定义IP)"
    green "6. 修改节点配置 (改端口 / UUID / Reality域名 / HY2跳跃)"
    echo "=========================================================="
    green "7. sing-box 服务管理"
    green "8. Argo 隧道管理"
    green "9. WARP 分流管理"
    echo "=========================================================="
    red   "0. 退出脚本"
    echo "=========================================================="
}

trap 'red "\n已退出脚本"; exit 0' INT

case "$1" in
    -c | --check)
        check_nodes
        exit 0
        ;;
    -u | --uninstall)
        perform_full_uninstall
        exit 0
        ;;
    -r | --restart)
        get_quick_tunnel
        rebuild_urls
        check_nodes
        exit 0
        ;;
    -h | --help)
        echo ""
        green "快捷键用法: sb [参数]"
        green "  sb          打开交互式管理菜单"
        green "  sb -c       直接输出节点 Base64 编码"
        green "  sb -r       刷新 Argo 临时域名并输出 Base64"
        green "  sb -u       直接彻底卸载并恢复初始状态"
        echo ""
        exit 0
        ;;
    *)
        while true; do
            menu
            reading "请输入选择 (0-9): " choice
            echo ""
            need_pause=true
            case "${choice}" in
                1)
                    if [ "$(check_service_raw sing-box)" == "running" ]; then
                        reading "检测到 sing-box 已在运行，是否覆盖重新安装并重设端口/协议？(y/n): " reinstall_yn
                        [[ ! "$reinstall_yn" =~ ^[yY]$ ]] && continue
                    fi
                    manage_packages install jq tar openssl lsof coreutils curl
                    install_singbox
                    if command_exists systemctl; then
                        main_systemd_services
                    elif command_exists rc-update; then
                        alpine_openrc_services
                    else
                        red "不支持的 init 系统"; exit 1
                    fi
                    bind_sb_shortcut
                    sleep 2
                    get_info
                    ;;
                2)  uninstall_singbox;       need_pause=false ;;
                3)  check_nodes;             need_pause=true ;;
                4)  manage_protocols;        need_pause=false ;;
                5)
                    configure_inbound_stack_and_ip
                    restart_singbox
                    rebuild_urls
                    check_nodes
                    need_pause=true
                    ;;
                6)  change_config;           need_pause=true ;;
                7)  manage_singbox;          need_pause=true ;;
                8)  manage_argo;             need_pause=true ;;
                9)  warp_manage;             need_pause=true ;;
                0)  exit 0 ;;
                *)  red "无效的选项，请输入 0-9"; need_pause=true ;;
            esac
            [ "$need_pause" = true ] && read -n 1 -s -r -p $'\033[1;91m按任意键返回主菜单...\033[0m'
        done
        ;;
esac
