#!/usr/bin/env bash
set -u

# 原始脚本地址
SB_SOURCE_URL="${SB_SOURCE_URL:-https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh}"

# 整合版自身的 raw 地址，创建快捷方式时会使用这个地址
SB_64M_URL="${SB_64M_URL:-https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box-64m.sh}"

# 构建目录使用磁盘，避免 /tmp 为 tmpfs 时占用内存
SB_BOOTSTRAP_DIR="${SB_BOOTSTRAP_DIR:-/var/tmp/sing-box-64m}"

umask 022
mkdir -p "$SB_BOOTSTRAP_DIR" || {
  echo "无法创建临时目录：$SB_BOOTSTRAP_DIR" >&2
  exit 1
}

die() {
  echo "sing-box 64M 优化脚本失败：$*" >&2
  exit 1
}

replace_range() {
  local src="$1"
  local dst="$2"
  local start="$3"
  local end="$4"
  local replacement="$5"

  grep -Fq -- "$start" "$src" || return 1
  grep -Fq -- "$end" "$src" || return 1

  awk \
    -v start="$start" \
    -v end="$end" \
    -v repl="$replacement" '
    {
      if (!skip && index($0, start)) {
        while ((getline line < repl) > 0) {
          print line
        }
        close(repl)
        skip=1
        next
      }

      if (skip) {
        if (index($0, end)) {
          skip=0
          print
        }
        next
      }

      print
    }
  ' "$src" > "$dst" || return 1

  mv -f "$dst" "$src"
}

insert_after_line() {
  local src="$1"
  local dst="$2"
  local needle="$3"
  local insert_file="$4"

  grep -Fq -- "$needle" "$src" || return 1

  awk \
    -v needle="$needle" \
    -v insert_file="$insert_file" '
    {
      print

      if ($0 == needle) {
        while ((getline line < insert_file) > 0) {
          print line
        }
        close(insert_file)
      }
    }
  ' "$src" > "$dst" || return 1

  mv -f "$dst" "$src"
}

UPSTREAM_FILE="$SB_BOOTSTRAP_DIR/sing-box.upstream.sh"
PATCHED_FILE="$SB_BOOTSTRAP_DIR/sing-box.64m.sh"
DOWNLOAD_FILE="${UPSTREAM_FILE}.part.$$"

rm -f "$DOWNLOAD_FILE"

wget \
  --no-check-certificate \
  --tries=3 \
  --timeout=20 \
  -qO "$DOWNLOAD_FILE" \
  "$SB_SOURCE_URL" || die "下载原始脚本失败"

[ -s "$DOWNLOAD_FILE" ] || die "原始脚本为空"

mv -f "$DOWNLOAD_FILE" "$UPSTREAM_FILE"
cp -f "$UPSTREAM_FILE" "$PATCHED_FILE"

[ -s "$PATCHED_FILE" ] || die "无法生成整合脚本"

# 将临时目录从 /tmp 改到磁盘目录
sed -i \
  -e 's|^TEMP_DIR=.*|TEMP_DIR="${SB_TEMP_DIR:-/var/lib/sing-box/.tmp}"|' \
  -e 's|xargs -P 50|xargs -P 1|g' \
  -e 's|worker_processes  auto;|worker_processes  1;|g' \
  -e 's|worker_connections  1024;|worker_connections  512;|g' \
  -e 's|keepalive_timeout  65;|keepalive_timeout  15;|g' \
  "$PATCHED_FILE"

# 让快捷方式 sb 指向整合版
SB_64M_URL_SED=$(printf '%s' "$SB_64M_URL" | sed 's/[&|]/\\&/g')

sed -i \
  "s|https://raw.githubusercontent.com/fscarmen/sing-box/main/sing-box.sh|${SB_64M_URL_SED}|g" \
  "$PATCHED_FILE"

PRELUDE_FILE="$SB_BOOTSTRAP_DIR/low-memory-prelude"
TMPDIR_FILE="$SB_BOOTSTRAP_DIR/tmpdir-export"
CALL_FILE="$SB_BOOTSTRAP_DIR/low-memory-call"

cat > "$PRELUDE_FILE" <<'EOF'
memory_total_kb() {
  awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null
}

low_memory_make_swap() {
  local swap_total_kb
  local swap_file
  local swap_dir
  local free_kb

  swap_total_kb=$(awk '/^SwapTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
  [[ "$swap_total_kb" =~ ^[0-9]+$ ]] || swap_total_kb=0

  # 已经有至少 256M swap 时不重复创建
  (( swap_total_kb >= 262144 )) && return 0

  command -v mkswap >/dev/null 2>&1 || return 1
  command -v swapon >/dev/null 2>&1 || return 1

  swap_file="${SB_SWAP_FILE:-/swapfile}"

  if [ -e "$swap_file" ] &&
     ! grep -qF -- "$swap_file" /proc/swaps 2>/dev/null; then
    swap_file="/var/lib/sing-box.swap"
  fi

  # 不覆盖用户已经存在的普通文件
  [ -e "$swap_file" ] &&
    grep -qF -- "$swap_file" /proc/swaps 2>/dev/null &&
    return 0

  [ -e "$swap_file" ] && return 1

  swap_dir="${swap_file%/*}"
  [ "$swap_dir" = "$swap_file" ] && swap_dir='/'

  mkdir -p "$swap_dir" 2>/dev/null || return 1

  free_kb=$(df -Pk "$swap_dir" 2>/dev/null | awk 'NR == 2 {print $4}')
  [[ "$free_kb" =~ ^[0-9]+$ ]] || return 1

  if (( free_kb < LOW_MEM_SWAP_MB * 1024 + 65536 )); then
    return 1
  fi

  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${LOW_MEM_SWAP_MB}M" "$swap_file" 2>/dev/null || {
      rm -f "$swap_file"
      dd if=/dev/zero \
        of="$swap_file" \
        bs=1M \
        count="$LOW_MEM_SWAP_MB" \
        >/dev/null 2>&1 || {
        rm -f "$swap_file"
        return 1
      }
    }
  else
    dd if=/dev/zero \
      of="$swap_file" \
      bs=1M \
      count="$LOW_MEM_SWAP_MB" \
      >/dev/null 2>&1 || {
      rm -f "$swap_file"
      return 1
    }
  fi

  chmod 600 "$swap_file" 2>/dev/null || {
    rm -f "$swap_file"
    return 1
  }

  mkswap "$swap_file" >/dev/null 2>&1 || {
    rm -f "$swap_file"
    return 1
  }

  swapon "$swap_file" >/dev/null 2>&1 || {
    rm -f "$swap_file"
    return 1
  }

  if [ -w /etc/fstab ]; then
    grep -qF -- "$swap_file none swap" /etc/fstab 2>/dev/null ||
      printf '%s none swap sw 0 0\n' "$swap_file" >> /etc/fstab
  fi

  if command -v sysctl >/dev/null 2>&1; then
    sysctl -w vm.swappiness=100 >/dev/null 2>&1 || true
    sysctl -w vm.vfs_cache_pressure=200 >/dev/null 2>&1 || true
  fi

  return 0
}

configure_low_memory() {
  [ "${IS_UNINSTALL:-}" = 'is_uninstall' ] && return 0

  local total_kb
  local unit
  local limit
  local dropin
  local conf

  total_kb=$(memory_total_kb)

  if [ "${SB_LOW_MEMORY:-0}" != '1' ]; then
    [[ "$total_kb" =~ ^[0-9]+$ ]] || return 0
    (( total_kb > 131072 )) && return 0
  fi

  LOW_MEMORY_MODE=1

  LOW_MEM_SWAP_MB="${SB_SWAP_MB:-512}"
  [[ "$LOW_MEM_SWAP_MB" =~ ^[0-9]+$ ]] || LOW_MEM_SWAP_MB=512
  (( LOW_MEM_SWAP_MB < 256 )) && LOW_MEM_SWAP_MB=256

  LOW_MEM_GOGC="${SB_GOGC:-50}"
  LOW_MEM_GODEBUG="${SB_GODEBUG:-madvdontneed=1}"

  if [[ "$total_kb" =~ ^[0-9]+$ ]] && (( total_kb <= 65536 )); then
    SINGBOX_GOMEMLIMIT="${SB_SINGBOX_GOMEMLIMIT:-32MiB}"
    ARGO_GOMEMLIMIT="${SB_ARGO_GOMEMLIMIT:-12MiB}"
  else
    SINGBOX_GOMEMLIMIT="${SB_SINGBOX_GOMEMLIMIT:-48MiB}"
    ARGO_GOMEMLIMIT="${SB_ARGO_GOMEMLIMIT:-16MiB}"
  fi

  export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-1}"
  export GOMEMLIMIT="$SINGBOX_GOMEMLIMIT"
  export GOGC="$LOW_MEM_GOGC"
  export GODEBUG="$LOW_MEM_GODEBUG"

  if [ -z "${LOW_MEMORY_CONFIGURED:-}" ]; then
    if command -v systemctl >/dev/null 2>&1 &&
       [ -d /run/systemd/system ]; then

      for unit in sing-box argo; do
        if [ "$unit" = 'sing-box' ]; then
          limit="$SINGBOX_GOMEMLIMIT"
        else
          limit="$ARGO_GOMEMLIMIT"
        fi

        dropin="/etc/systemd/system/${unit}.service.d"
        mkdir -p "$dropin" 2>/dev/null || continue

        cat > "${dropin}/10-low-memory.conf" <<EOF_MEMORY
[Service]
Environment=GOMEMLIMIT=${limit}
Environment=GOGC=${LOW_MEM_GOGC}
Environment=GODEBUG=${LOW_MEM_GODEBUG}
EOF_MEMORY
      done

      systemctl daemon-reload >/dev/null 2>&1 || true

    elif command -v rc-service >/dev/null 2>&1 ||
         [ -d /run/openrc ]; then

      mkdir -p /etc/conf.d 2>/dev/null || true

      for unit in sing-box argo; do
        if [ "$unit" = 'sing-box' ]; then
          limit="$SINGBOX_GOMEMLIMIT"
        else
          limit="$ARGO_GOMEMLIMIT"
        fi

        conf="/etc/conf.d/${unit}"
        touch "$conf" 2>/dev/null || continue

        if ! grep -q '^# sing-box-64m-memory$' "$conf" 2>/dev/null; then
          cat >> "$conf" <<EOF_MEMORY

# sing-box-64m-memory
export GOMEMLIMIT=${limit}
export GOGC=${LOW_MEM_GOGC}
export GODEBUG=${LOW_MEM_GODEBUG}
EOF_MEMORY
        fi
      done
    fi

    LOW_MEMORY_CONFIGURED=1
  fi

  if [ -z "${LOW_MEMORY_SWAP_DONE:-}" ] &&
     command -v mkswap >/dev/null 2>&1 &&
     command -v swapon >/dev/null 2>&1; then

    if low_memory_make_swap; then
      LOW_MEMORY_SWAP_DONE=1
    elif [ -z "${LOW_MEMORY_SWAP_WARNED:-}" ]; then
      echo "警告：无法启用 swap，内存不足时仍可能被 OOM killer 终止。" >&2
      LOW_MEMORY_SWAP_WARNED=1
    fi
  fi
}

download_atomic() {
  local url="$1"
  local dest="$2"
  local dir
  local part

  [ -s "$dest" ] && return 0

  dir="${dest%/*}"
  [ "$dir" = "$dest" ] && dir='.'

  mkdir -p "$dir" 2>/dev/null || return 1

  part="${dest}.part.$$"
  rm -f "$part"

  if wget \
      --no-check-certificate \
      --tries=2 \
      --timeout=10 \
      -qO "$part" \
      "$url" 2>/dev/null &&
     [ -s "$part" ]; then
    mv -f "$part" "$dest"
    return 0
  fi

  rm -f "$part"
  return 1
}
EOF

printf '%s\n' 'export TMPDIR="$TEMP_DIR"' > "$TMPDIR_FILE"
printf '%s\n' 'configure_low_memory' > "$CALL_FILE"

insert_after_line \
  "$PATCHED_FILE" \
  "${PATCHED_FILE}.new" \
  'export DEBIAN_FRONTEND=noninteractive' \
  "$PRELUDE_FILE" || die "无法插入低内存函数"

insert_after_line \
  "$PATCHED_FILE" \
  "${PATCHED_FILE}.new" \
  'mkdir -p "$TEMP_DIR"' \
  "$TMPDIR_FILE" || die "无法设置磁盘临时目录"

# 在 root 检查后执行一次，避免没有权限时创建 swap
insert_after_line \
  "$PATCHED_FILE" \
  "${PATCHED_FILE}.new" \
  'check_root' \
  "$CALL_FILE" || die "无法插入低内存初始化"

# 依赖安装后再次执行一次，兼容 mkswap 在依赖安装前不存在的系统
insert_after_line \
  "$PATCHED_FILE" \
  "${PATCHED_FILE}.new" \
  'check_dependencies' \
  "$CALL_FILE" || die "无法插入低内存二次初始化"

# 原脚本会并发下载三个订阅模板，改为顺序下载
TEMPLATE_REPLACEMENT="$SB_BOOTSTRAP_DIR/template-replacement"

cat > "$TEMPLATE_REPLACEMENT" <<'EOF'
  # 低内存模式下顺序下载订阅模板，避免多个 wget 同时占用内存
  if [ "$IS_UNINSTALL" != 'is_uninstall' ]; then
    download_atomic \
      "${GH_PROXY}${SUBSCRIBE_TEMPLATE}/clash" \
      "$TEMP_DIR/clash" || true

    download_atomic \
      "${GH_PROXY}${SUBSCRIBE_TEMPLATE}/clash2" \
      "$TEMP_DIR/clash2" || true

    download_atomic \
      "${GH_PROXY}${SUBSCRIBE_TEMPLATE}/sing-box" \
      "$TEMP_DIR/sing-box-template" || true
  fi
EOF

replace_range \
  "$PATCHED_FILE" \
  "${PATCHED_FILE}.new" \
  '  # 并发下载订阅模板' \
  '  # 如果有需要，后台静默下载 sing-box（卸载模式跳过）' \
  "$TEMPLATE_REPLACEMENT" || die "无法优化订阅模板下载"

# 原脚本会同时下载 sing-box、jq、qrencode 和 WARP 账户，改为顺序执行
SINGBOX_REPLACEMENT="$SB_BOOTSTRAP_DIR/singbox-replacement"

cat > "$SINGBOX_REPLACEMENT" <<'EOF'
    # 低内存模式下顺序下载所有组件
    local ONLINE
    local SB_DIR
    local SB_BIN
    local SB_ARCHIVE

    ONLINE=$(get_sing_box_version)
    SB_DIR="$TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH"
    SB_BIN="$SB_DIR/sing-box"
    SB_ARCHIVE="$TEMP_DIR/sing-box-$ONLINE-linux-$SING_BOX_ARCH.tar.gz"

    rm -rf "$SB_DIR"

    if download_atomic \
        "${GH_PROXY}https://github.com/SagerNet/sing-box/releases/download/v${ONLINE}/sing-box-${ONLINE}-linux-${SING_BOX_ARCH}.tar.gz" \
        "$SB_ARCHIVE"; then

      tar -xzf "$SB_ARCHIVE" \
        -C "$TEMP_DIR" \
        >/dev/null 2>&1 &&
      [ -s "$SB_BIN" ] &&
      mv -f "$SB_BIN" "$TEMP_DIR/sing-box" &&
      chmod +x "$TEMP_DIR/sing-box"
    fi

    rm -f "$SB_ARCHIVE"
    rm -rf "$SB_DIR"

    download_atomic \
      "${GH_PROXY}https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-${JQ_ARCH}" \
      "$TEMP_DIR/jq" &&
      chmod +x "$TEMP_DIR/jq" || true

    download_atomic \
      "${GH_PROXY}https://github.com/fscarmen/client_template/raw/main/qrencode-go/qrencode-go-linux-${QRENCODE_ARCH}" \
      "$TEMP_DIR/qrencode" &&
      chmod +x "$TEMP_DIR/qrencode" || true

    if [ "$IS_TUN" = 'is_tun' ]; then
      timeout 15 bash <(
        wget \
          -qO- \
          --timeout=5 \
          --tries=1 \
          "https://gitlab.com/fscarmen/warp/-/raw/main/api.sh"
      ) --register > "$TEMP_DIR/warp_account.json" 2>/dev/null || true
    fi
EOF

replace_range \
  "$PATCHED_FILE" \
  "${PATCHED_FILE}.new" \
  '    # 任务 1: 下载 sing-box' \
  '  elif [ "${STATUS[0]}" != "$(text 26)" ]; then' \
  "$SINGBOX_REPLACEMENT" || die "无法优化组件下载"

# cloudflared 也改为顺序下载
ARGO_REPLACEMENT="$SB_BOOTSTRAP_DIR/argo-replacement"

cat > "$ARGO_REPLACEMENT" <<'EOF'
  # 低内存模式下顺序下载 cloudflared
  if [[ "${STATUS[1]}" = "$(text 26)" ||
        "$NONINTERACTIVE_INSTALL" = 'noninteractive_install' ]] &&
     [ ! -s "${WORK_DIR}/cloudflared" ] &&
     [ "$IS_UNINSTALL" != 'is_uninstall' ]; then

    download_atomic \
      "${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARGO_ARCH}" \
      "$TEMP_DIR/cloudflared" &&
      chmod +x "$TEMP_DIR/cloudflared" || true
EOF

replace_range \
  "$PATCHED_FILE" \
  "${PATCHED_FILE}.new" \
  '  # 如果有需要，后台静默下载 cloudflared（卸载模式跳过）' \
  '  elif [ "${STATUS[1]}" != "$(text 26)" ]; then' \
  "$ARGO_REPLACEMENT" || die "无法优化 cloudflared 下载"

chmod 700 "$PATCHED_FILE"

if [ "${SB_MATERIALIZE:-0}" = '1' ]; then
  echo "整合后的完整脚本已经生成："
  echo "$PATCHED_FILE"
  exit 0
fi

exec bash "$PATCHED_FILE" "$@"