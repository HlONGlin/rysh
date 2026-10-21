#!/bin/sh

RYSH_VERSION="1.0.2"
RYSH_DIR="/etc/rysh"
NODE_DIR="$RYSH_DIR/nodes"
STATE_DIR="$RYSH_DIR/state"
HISTORY_DIR="$RYSH_DIR/history"
SETTINGS_FILE="$RYSH_DIR/settings.conf"
BLOCKED_FILE="$RYSH_DIR/blocked.ports"
TC_STATE_FILE="$RYSH_DIR/tc.state"
EVENT_LOG="$RYSH_DIR/events.log"
LOCK_DIR="/var/lock/rysh.lock"
MANAGED_MARK="$RYSH_DIR/.managed"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF="$XRAY_CONF_DIR/config.json"
XRAY_ASSET_DIR="/usr/local/share/xray"
XRAY_LOG_DIR="/var/log/xray"
API_ADDR="127.0.0.1:10085"
API_PORT="10085"
TC_CHAIN="1381589832"
TC_PREF_BASE="1"

if [ -t 1 ]; then
    C_RED=$(printf '\033[31m')
    C_GREEN=$(printf '\033[32m')
    C_YELLOW=$(printf '\033[33m')
    C_BLUE=$(printf '\033[34m')
    C_CYAN=$(printf '\033[36m')
    C_BOLD=$(printf '\033[1m')
    C_DIM=$(printf '\033[2m')
    C_NC=$(printf '\033[0m')
else
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_CYAN=""
    C_BOLD=""
    C_DIM=""
    C_NC=""
fi

msg() { printf '%s\n' "$*"; }
ok() { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_NC" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_NC" "$*"; }
err() { printf '%s[错误]%s %s\n' "$C_RED" "$C_NC" "$*" >&2; }
die() { err "$*"; exit 1; }

clear_screen() {
    clear 2>/dev/null || printf '\033[2J\033[H'
}

pause() {
    printf '%s按回车继续...%s' "$C_DIM" "$C_NC"
    read -r _ 2>/dev/null || true
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行此脚本"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

require_xray() {
    [ -x "$XRAY_BIN" ] || die "Xray 尚未安装，请先执行菜单 1"
}

sanitize_text() {
    printf '%s' "$1" | tr -d "'" | tr -d '\r' | tr -d '\n'
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_number() {
    printf '%s' "$1" | grep -Eq '^[0-9]+([.][0-9]+)?$'
}

is_zero_number() {
    awk -v v="$1" 'BEGIN{exit !(v+0==0)}'
}

to_int() {
    awk -v v="$1" 'BEGIN{printf "%.0f", v+0}'
}

ensure_dirs() {
    mkdir -p "$RYSH_DIR" "$NODE_DIR" "$STATE_DIR" "$HISTORY_DIR" "$XRAY_CONF_DIR" "$XRAY_ASSET_DIR" "$XRAY_LOG_DIR" 2>/dev/null
    chmod 700 "$RYSH_DIR" "$NODE_DIR" "$STATE_DIR" "$HISTORY_DIR" "$XRAY_CONF_DIR" 2>/dev/null
    chmod 755 "$XRAY_ASSET_DIR" "$XRAY_LOG_DIR" 2>/dev/null
}

load_settings() {
    PUBLIC_IP=""
    DEFAULT_SNI="www.amazon.com"
    DEFAULT_FLOW="xtls-rprx-vision"
    DEFAULT_FP="chrome"
    MONITOR_INTERVAL="1"
    IFACE=""
    DOWNLOAD_PROXY=""
    if [ -f "$SETTINGS_FILE" ]; then
        . "$SETTINGS_FILE"
    fi
    [ -n "$DEFAULT_SNI" ] || DEFAULT_SNI="www.amazon.com"
    [ -n "$DEFAULT_FLOW" ] || DEFAULT_FLOW="xtls-rprx-vision"
    [ -n "$DEFAULT_FP" ] || DEFAULT_FP="chrome"
    is_uint "$MONITOR_INTERVAL" || MONITOR_INTERVAL="1"
    MONITOR_INTERVAL=$(to_int "$MONITOR_INTERVAL")
    [ "$MONITOR_INTERVAL" -ge 1 ] 2>/dev/null || MONITOR_INTERVAL="1"
    [ "$MONITOR_INTERVAL" -le 59 ] 2>/dev/null || MONITOR_INTERVAL="1"
}

save_settings() {
    ensure_dirs
    tmp="$SETTINGS_FILE.tmp.$$"
    {
        printf "PUBLIC_IP='%s'\n" "$(sanitize_text "$PUBLIC_IP")"
        printf "DEFAULT_SNI='%s'\n" "$(sanitize_text "$DEFAULT_SNI")"
        printf "DEFAULT_FLOW='%s'\n" "$(sanitize_text "$DEFAULT_FLOW")"
        printf "DEFAULT_FP='%s'\n" "$(sanitize_text "$DEFAULT_FP")"
        printf "MONITOR_INTERVAL='%s'\n" "$MONITOR_INTERVAL"
        printf "IFACE='%s'\n" "$(sanitize_text "$IFACE")"
        printf "DOWNLOAD_PROXY='%s'\n" "$(sanitize_text "$DOWNLOAD_PROXY")"
    } > "$tmp" || return 1
    mv "$tmp" "$SETTINGS_FILE"
    chmod 600 "$SETTINGS_FILE"
}

log_event() {
    ensure_dirs
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$EVENT_LOG"
}

self_install() {
    src="$0"
    if [ -f "$src" ]; then
        abs=$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")
        if [ "$abs" != "/usr/local/bin/rysh" ]; then
            cp "$abs" /usr/local/bin/rysh 2>/dev/null && chmod 755 /usr/local/bin/rysh 2>/dev/null
        fi
    elif [ -x /usr/local/bin/rysh ]; then
        install_shortcut
        return 0
    fi
    [ -x /usr/local/bin/rysh ] || warn "请将脚本安装到 /usr/local/bin/rysh，否则定时任务无法运行"
    install_shortcut
}

install_shortcut() {
    [ -x /usr/local/bin/rysh ] || return 0
    if [ -e /usr/local/bin/ry ] || [ -L /usr/local/bin/ry ]; then
        target=$(readlink /usr/local/bin/ry 2>/dev/null)
        if [ "$target" = "/usr/local/bin/rysh" ]; then
            return 0
        fi
        if [ -f /usr/local/bin/ry ] && ! [ -L /usr/local/bin/ry ]; then
            warn "/usr/local/bin/ry 已存在且不是 rysh 的链接，跳过快捷命令创建"
            return 0
        fi
    fi
    ln -sf /usr/local/bin/rysh /usr/local/bin/ry 2>/dev/null && return 0
    cp /usr/local/bin/rysh /usr/local/bin/ry 2>/dev/null && chmod 755 /usr/local/bin/ry 2>/dev/null
}

remove_shortcut() {
    if [ -L /usr/local/bin/ry ]; then
        rm -f /usr/local/bin/ry
    elif [ -f /usr/local/bin/ry ]; then
        cmp -s /usr/local/bin/ry /usr/local/bin/rysh 2>/dev/null && rm -f /usr/local/bin/ry
    fi
}

ensure_deps() {
    missing=""
    for c in curl unzip jq nft tc ss openssl timeout; do
        need_cmd "$c" || missing="$missing $c"
    done
    if [ -n "$missing" ]; then
        msg "正在安装依赖:$missing"
        if need_cmd apk; then
            apk add --no-cache curl unzip jq nftables iptables iproute2 ca-certificates openssl coreutils >/dev/null 2>&1 || return 1
            need_cmd tc || apk add --no-cache iproute2-tc >/dev/null 2>&1 || true
            need_cmd ss || apk add --no-cache iproute2-ss >/dev/null 2>&1 || true
        elif need_cmd apt-get; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq curl unzip jq nftables iptables iproute2 ca-certificates cron openssl coreutils >/dev/null 2>&1 || {
                err "依赖安装失败，请检查网络或软件源"
                return 1
            }
        else
            err "依赖安装失败，请检查网络或软件源"
            return 1
        fi
    fi
    need_cmd jq || warn "jq 未安装，流量统计可能不可用"
    return 0
}

download() {
    url="$1"
    out="$2"
    if need_cmd curl; then
        curl -fL --retry 3 --connect-timeout 10 -o "$out" "$url"
    elif need_cmd wget; then
        wget -O "$out" "$url"
    else
        return 1
    fi
}

xray_arch() {
    m=$(uname -m)
    case "$m" in
        x86_64|amd64) printf '%s' "64" ;;
        aarch64|arm64) printf '%s' "arm64-v8a" ;;
        armv7l|armv7) printf '%s' "arm32-v7a" ;;
        armv6l) printf '%s' "arm32-v6" ;;
        i386|i686) printf '%s' "32" ;;
        s390x) printf '%s' "s390x" ;;
        *) printf '%s' "" ;;
    esac
}

create_xray_service() {
    cat > /etc/init.d/xray <<'SERVICE_EOF'
#!/sbin/openrc-run
name="xray"
description="Xray-core service"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/xray.pid"
depend() {
    need net
    after firewall
}
SERVICE_EOF
    chmod 755 /etc/init.d/xray
}

create_rysh_service() {
    cat > /etc/init.d/rysh <<'SERVICE_EOF'
#!/sbin/openrc-run
description="rysh policy service"
depend() {
    need net
    after firewall
    before xray
}
start() {
    ebegin "Applying rysh policy"
    /usr/local/bin/rysh apply --quiet
    eend $?
}
stop() {
    ebegin "Clearing rysh policy"
    /usr/local/bin/rysh clear --quiet
    eend $?
}
SERVICE_EOF
    chmod 755 /etc/init.d/rysh
}

openrc_active() {
    [ -d /run/openrc ] && need_cmd rc-service
}

systemd_active() {
    need_cmd systemctl && [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]
}

install_xray() {
    require_root
    self_install
    ensure_deps || return 1
    arch=$(xray_arch)
    [ -n "$arch" ] || die "不支持的 CPU 架构: $(uname -m)"
    ensure_dirs

    if [ -x "$XRAY_BIN" ]; then
        cur=$("$XRAY_BIN" version 2>/dev/null | head -n 1)
        msg "当前 Xray: $cur"
        if [ "${RYSH_ASSUME_YES:-0}" != "1" ]; then
            printf '是否更新到最新版本? [y/N]: '
            read -r ans 2>/dev/null || ans=""
            case "$ans" in
                y|Y|yes|YES) ;;
                *) return 0 ;;
            esac
        fi
    fi

    tmp=$(mktemp -d 2>/dev/null) || die "无法创建临时目录"
    if [ -n "${RYSH_XRAY_URL:-}" ]; then
        url="$RYSH_XRAY_URL"
    else
        url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
        if [ -n "$DOWNLOAD_PROXY" ]; then
            proxy="${DOWNLOAD_PROXY%/}"
            url="$proxy/$url"
        fi
    fi
    msg "下载 Xray: $url"
    if ! download "$url" "$tmp/xray.zip"; then
        rm -rf "$tmp"
        die "下载失败，可在全局设置中配置下载代理"
    fi
    if ! unzip -o "$tmp/xray.zip" -d "$tmp" >/dev/null 2>&1; then
        rm -rf "$tmp"
        die "解压失败"
    fi
    [ -f "$tmp/xray" ] || {
        rm -rf "$tmp"
        die "压缩包中未找到 xray 可执行文件"
    }

    candidate="$XRAY_BIN.new.$$"
    if ! cp "$tmp/xray" "$candidate" || ! chmod 755 "$candidate"; then
        rm -f "$candidate"
        rm -rf "$tmp"
        die "准备新版本 Xray 失败"
    fi
    if [ -x "$XRAY_BIN" ]; then
        cp "$XRAY_BIN" "$XRAY_BIN.bak" 2>/dev/null || true
    fi
    xray_stop
    if ! mv -f "$candidate" "$XRAY_BIN"; then
        rm -f "$candidate"
        [ -x "$XRAY_BIN.bak" ] && mv "$XRAY_BIN.bak" "$XRAY_BIN"
        xray_start
        rm -rf "$tmp"
        die "安装 xray 失败"
    fi
    [ -f "$tmp/geoip.dat" ] && cp "$tmp/geoip.dat" "$XRAY_ASSET_DIR/geoip.dat"
    [ -f "$tmp/geosite.dat" ] && cp "$tmp/geosite.dat" "$XRAY_ASSET_DIR/geosite.dat"
    rm -rf "$tmp"

    if ! "$XRAY_BIN" version >/dev/null 2>&1; then
        if [ -x "$XRAY_BIN.bak" ]; then
            restore="$XRAY_BIN.restore.$$"
            if cp "$XRAY_BIN.bak" "$restore" && chmod 755 "$restore"; then
                mv -f "$restore" "$XRAY_BIN"
            else
                rm -f "$restore"
                err "恢复旧版 Xray 失败，备份仍保留在 $XRAY_BIN.bak"
            fi
            xray_start
        fi
        die "Xray 无法运行，可能是架构不匹配"
    fi

    create_xray_service
    create_rysh_service
    mkdir -p "$XRAY_LOG_DIR"

    if [ -f "$XRAY_CONF" ] && [ ! -f "$MANAGED_MARK" ]; then
        cp "$XRAY_CONF" "$XRAY_CONF.pre-rysh.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        warn "检测到已有 Xray 配置，已备份，rysh 接管后将重新生成"
    fi
    touch "$MANAGED_MARK"

    if [ ! -f "$XRAY_CONF" ] || ! validate_config "$XRAY_CONF"; then
        [ -f "$XRAY_CONF" ] && warn "现有配置校验失败，尝试重新生成"
        tmp_cfg="$XRAY_CONF.tmp.$$.json"
        gen_config > "$tmp_cfg" || {
            rm -f "$tmp_cfg"
            die "生成默认配置失败"
        }
        if ! validate_config_verbose "$tmp_cfg"; then
            rm -f "$tmp_cfg"
            die "Xray 配置校验失败，请查看 $XRAY_LOG_DIR/error.log"
        fi
        chmod 600 "$tmp_cfg"
        if ! mv "$tmp_cfg" "$XRAY_CONF"; then
            rm -f "$tmp_cfg"
            die "写入 Xray 配置失败"
        fi
    fi

    if openrc_active; then
        rc-update add xray default >/dev/null 2>&1 || true
        rc-update add rysh default >/dev/null 2>&1 || true
    elif systemd_active; then
        create_systemd_services
        systemctl daemon-reload
        systemctl enable rysh.service xray.service >/dev/null 2>&1 || true
    fi
    xray_start
    if ! wait_xray_start; then
        err "Xray 启动失败，请查看 $XRAY_LOG_DIR/error.log"
        return 1
    fi
    install_cron
    [ -n "$(node_ids)" ] && apply_tc_all
    ok "Xray 安装完成: $("$XRAY_BIN" version 2>/dev/null | head -n 1)"
}

create_systemd_services() {
    cat > /etc/systemd/system/xray.service <<'SERVICE_EOF'
[Unit]
Description=Xray-core service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE_EOF
    cat > /etc/systemd/system/rysh.service <<'SERVICE_EOF'
[Unit]
Description=rysh network policy
After=network-online.target
Before=xray.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/rysh apply --quiet
ExecStop=/usr/local/bin/rysh clear --quiet

[Install]
WantedBy=multi-user.target
SERVICE_EOF
}

validate_config() {
    [ -x "$XRAY_BIN" ] || return 1
    "$XRAY_BIN" run -test -c "$1" >/dev/null 2>&1 && return 0
    "$XRAY_BIN" -test -c "$1" >/dev/null 2>&1 && return 0
    return 1
}

validate_config_verbose() {
    [ -x "$XRAY_BIN" ] || return 1
    out=$("$XRAY_BIN" run -test -c "$1" 2>&1) && return 0
    printf '%s\n' "$out" | grep -Ev '^(Xray |A unified platform|$)' >&2
    return 1
}

xray_start() {
    if systemd_active && [ -f /etc/systemd/system/xray.service ]; then
        systemctl start xray.service >/dev/null 2>&1 || true
        return 0
    fi
    if openrc_active && [ -x /etc/init.d/xray ]; then
        rc-service xray start >/dev/null 2>&1 || true
        return 0
    fi
    if [ -f /run/xray.pid ] && kill -0 "$(cat /run/xray.pid)" 2>/dev/null; then
        return 0
    fi
    [ -x "$XRAY_BIN" ] || return 1
    nohup "$XRAY_BIN" run -c "$XRAY_CONF" >>"$XRAY_LOG_DIR/stdout.log" 2>&1 &
    printf '%s' "$!" > /run/xray.pid
}

xray_stop() {
    if systemd_active && [ -f /etc/systemd/system/xray.service ]; then
        systemctl stop xray.service >/dev/null 2>&1 || true
        return 0
    fi
    if openrc_active && [ -x /etc/init.d/xray ]; then
        rc-service xray stop >/dev/null 2>&1 || true
        return 0
    fi
    if [ -f /run/xray.pid ]; then
        kill "$(cat /run/xray.pid)" 2>/dev/null || true
        rm -f /run/xray.pid
    fi
}

xray_restart() {
    xray_stop
    sleep 1
    xray_start
}

xray_running() {
    if systemd_active && [ -f /etc/systemd/system/xray.service ]; then
        systemctl is-active --quiet xray.service
        return $?
    fi
    if openrc_active && [ -x /etc/init.d/xray ]; then
        rc-service xray status >/dev/null 2>&1
        return $?
    fi
    [ -f /run/xray.pid ] && kill -0 "$(cat /run/xray.pid)" 2>/dev/null
}

wait_xray_start() {
    i=0
    while [ "$i" -lt 5 ]; do
        xray_running && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

xray_status_text() {
    if xray_running; then
        printf '运行中'
    else
        printf '未运行'
    fi
}

node_ids() {
    for f in "$NODE_DIR"/*.conf; do
        [ -f "$f" ] || continue
        b=${f##*/}
        b=${b%.conf}
        case "$b" in
            ''|*[!0-9]*) continue ;;
        esac
        printf '%s\n' "$b"
    done | sort -n
}

next_id() {
    max=0
    for id in $(node_ids); do
        [ "$id" -gt "$max" ] && max=$id
    done
    printf '%s' "$((max + 1))"
}

node_get_field() {
    f="$NODE_DIR/$1.conf"
    [ -f "$f" ] || return 1
    awk -F"'" -v k="$2" 'index($0, k"=") == 1 {print $2; exit}' "$f"
}

node_port_used() {
    p="$1"
    exclude="$2"
    for f in "$NODE_DIR"/*.conf; do
        [ -f "$f" ] || continue
        b=${f##*/}
        b=${b%.conf}
        [ "$b" = "$exclude" ] && continue
        v=$(awk -F"'" '/^N_PORT=/{print $2; exit}' "$f")
        [ "$v" = "$p" ] && return 0
    done
    return 1
}

port_listening() {
    p="$1"
    if need_cmd ss; then
        ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$p$"
        return $?
    fi
    if need_cmd netstat; then
        netstat -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$p$"
        return $?
    fi
    return 1
}

load_node() {
    N_ID=""
    N_NAME=""
    N_PORT=""
    N_PUBLIC_PORT=""
    N_UUID=""
    N_PRIV=""
    N_PUB=""
    N_SID=""
    N_SNI=""
    N_DEST=""
    N_FLOW=""
    N_FP=""
    N_ENABLED="1"
    N_CREATED=""
    N_EXPIRES="0"
    N_QUOTA_GB="0"
    N_RATE_MBPS="0"
    N_REMARK=""
    f="$NODE_DIR/$1.conf"
    [ -f "$f" ] || return 1
    . "$f"
    N_ID=${N_ID:-$1}
    N_NAME=${N_NAME:-节点$N_ID}
    N_PUBLIC_PORT=${N_PUBLIC_PORT:-$N_PORT}
    N_ENABLED=${N_ENABLED:-1}
    N_EXPIRES=${N_EXPIRES:-0}
    N_QUOTA_GB=${N_QUOTA_GB:-0}
    N_RATE_MBPS=${N_RATE_MBPS:-0}
    N_FLOW=${N_FLOW:-}
    N_FP=${N_FP:-chrome}
    return 0
}

save_node() {
    ensure_dirs
    tmp="$NODE_DIR/$N_ID.conf.tmp.$$"
    {
        printf "N_ID='%s'\n" "$N_ID"
        printf "N_NAME='%s'\n" "$(sanitize_text "$N_NAME")"
        printf "N_PORT='%s'\n" "$N_PORT"
        printf "N_PUBLIC_PORT='%s'\n" "${N_PUBLIC_PORT:-$N_PORT}"
        printf "N_UUID='%s'\n" "$N_UUID"
        printf "N_PRIV='%s'\n" "$N_PRIV"
        printf "N_PUB='%s'\n" "$N_PUB"
        printf "N_SID='%s'\n" "$N_SID"
        printf "N_SNI='%s'\n" "$N_SNI"
        printf "N_DEST='%s'\n" "$N_DEST"
        printf "N_FLOW='%s'\n" "$N_FLOW"
        printf "N_FP='%s'\n" "$N_FP"
        printf "N_ENABLED='%s'\n" "$N_ENABLED"
        printf "N_CREATED='%s'\n" "$N_CREATED"
        printf "N_EXPIRES='%s'\n" "$N_EXPIRES"
        printf "N_QUOTA_GB='%s'\n" "$N_QUOTA_GB"
        printf "N_RATE_MBPS='%s'\n" "$N_RATE_MBPS"
        printf "N_REMARK='%s'\n" "$(sanitize_text "$N_REMARK")"
    } > "$tmp" || return 1
    mv "$tmp" "$NODE_DIR/$N_ID.conf"
    chmod 600 "$NODE_DIR/$N_ID.conf"
}

load_state() {
    S_TOTAL_UP="0"
    S_TOTAL_DOWN="0"
    S_MONTH=""
    S_MONTH_UP="0"
    S_MONTH_DOWN="0"
    S_LAST_UP="0"
    S_LAST_DOWN="0"
    S_XRAY_GEN=""
    S_HAS_BASELINE="0"
    S_LEGACY_STATE="0"
    S_BLOCK_REASON=""
    f="$STATE_DIR/$1.state"
    [ -f "$f" ] || return 0
    grep -q '^S_HAS_BASELINE=' "$f" 2>/dev/null || S_LEGACY_STATE="1"
    . "$f"
    S_TOTAL_UP=${S_TOTAL_UP:-0}
    S_TOTAL_DOWN=${S_TOTAL_DOWN:-0}
    S_MONTH_UP=${S_MONTH_UP:-0}
    S_MONTH_DOWN=${S_MONTH_DOWN:-0}
    S_LAST_UP=${S_LAST_UP:-0}
    S_LAST_DOWN=${S_LAST_DOWN:-0}
    S_XRAY_GEN=${S_XRAY_GEN:-}
    S_HAS_BASELINE=${S_HAS_BASELINE:-0}
    S_LEGACY_STATE=${S_LEGACY_STATE:-0}
    S_BLOCK_REASON=${S_BLOCK_REASON:-}
}

save_state() {
    ensure_dirs
    tmp="$STATE_DIR/$N_ID.state.tmp.$$"
    {
        printf "S_TOTAL_UP='%s'\n" "$S_TOTAL_UP"
        printf "S_TOTAL_DOWN='%s'\n" "$S_TOTAL_DOWN"
        printf "S_MONTH='%s'\n" "$S_MONTH"
        printf "S_MONTH_UP='%s'\n" "$S_MONTH_UP"
        printf "S_MONTH_DOWN='%s'\n" "$S_MONTH_DOWN"
        printf "S_LAST_UP='%s'\n" "$S_LAST_UP"
        printf "S_LAST_DOWN='%s'\n" "$S_LAST_DOWN"
        printf "S_XRAY_GEN='%s'\n" "$S_XRAY_GEN"
        printf "S_HAS_BASELINE='%s'\n" "$S_HAS_BASELINE"
        printf "S_LEGACY_STATE='%s'\n" "$S_LEGACY_STATE"
        printf "S_BLOCK_REASON='%s'\n" "$(sanitize_text "$S_BLOCK_REASON")"
    } > "$tmp" || return 1
    mv "$tmp" "$STATE_DIR/$N_ID.state"
    chmod 600 "$STATE_DIR/$N_ID.state"
}

add_bytes() {
    awk -v a="$1" -v b="$2" 'BEGIN{printf "%.0f", (a+0)+(b+0)}'
}

month_used_bytes() {
    awk -v a="$S_MONTH_UP" -v b="$S_MONTH_DOWN" 'BEGIN{printf "%.0f", (a+0)+(b+0)}'
}

total_used_bytes() {
    awk -v a="$S_TOTAL_UP" -v b="$S_TOTAL_DOWN" 'BEGIN{printf "%.0f", (a+0)+(b+0)}'
}

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        split("B KB MB GB TB PB EB", u, " ")
        i=1
        b=b+0
        while (b>=1024 && i<7) { b/=1024; i++ }
        if (i==1) printf "%.0f %s", b, u[i]
        else printf "%.2f %s", b, u[i]
    }'
}

fmt_time() {
    e="${1:-0}"
    if ! is_uint "$e" || [ "$e" -le 0 ]; then
        printf '永久'
        return
    fi
    d=$(date -d "@$e" '+%Y-%m-%d %H:%M' 2>/dev/null)
    [ -n "$d" ] || d=$(epoch_to_date "$e")
    printf '%s' "$d"
}

date_to_epoch() {
    awk -v d="$1" 'BEGIN{
        split(d,a,"-")
        y=a[1]+0; m=a[2]+0; day=a[3]+0
        if (m<=2) { y--; m+=12 }
        A=int(y/100)
        B=2-A+int(A/4)
        jd=int(365.25*(y+4716))+int(30.6001*(m+1))+day+B-1524
        printf "%.0f", (jd-2440588)*86400
    }'
}

epoch_to_date() {
    awk -v e="$1" 'BEGIN{
        z=int(e/86400)+2440588
        if (z<2299161) A=z
        else {
            alpha=int((z-1867216.25)/36524.25)
            A=z+1+alpha-int(alpha/4)
        }
        B=A+1524
        C=int((B-122.1)/365.25)
        D=int(365.25*C)
        E=int((B-D)/30.6001)
        day=B-D-int(30.6001*E)
        if (E<14) month=E-1; else month=E-13
        if (month>2) year=C-4716; else year=C-4715
        printf "%04d-%02d-%02d", year, month, day
    }'
}

validate_sni() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' || return 1
    case "$1" in
        *.*) return 0 ;;
        *) return 1 ;;
    esac
}

validate_dest() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9.-]+:[0-9]{1,5}$' || return 1
    p=${1##*:}
    [ "$p" -ge 1 ] 2>/dev/null && [ "$p" -le 65535 ] 2>/dev/null
}

validate_date() {
    printf '%s' "$1" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || return 1
    m=${1#*-}
    m=${m%%-*}
    d=${1##*-}
    [ "$m" -ge 1 ] 2>/dev/null && [ "$m" -le 12 ] 2>/dev/null || return 1
    [ "$d" -ge 1 ] 2>/dev/null && [ "$d" -le 31 ] 2>/dev/null || return 1
    return 0
}

validate_new_port() {
    p="$1"
    is_uint "$p" || return 1
    p=$(to_int "$p")
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || return 1
    [ "$p" -eq "$API_PORT" ] && return 1
    node_port_used "$p" "" && return 1
    port_listening "$p" && return 1
    return 0
}

validate_change_port() {
    p="$1"
    id="$2"
    is_uint "$p" || return 1
    p=$(to_int "$p")
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || return 1
    [ "$p" -eq "$API_PORT" ] && return 1
    node_port_used "$p" "$id" && return 1
    old=$(node_get_field "$id" N_PORT)
    [ "$p" = "$old" ] && return 0
    port_listening "$p" && return 1
    return 0
}

is_port_free() {
    p="$1"
    is_uint "$p" || return 1
    p=$(to_int "$p")
    [ "$p" -eq "$API_PORT" ] && return 1
    node_port_used "$p" "" && return 1
    port_listening "$p" && return 1
    return 0
}

random_port() {
    tries=0
    while [ "$tries" -lt 200 ]; do
        r=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')
        [ -n "$r" ] || r=12345
        p=$((20000 + r % 40000))
        if is_port_free "$p"; then
            printf '%s' "$p"
            return 0
        fi
        tries=$((tries + 1))
    done
    p=20000
    while [ "$p" -le 60000 ]; do
        if is_port_free "$p"; then
            printf '%s' "$p"
            return 0
        fi
        p=$((p + 1))
    done
    return 1
}

gen_uuid() {
    if [ -x "$XRAY_BIN" ]; then
        u=$("$XRAY_BIN" uuid 2>/dev/null | tr -d '\r\n')
        [ -n "$u" ] && {
            printf '%s' "$u"
            return 0
        }
    fi
    cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '\r\n'
}

gen_keys() {
    [ -x "$XRAY_BIN" ] || return 1
    out=$("$XRAY_BIN" x25519 2>/dev/null)
    priv=$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')
    pub=$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /public/ {print $2; exit}')
    [ -n "$priv" ] && [ -n "$pub" ] || return 1
    printf '%s|%s' "$priv" "$pub"
}

gen_shortid() {
    od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
}

get_public_ip() {
    if [ -n "$PUBLIC_IP" ]; then
        printf '%s' "$PUBLIC_IP"
        return
    fi
    ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null)
    [ -n "$ip" ] || ip=$(curl -4 -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null)
    [ -n "$ip" ] || ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    printf '%s' "$ip"
}

urlencode() {
    printf '%s' "$1" | jq -sRr @uri 2>/dev/null || printf '%s' "$1"
}

build_link() {
    ip="${CACHED_IP:-$(get_public_ip)}"
    public_port="${N_PUBLIC_PORT:-$N_PORT}"
    enc=$(urlencode "$N_NAME")
    flow=""
    [ -n "$N_FLOW" ] && flow="&flow=$N_FLOW"
    fp="$N_FP"
    [ -n "$fp" ] || fp="chrome"
    printf 'vless://%s@%s:%s?encryption=none%s&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=tcp&headerType=none#%s\n' \
        "$N_UUID" "$ip" "$public_port" "$flow" "$N_SNI" "$fp" "$N_PUB" "$N_SID" "$enc"
}

gen_config() {
    ensure_dirs
    cat <<'JSON_HEAD'
{
  "log": {
    "loglevel": "warning",
    "error": "/var/log/xray/error.log"
  },
  "stats": {},
  "api": {
    "tag": "api",
    "services": ["StatsService"]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true
    }
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "tag": "api"
    }
JSON_HEAD

    for id in $(node_ids); do
        load_node "$id" || continue
        [ "$N_ENABLED" = "1" ] || continue
        printf '    ,\n'
        printf '    {\n'
        printf '      "listen": "0.0.0.0",\n'
        printf '      "port": %s,\n' "$N_PORT"
        printf '      "protocol": "vless",\n'
        printf '      "settings": {\n'
        printf '        "clients": [\n'
        printf '          {\n'
        printf '            "id": "%s",\n' "$N_UUID"
        if [ -n "$N_FLOW" ]; then
            printf '            "flow": "%s",\n' "$N_FLOW"
        fi
        printf '            "email": "n%s",\n' "$N_ID"
        printf '            "level": 0\n'
        printf '          }\n'
        printf '        ],\n'
        printf '        "decryption": "none"\n'
        printf '      },\n'
        printf '      "streamSettings": {\n'
        printf '        "network": "tcp",\n'
        printf '        "security": "reality",\n'
        printf '        "realitySettings": {\n'
        printf '          "show": false,\n'
        printf '          "dest": "%s",\n' "$N_DEST"
        printf '          "xver": 0,\n'
        printf '          "serverNames": ["%s"],\n' "$N_SNI"
        printf '          "privateKey": "%s",\n' "$N_PRIV"
        printf '          "shortIds": ["%s"]\n' "$N_SID"
        printf '        }\n'
        printf '      },\n'
        printf '      "sniffing": {\n'
        printf '        "enabled": true,\n'
        printf '        "destOverride": ["http", "tls", "quic"]\n'
        printf '      },\n'
        printf '      "tag": "rysh-%s"\n' "$N_ID"
        printf '    }\n'
    done

    cat <<'JSON_TAIL'
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      }
    ]
  }
}
JSON_TAIL
}

apply_config() {
    require_xray
    ensure_dirs
    if [ -f "$XRAY_CONF" ] && [ ! -f "$MANAGED_MARK" ]; then
        cp "$XRAY_CONF" "$XRAY_CONF.pre-rysh.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        warn "检测到非 rysh 管理的配置，已备份原文件"
    fi
    touch "$MANAGED_MARK"
    tmp="$XRAY_CONF.tmp.$$.json"
    if ! gen_config > "$tmp"; then
        rm -f "$tmp"
        err "生成配置失败"
        return 1
    fi
    if ! validate_config_verbose "$tmp"; then
        err "Xray 配置校验失败，已保留旧配置"
        rm -f "$tmp"
        return 1
    fi
    [ -f "$XRAY_CONF" ] && cp "$XRAY_CONF" "$XRAY_CONF.bak" 2>/dev/null
    if ! mv "$tmp" "$XRAY_CONF"; then
        rm -f "$tmp"
        err "写入 Xray 配置失败"
        return 1
    fi
    chmod 600 "$XRAY_CONF"
    xray_restart
    if ! wait_xray_start; then
        if [ -f "$XRAY_CONF.bak" ]; then
            cp "$XRAY_CONF.bak" "$XRAY_CONF"
            xray_restart
            wait_xray_start
        fi
        err "Xray 启动失败，已尝试恢复旧配置，请查看 $XRAY_LOG_DIR/error.log"
        return 1
    fi
    ok "配置已应用，Xray 已重启"
    return 0
}

stats_query() {
    if need_cmd timeout; then
        timeout 10 "$XRAY_BIN" api statsquery --server="$API_ADDR" -pattern "user>>>" 2>/dev/null
    else
        "$XRAY_BIN" api statsquery --server="$API_ADDR" -pattern "user>>>" 2>/dev/null
    fi
}

stats_query_user() {
    uid="$1"
    if need_cmd timeout; then
        timeout 10 "$XRAY_BIN" api statsquery --server="$API_ADDR" -pattern "user>>>n$uid>>>" 2>/dev/null
    else
        "$XRAY_BIN" api statsquery --server="$API_ADDR" -pattern "user>>>n$uid>>>" 2>/dev/null
    fi
}

stats_user_baseline() {
    uid="$1"
    json=$(stats_query_user "$uid") || return 1
    printf '%s' "$json" | jq -e . >/dev/null 2>&1 || return 1
    up=$(printf '%s' "$json" | jq -r --arg n "user>>>n$uid>>>traffic>>>uplink" '[.stat[]? | select(.name==$n) | .value][0] // 0' 2>/dev/null)
    down=$(printf '%s' "$json" | jq -r --arg n "user>>>n$uid>>>traffic>>>downlink" '[.stat[]? | select(.name==$n) | .value][0] // 0' 2>/dev/null)
    is_uint "$up" || up=0
    is_uint "$down" || down=0
    printf '%s %s\n' "$up" "$down"
}

reset_user_baseline() {
    uid="$1"
    baseline=$(stats_user_baseline "$uid") || return 1
    S_LAST_UP=${baseline%% *}
    S_LAST_DOWN=${baseline#* }
    S_XRAY_GEN=$(xray_generation 2>/dev/null)
    S_HAS_BASELINE="1"
    S_LEGACY_STATE="0"
}

xray_generation() {
    pid=$(cat /run/xray.pid 2>/dev/null)
    if ! is_uint "$pid" || ! kill -0 "$pid" 2>/dev/null; then
        pid=""
        if need_cmd pidof; then
            pid=$(pidof xray 2>/dev/null | awk '{print $1}')
        elif need_cmd pgrep; then
            pid=$(pgrep -xo xray 2>/dev/null)
        fi
    fi
    is_uint "$pid" || return 1
    [ -r "/proc/$pid/stat" ] || return 1
    start=$(awk '{sub(/^.*\) /, ""); print $20}' "/proc/$pid/stat" 2>/dev/null)
    [ -n "$start" ] || return 1
    printf '%s' "$start"
}

counter_delta() {
    current="$1"
    previous="$2"
    old_generation="$3"
    new_generation="$4"
    if [ -n "$old_generation" ] && [ -n "$new_generation" ] && [ "$old_generation" != "$new_generation" ]; then
        awk -v c="$current" 'BEGIN{printf "%.0f", c+0}'
    else
        awk -v c="$current" -v p="$previous" 'BEGIN{d=(c+0)-(p+0); if(d<0)d=c+0; printf "%.0f", d}'
    fi
}

get_stat() {
    f="$1"
    k="$2"
    awk -v k="$k" '$1==k {print $2; found=1; exit} END{if(!found) print 0}' "$f" 2>/dev/null
}

stat_exists() {
    f="$1"
    k="$2"
    awk -v k="$k" '$1==k {found=1; exit} END{exit !found}' "$f" 2>/dev/null
}

quota_exceeded() {
    [ -n "$N_QUOTA_GB" ] || return 1
    [ "$S_MONTH" = "$(date +%Y-%m)" ] || return 1
    used=$(month_used_bytes)
    awk -v u="$used" -v q="$N_QUOTA_GB" 'BEGIN{if (q+0 <= 0) exit 1; exit !(u >= q*1073741824)}'
}

node_status() {
    now=$(date +%s)
    if [ "$N_ENABLED" != "1" ]; then
        printf '已禁用'
        return
    fi
    if is_uint "$N_EXPIRES" && [ "$N_EXPIRES" -gt 0 ] && [ "$now" -ge "$N_EXPIRES" ]; then
        printf '已到期'
        return
    fi
    if quota_exceeded; then
        printf '超月限额'
        return
    fi
    if is_uint "$N_EXPIRES" && [ "$N_EXPIRES" -gt 0 ]; then
        remain=$(( (N_EXPIRES - now + 86399) / 86400 ))
        if [ "$remain" -le 7 ]; then
            printf '即将到期(%s天)' "$remain"
            return
        fi
    fi
    printf '正常'
}

status_color() {
    case "$1" in
        正常) printf '%s' "$C_GREEN" ;;
        即将到期*) printf '%s' "$C_YELLOW" ;;
        已禁用|已到期|超月限额) printf '%s' "$C_RED" ;;
        *) printf '%s' "$C_YELLOW" ;;
    esac
}

quota_progress() {
    quota="$N_QUOTA_GB"
    if is_zero_number "$quota"; then
        printf '不限'
        return
    fi
    used=$(month_used_bytes)
    awk -v u="$used" -v q="$quota" 'BEGIN {
        limit=q*1073741824
        pct=(limit>0)?int((u*100)/limit):0
        if(pct>100)pct=100
        printf "%s / %s GB (%d%%)", sprintf("%.2f",u/1073741824),q,pct
    }'
}

archive_month() {
    [ -n "$S_MONTH" ] || return 0
    mkdir -p "$HISTORY_DIR" 2>/dev/null
    printf '%s %s %s %s\n' "$N_ID" "$S_MONTH_UP" "$S_MONTH_DOWN" "$(month_used_bytes)" >> "$HISTORY_DIR/$S_MONTH.log"
}

acquire_lock() {
    mkdir -p /var/lock 2>/dev/null
    i=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            rm -rf "$LOCK_DIR"
            continue
        fi
        i=$((i + 1))
        if [ "$i" -ge 10 ]; then
            err "另一个任务正在运行，请稍后重试"
            return 1
        fi
        sleep 1
    done
    printf '%s' "$$" > "$LOCK_DIR/pid" 2>/dev/null
    LOCK_HELD=1
    return 0
}

release_lock() {
    [ "${LOCK_HELD:-0}" = "1" ] && rm -rf "$LOCK_DIR" 2>/dev/null
    LOCK_HELD=0
}

clear_iptables_policy() {
    need_cmd iptables || return 0
    iptables -F RYSH_IN 2>/dev/null || true
    iptables -F RYSH_OUT 2>/dev/null || true
    iptables -D INPUT -j RYSH_IN 2>/dev/null || true
    iptables -D OUTPUT -j RYSH_OUT 2>/dev/null || true
    iptables -X RYSH_IN 2>/dev/null || true
    iptables -X RYSH_OUT 2>/dev/null || true
}

apply_blocklist() {
    raw="$1"
    ports=$(printf '%s\n' "$raw" | tr ' ' '\n' | sed '/^$/d' | sort -nu | tr '\n' ' ' | sed 's/ $//')
    if [ -z "$ports" ]; then
        if need_cmd nft; then
            nft delete table inet rysh 2>/dev/null || true
        fi
        clear_iptables_policy
        : > "$BLOCKED_FILE"
        return 0
    fi
    old=$(cat "$BLOCKED_FILE" 2>/dev/null)
    [ "$ports" = "$old" ] && return 0

    clear_iptables_policy

    if need_cmd nft; then
        {
            printf 'table inet rysh {\n'
            printf '  chain input {\n'
            printf '    type filter hook input priority -200; policy accept;\n'
            for p in $ports; do
                printf '    tcp dport %s drop\n' "$p"
            done
            printf '  }\n'
            printf '  chain output {\n'
            printf '    type filter hook output priority -200; policy accept;\n'
            for p in $ports; do
                printf '    tcp sport %s drop\n' "$p"
            done
            printf '  }\n'
            printf '}\n'
        } > "$RYSH_DIR/blocked.nft"
        nft delete table inet rysh 2>/dev/null || true
        if nft -f "$RYSH_DIR/blocked.nft" 2>/dev/null; then
            printf '%s\n' "$ports" > "$BLOCKED_FILE"
            return 0
        fi
        warn "nftables 规则应用失败，尝试使用 iptables"
    fi

    if need_cmd iptables; then
        iptables -N RYSH_IN 2>/dev/null || true
        iptables -N RYSH_OUT 2>/dev/null || true
        iptables -C INPUT -j RYSH_IN 2>/dev/null || iptables -I INPUT -j RYSH_IN
        iptables -C OUTPUT -j RYSH_OUT 2>/dev/null || iptables -I OUTPUT -j RYSH_OUT
        for p in $ports; do
            iptables -A RYSH_IN -p tcp --dport "$p" -j DROP
            iptables -A RYSH_OUT -p tcp --sport "$p" -j DROP
        done
        printf '%s\n' "$ports" > "$BLOCKED_FILE"
        return 0
    fi

    err "未找到 nftables/iptables，无法自动封禁端口"
    return 1
}

tc_clear_owned() {
    need_cmd tc || return 1
    if [ -f "$TC_STATE_FILE" ]; then
        while read -r olddev oldid oldpref; do
            [ -n "$olddev" ] || continue
            if is_uint "$oldpref"; then
                tc filter del dev "$olddev" egress chain "$TC_CHAIN" pref "$oldpref" 2>/dev/null || true
                tc filter del dev "$olddev" ingress chain "$TC_CHAIN" pref "$oldpref" 2>/dev/null || true
            fi
            tc filter flush dev "$olddev" egress chain "$TC_CHAIN" 2>/dev/null || true
            tc filter flush dev "$olddev" ingress chain "$TC_CHAIN" 2>/dev/null || true
        done < "$TC_STATE_FILE"
    fi
    current="$IFACE"
    [ -n "$current" ] || current=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    if [ -n "$current" ]; then
        tc filter flush dev "$current" egress chain "$TC_CHAIN" 2>/dev/null || true
        tc filter flush dev "$current" ingress chain "$TC_CHAIN" 2>/dev/null || true
    fi
}

apply_tc_rules() {
    has_rate=0
    for id in $(node_ids); do
        en=$(node_get_field "$id" N_ENABLED)
        [ "$en" = "1" ] || continue
        r=$(node_get_field "$id" N_RATE_MBPS)
        [ -n "$r" ] && awk -v r="$r" 'BEGIN{exit !(r+0>0)}' && has_rate=1
    done
    if ! need_cmd tc; then
        if [ "$has_rate" -eq 1 ] || [ -s "$TC_STATE_FILE" ]; then
            warn "未安装 tc，无法应用限速 (apk add iproute2-tc)"
            return 1
        fi
        return 0
    fi
    ensure_dirs
    if [ "$has_rate" -eq 0 ]; then
        tc_clear_owned || true
        : > "$TC_STATE_FILE"
        return 0
    fi
    if ! need_cmd ip; then
        if [ "$has_rate" -eq 1 ]; then
            warn "未安装 ip 命令，无法应用限速"
            return 1
        fi
        return 0
    fi
    dev="$IFACE"
    [ -n "$dev" ] || dev=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    if [ -z "$dev" ]; then
        warn "无法检测默认网卡，请在全局设置中指定网卡"
        return 1
    fi

    if ! tc qdisc add dev "$dev" clsact 2>/dev/null; then
        tc qdisc show dev "$dev" | grep -q 'clsact' || {
            warn "无法创建 clsact qdisc，未应用限速"
            return 1
        }
    fi

    tc_clear_owned || true
    tc filter flush dev "$dev" egress chain "$TC_CHAIN" 2>/dev/null || true
    tc filter flush dev "$dev" ingress chain "$TC_CHAIN" 2>/dev/null || true

    state_tmp="$TC_STATE_FILE.tmp.$$"
    : > "$state_tmp"
    for id in $(node_ids); do
        load_node "$id" || continue
        [ "$N_ENABLED" = "1" ] || continue
        rate="$N_RATE_MBPS"
        [ -n "$rate" ] && [ "$rate" != "0" ] || continue
        kbit=$(awk -v m="$rate" 'BEGIN{printf "%d", m*1000}')
        [ "$kbit" -gt 0 ] 2>/dev/null || continue
        is_uint "$id" || continue
        pref=$((TC_PREF_BASE + id))
        [ "$pref" -le 65535 ] || {
            warn "节点 $id ID 超出 tc 优先级范围，未应用限速"
            continue
        }

        added=0
        if tc filter add dev "$dev" egress chain "$TC_CHAIN" protocol all pref "$pref" flower ip_proto tcp src_port "$N_PORT" action police rate "${kbit}kbit" burst 64k conform-exceed drop 2>/dev/null; then
            added=1
        elif tc filter add dev "$dev" egress chain "$TC_CHAIN" protocol ip pref "$pref" u32 match ip sport "$N_PORT" 0xffff police rate "${kbit}kbit" burst 64k conform-exceed drop 2>/dev/null; then
            added=1
        else
            warn "节点 $id egress 限速规则创建失败"
        fi

        if tc filter add dev "$dev" ingress chain "$TC_CHAIN" protocol all pref "$pref" flower ip_proto tcp dst_port "$N_PORT" action police rate "${kbit}kbit" burst 64k conform-exceed drop 2>/dev/null; then
            added=1
        elif tc filter add dev "$dev" ingress chain "$TC_CHAIN" protocol ip pref "$pref" u32 match ip dport "$N_PORT" 0xffff police rate "${kbit}kbit" burst 64k conform-exceed drop 2>/dev/null; then
            added=1
        else
            warn "节点 $id ingress 限速规则创建失败"
        fi
        if [ "$added" -eq 1 ]; then
            printf '%s %s %s\n' "$dev" "$id" "$pref" >> "$state_tmp"
        fi
    done
    mv "$state_tmp" "$TC_STATE_FILE"
    log_event "tc police rules applied on $dev"
    return 0
}

apply_tc_all() {
    acquire_lock || return 1
    apply_tc_rules "$@"
    rc=$?
    release_lock
    return "$rc"
}

clear_tc() {
    need_cmd tc || return 0
    tc_clear_owned || true
    : > "$TC_STATE_FILE"
}

clear_all() {
    if need_cmd nft; then
        nft delete table inet rysh 2>/dev/null || true
    fi
    clear_iptables_policy
    clear_tc
    : > "$BLOCKED_FILE"
}

monitor_run() {
    quiet=0
    [ "${1:-}" = "--quiet" ] && quiet=1
    require_root
    ensure_dirs
    if ! need_cmd jq; then
        err "缺少 jq，无法统计流量"
        return 1
    fi
    acquire_lock || return 1
    trap 'release_lock' EXIT INT TERM

    now=$(date +%s)
    month=$(date +%Y-%m)
    stats_file=$(mktemp 2>/dev/null) || stats_file="$RYSH_DIR/.stats.$$"
    stats_ok=0
    xray_gen_before=$(xray_generation 2>/dev/null)
    xray_gen="$xray_gen_before"
    if [ -x "$XRAY_BIN" ]; then
        if json=$(stats_query 0); then
            xray_gen_after=$(xray_generation 2>/dev/null)
            if [ -n "$xray_gen_before" ] && [ -n "$xray_gen_after" ] && [ "$xray_gen_before" != "$xray_gen_after" ]; then
                if json=$(stats_query 0); then
                    xray_gen=$(xray_generation 2>/dev/null)
                    [ -n "$xray_gen" ] || xray_gen="$xray_gen_after"
                    stats_ok=1
                fi
            else
                xray_gen="$xray_gen_after"
                [ -n "$xray_gen" ] || xray_gen="$xray_gen_before"
                stats_ok=1
            fi
            if [ "$stats_ok" -eq 1 ]; then
                printf '%s' "$json" | jq -r '.stat[]? | "\(.name) \(.value)"' > "$stats_file" 2>/dev/null || true
            fi
        fi
    fi
    [ -f "$stats_file" ] || : > "$stats_file"

    blocked=""
    events=""
    for id in $(node_ids); do
        load_node "$id" || continue
        load_state "$id"
        if [ "$S_MONTH" != "$month" ]; then
            archive_month
            S_MONTH="$month"
            S_MONTH_UP="0"
            S_MONTH_DOWN="0"
        fi
        if [ "$stats_ok" -eq 1 ]; then
            up_key="user>>>n$id>>>traffic>>>uplink"
            down_key="user>>>n$id>>>traffic>>>downlink"
            up_present=0
            down_present=0
            stat_exists "$stats_file" "$up_key" && up_present=1
            stat_exists "$stats_file" "$down_key" && down_present=1
            up=0
            down=0
            delta_up=0
            delta_down=0
            if [ "$up_present" -eq 1 ]; then
                up=$(get_stat "$stats_file" "$up_key")
                if [ "$S_HAS_BASELINE" = "1" ]; then
                    delta_up=$(counter_delta "$up" "$S_LAST_UP" "$S_XRAY_GEN" "$xray_gen")
                elif [ "$S_LEGACY_STATE" = "1" ]; then
                    delta_up=0
                else
                    delta_up=$(awk -v c="$up" 'BEGIN{printf "%.0f", c+0}')
                fi
            fi
            if [ "$down_present" -eq 1 ]; then
                down=$(get_stat "$stats_file" "$down_key")
                if [ "$S_HAS_BASELINE" = "1" ]; then
                    delta_down=$(counter_delta "$down" "$S_LAST_DOWN" "$S_XRAY_GEN" "$xray_gen")
                elif [ "$S_LEGACY_STATE" = "1" ]; then
                    delta_down=0
                else
                    delta_down=$(awk -v c="$down" 'BEGIN{printf "%.0f", c+0}')
                fi
            fi
            if [ "$up_present" -eq 1 ] || [ "$down_present" -eq 1 ]; then
                [ "$up_present" -eq 1 ] && S_LAST_UP=$(get_stat "$stats_file" "$up_key")
                [ "$down_present" -eq 1 ] && S_LAST_DOWN=$(get_stat "$stats_file" "$down_key")
                S_XRAY_GEN="$xray_gen"
                S_HAS_BASELINE="1"
                S_LEGACY_STATE="0"
            fi
            S_TOTAL_UP=$(add_bytes "$S_TOTAL_UP" "$delta_up")
            S_TOTAL_DOWN=$(add_bytes "$S_TOTAL_DOWN" "$delta_down")
            S_MONTH_UP=$(add_bytes "$S_MONTH_UP" "$delta_up")
            S_MONTH_DOWN=$(add_bytes "$S_MONTH_DOWN" "$delta_down")
        fi

        reason=""
        if [ "$N_ENABLED" = "1" ]; then
            if is_uint "$N_EXPIRES" && [ "$N_EXPIRES" -gt 0 ] && [ "$now" -ge "$N_EXPIRES" ]; then
                reason="到期"
            elif quota_exceeded; then
                reason="超月限额"
            fi
            [ -n "$reason" ] && blocked="$blocked $N_PORT"
        fi

        if [ "$reason" != "$S_BLOCK_REASON" ]; then
            if [ -n "$reason" ]; then
                log_event "node $id ($N_NAME) blocked: $reason"
                events="$events\n节点 $id ($N_NAME) 已封禁: $reason"
            elif [ -n "$S_BLOCK_REASON" ]; then
                log_event "node $id ($N_NAME) unblocked"
                events="$events\n节点 $id ($N_NAME) 已解封"
            fi
            S_BLOCK_REASON="$reason"
        fi
        save_state
    done

    apply_blocklist "$blocked"
    rm -f "$stats_file"
    release_lock
    trap - EXIT INT TERM

    if [ "$quiet" -eq 0 ] && [ -n "$events" ]; then
        printf '%b\n' "$events"
    fi
    return 0
}

prompt_default() {
    label="$1"
    def="$2"
    if [ -n "$def" ]; then
        printf '%s [%s]: ' "$label" "$def"
    else
        printf '%s: ' "$label"
    fi
    read -r REPLY 2>/dev/null || REPLY=""
    [ -z "$REPLY" ] && REPLY="$def"
}

ask_node_id() {
    ids=$(node_ids)
    if [ -z "$ids" ]; then
        warn "还没有节点"
        return 1
    fi
    printf '可用节点: '
    for n in $ids; do
        nm=$(node_get_field "$n" N_NAME)
        printf '%s(%s) ' "$n" "$nm"
    done
    printf '\n'
    prompt_default "节点 ID" ""
    NODE_INPUT=$(sanitize_text "$REPLY")
    [ -n "$NODE_INPUT" ] || return 1
    is_uint "$NODE_INPUT" && NODE_INPUT=$(to_int "$NODE_INPUT")
    return 0
}

new_node_record() {
    id=$(next_id)
    uuid=$(gen_uuid)
    [ -n "$uuid" ] || return 1
    keys=$(gen_keys) || return 1
    priv=${keys%%|*}
    pub=${keys#*|}
    sid=$(gen_shortid)
    [ -n "$sid" ] || return 1
    expires=0
    if is_uint "$9"; then
        days=$(to_int "$9")
        [ "$days" -gt 0 ] && expires=$(( $(date +%s) + days * 86400 ))
    fi
    N_ID="$id"
    N_NAME="$1"
    N_PORT="$2"
    N_PUBLIC_PORT="$2"
    N_UUID="$uuid"
    N_PRIV="$priv"
    N_PUB="$pub"
    N_SID="$sid"
    N_SNI="$3"
    N_DEST="$4"
    N_FLOW="$5"
    N_FP="$6"
    N_ENABLED="1"
    N_CREATED="$(date +%s)"
    N_EXPIRES="$expires"
    N_QUOTA_GB="$7"
    N_RATE_MBPS="$8"
    N_REMARK=""
    save_node || return 1
    printf '%s' "$id"
}

create_node() {
    require_xray
    prepare_node_sni
    id=$(next_id)
    name="节点$id"
    prompt_default "节点名称" "$name"
    name=$(sanitize_text "$REPLY")
    [ -n "$name" ] || name="节点$id"

    auto=$(random_port) || die "找不到空闲端口"
    prompt_default "端口" "$auto"
    port=$(sanitize_text "$REPLY")
    while ! validate_new_port "$port"; do
        warn "端口无效、被占用或是 API 端口"
        prompt_default "端口" "$auto"
        port=$(sanitize_text "$REPLY")
    done
    port=$(to_int "$port")

    prompt_default "面板外部映射端口 (直连填写同监听端口)" "$port"
    public_port=$(sanitize_text "$REPLY")
    while ! is_uint "$public_port" || [ "$(to_int "$public_port")" -lt 1 ] || [ "$(to_int "$public_port")" -gt 65535 ]; do
        warn "请输入 1-65535 之间的外部端口"
        prompt_default "面板外部映射端口" "$port"
        public_port=$(sanitize_text "$REPLY")
    done
    N_PUBLIC_PORT=$(to_int "$public_port")
    public_port="$N_PUBLIC_PORT"

    prompt_default "SNI (Reality 伪装域名)" "$DEFAULT_SNI"
    sni=$(sanitize_text "$REPLY")
    while ! validate_sni "$sni"; do
        warn "SNI 格式不正确"
        prompt_default "SNI (Reality 伪装域名)" "$DEFAULT_SNI"
        sni=$(sanitize_text "$REPLY")
    done

    dest="$sni:443"
    prompt_default "目标地址 (host:port)" "$dest"
    dest=$(sanitize_text "$REPLY")
    while ! validate_dest "$dest"; do
        warn "目标地址格式应为 host:port"
        prompt_default "目标地址 (host:port)" "$dest"
        dest=$(sanitize_text "$REPLY")
    done

    rate="0"
    quota="0"
    days="0"
    printf '是否现在设置限速/月限额/到期时间? [y/N]: '
    read -r adv 2>/dev/null || adv=""
    case "$adv" in
        y|Y)
            prompt_default "限速 Mbps (0=不限)" "0"
            rate=$(sanitize_text "$REPLY")
            while ! is_number "$rate"; do
                warn "请输入数字"
                prompt_default "限速 Mbps (0=不限)" "0"
                rate=$(sanitize_text "$REPLY")
            done
            prompt_default "月流量限额 GB (0=不限)" "0"
            quota=$(sanitize_text "$REPLY")
            while ! is_number "$quota"; do
                warn "请输入数字"
                prompt_default "月流量限额 GB (0=不限)" "0"
                quota=$(sanitize_text "$REPLY")
            done
            prompt_default "有效期天数 (0=永久)" "0"
            days=$(sanitize_text "$REPLY")
            while ! is_uint "$days"; do
                warn "请输入整数天数"
                prompt_default "有效期天数 (0=永久)" "0"
                days=$(sanitize_text "$REPLY")
            done
            ;;
    esac

    nid=$(new_node_record "$name" "$port" "$sni" "$dest" "$DEFAULT_FLOW" "$DEFAULT_FP" "$quota" "$rate" "$days") || die "创建节点失败"
    load_node "$nid"
    N_PUBLIC_PORT="$public_port"
    save_node || warn "节点已创建，但外部映射端口保存失败"
    if ! apply_config; then
        warn "节点已保存，但配置应用失败，请检查后重试"
        return 1
    fi
    apply_tc_all
    monitor_run --quiet
    log_event "created node $nid port $port"
    ok "节点 $nid 创建成功"
    load_node "$nid"
    CACHED_IP=$(get_public_ip)
    build_link
    unset CACHED_IP
}

batch_create() {
    require_xray
    prepare_node_sni
    prompt_default "创建数量" "3"
    count=$(sanitize_text "$REPLY")
    while ! is_uint "$count" || [ "$(to_int "$count")" -lt 1 ] || [ "$(to_int "$count")" -gt 100 ]; do
        warn "请输入 1-100 之间的整数"
        prompt_default "创建数量" "3"
        count=$(sanitize_text "$REPLY")
    done
    count=$(to_int "$count")

    prompt_default "名称前缀" "节点"
    prefix=$(sanitize_text "$REPLY")
    [ -n "$prefix" ] || prefix="节点"

    prompt_default "SNI (Reality 伪装域名)" "$DEFAULT_SNI"
    sni=$(sanitize_text "$REPLY")
    while ! validate_sni "$sni"; do
        warn "SNI 格式不正确"
        prompt_default "SNI (Reality 伪装域名)" "$DEFAULT_SNI"
        sni=$(sanitize_text "$REPLY")
    done

    dest="$sni:443"
    prompt_default "目标地址 (host:port)" "$dest"
    dest=$(sanitize_text "$REPLY")
    while ! validate_dest "$dest"; do
        warn "目标地址格式应为 host:port"
        prompt_default "目标地址 (host:port)" "$dest"
        dest=$(sanitize_text "$REPLY")
    done

    prompt_default "每个节点限速 Mbps (0=不限)" "0"
    rate=$(sanitize_text "$REPLY")
    while ! is_number "$rate"; do
        warn "请输入数字"
        prompt_default "每个节点限速 Mbps (0=不限)" "0"
        rate=$(sanitize_text "$REPLY")
    done

    prompt_default "每个节点月限额 GB (0=不限)" "0"
    quota=$(sanitize_text "$REPLY")
    while ! is_number "$quota"; do
        warn "请输入数字"
        prompt_default "每个节点月限额 GB (0=不限)" "0"
        quota=$(sanitize_text "$REPLY")
    done

    prompt_default "每个节点有效期天数 (0=永久)" "0"
    days=$(sanitize_text "$REPLY")
    while ! is_uint "$days"; do
        warn "请输入整数天数"
        prompt_default "每个节点有效期天数 (0=永久)" "0"
        days=$(sanitize_text "$REPLY")
    done

    i=0
    created=""
    while [ "$i" -lt "$count" ]; do
        port=$(random_port) || {
            warn "没有足够的空闲端口"
            break
        }
        nid=$(new_node_record "$prefix$((i + 1))" "$port" "$sni" "$dest" "$DEFAULT_FLOW" "$DEFAULT_FP" "$quota" "$rate" "$days") || {
            warn "第 $((i + 1)) 个节点创建失败"
            break
        }
        created="$created $nid"
        load_node "$nid"
        N_PUBLIC_PORT="$N_PORT"
        save_node || warn "节点 $nid 外部端口初始化失败"
        i=$((i + 1))
    done

    if [ -z "$created" ]; then
        err "没有创建任何节点"
        return 1
    fi
    if ! apply_config; then
        warn "节点已保存，但配置应用失败，请检查后重试"
        return 1
    fi
    apply_tc_all
    monitor_run --quiet
    ok "已创建节点:$created"
    CACHED_IP=$(get_public_ip)
    for nid in $created; do
        load_node "$nid"
        printf '[%s] %s\n%s\n\n' "$N_ID" "$N_NAME" "$(build_link)"
    done
    unset CACHED_IP
}

show_node_detail() {
    load_node "$1" || return 1
    load_state "$1"
    printf 'ID       : %s\n' "$N_ID"
    printf '名称     : %s\n' "$N_NAME"
    printf '监听端口 : %s\n' "$N_PORT"
    [ "$N_PUBLIC_PORT" = "$N_PORT" ] || printf '外部端口 : %s (面板映射)\n' "$N_PUBLIC_PORT"
    printf '状态     : %s\n' "$(node_status)"
    printf 'SNI      : %s\n' "$N_SNI"
    printf '目标     : %s\n' "$N_DEST"
    printf '流控     : %s\n' "$([ -n "$N_FLOW" ] && printf '%s' "$N_FLOW" || printf '无')"
    printf '指纹     : %s\n' "$N_FP"
    printf 'UUID     : %s\n' "$N_UUID"
    printf '公钥     : %s\n' "$N_PUB"
    printf 'ShortID  : %s\n' "$N_SID"
    printf '本月流量 : %s\n' "$(human_bytes "$(month_used_bytes)")"
    printf '总流量   : %s\n' "$(human_bytes "$(total_used_bytes)")"
    if is_zero_number "$N_QUOTA_GB"; then
        printf '月限额   : 不限\n'
    else
        printf '月限额   : %s GB\n' "$N_QUOTA_GB"
    fi
    printf '到期时间 : %s\n' "$(fmt_time "$N_EXPIRES")"
    if is_zero_number "$N_RATE_MBPS"; then
        printf '限速     : 不限\n'
    else
        printf '限速     : %s Mbps\n' "$N_RATE_MBPS"
    fi
    printf '备注     : %s\n' "$N_REMARK"
}

show_nodes() {
    ids=$(node_ids)
    if [ -z "$ids" ]; then
        warn "还没有节点，请先创建"
        return 0
    fi
    printf '%-4s %-18s %-7s %-7s %-10s %-24s %-12s %s\n' 'ID' '名称' '监听' '外部' '状态' '本月用量 / 限额' '总流量' '到期'
    printf '%s\n' '-----------------------------------------------------------------------------------------------'
    for id in $ids; do
        load_node "$id" || continue
        load_state "$id"
        state=$(node_status)
        color=$(status_color "$state")
        printf '%-4s %-18.18s %-7s %-7s %s%-10s%s %-24s %-12s %s\n' \
            "$id" "$N_NAME" "$N_PORT" "$N_PUBLIC_PORT" "$color" "$state" "$C_NC" \
            "$(quota_progress)" "$(human_bytes "$(total_used_bytes)")" "$(fmt_time "$N_EXPIRES")"
    done
    printf '\n图例: %s正常%s  %s即将到期%s  %s已禁用/已到期/超月限额%s\n' \
        "$C_GREEN" "$C_NC" "$C_YELLOW" "$C_NC" "$C_RED" "$C_NC"
}

show_link_menu() {
    ask_node_id || return 1
    id="$NODE_INPUT"
    load_node "$id" || {
        err "节点不存在"
        return 1
    }
    CACHED_IP=$(get_public_ip)
    link=$(build_link)
    printf '\n%s\n\n' "$link"
    if need_cmd qrencode; then
        qrencode -t ANSIUTF8 "$link" 2>/dev/null || true
    else
        printf '是否安装 qrencode 显示二维码? [y/N]: '
        read -r ans 2>/dev/null || ans=""
        case "$ans" in
            y|Y)
                if ! need_cmd qrencode && need_cmd apk; then
                    apk add --no-cache qrencode >/dev/null 2>&1 || warn "二维码安装失败"
                elif ! need_cmd qrencode && need_cmd apt-get; then
                    apt-get install -y -qq qrencode >/dev/null 2>&1 || warn "二维码安装失败"
                fi
                if need_cmd qrencode; then
                    qrencode -t ANSIUTF8 "$link" 2>/dev/null || warn "二维码生成失败"
                else
                    warn "请手动安装 qrencode 后重试"
                fi
                ;;
        esac
    fi
    unset CACHED_IP
}

export_links() {
    ids=$(node_ids)
    if [ -z "$ids" ]; then
        warn "还没有节点"
        return 0
    fi
    CACHED_IP=$(get_public_ip)
    out="$RYSH_DIR/links.txt"
    : > "$out"
    for id in $ids; do
        load_node "$id" || continue
        build_link >> "$out"
    done
    unset CACHED_IP
    base64 "$out" 2>/dev/null > "$RYSH_DIR/subscription.txt" || true
    chmod 600 "$out" "$RYSH_DIR/subscription.txt" 2>/dev/null
    ok "节点链接已导出: $out"
    [ -s "$RYSH_DIR/subscription.txt" ] && ok "Base64 订阅已生成: $RYSH_DIR/subscription.txt"
}

modify_node() {
    require_xray
    ask_node_id || return 1
    id="$NODE_INPUT"
    load_node "$id" || {
        err "节点不存在"
        return 1
    }
    while :; do
        clear_screen
        show_node_detail "$id"
        printf '\n'
        printf ' 1. 修改名称        2. 修改监听端口\n'
        printf ' 3. 修改 SNI/目标   4. 修改流控\n'
        printf ' 5. 修改指纹        6. 重置 UUID\n'
        printf ' 7. 重置 Reality 密钥  8. 修改备注\n'
        printf ' 9. 查看节点链接   10. 修改外部映射端口\n'
        printf ' 0. 返回\n'
        printf '请选择: '
        read -r c 2>/dev/null || c=""
        case "$c" in
            1)
                prompt_default "新名称" "$N_NAME"
                N_NAME=$(sanitize_text "$REPLY")
                [ -n "$N_NAME" ] || N_NAME="节点$N_ID"
                save_node
                ok "名称已修改"
                ;;
            2)
                prompt_default "新监听端口" "$N_PORT"
                p=$(sanitize_text "$REPLY")
                while ! validate_change_port "$p" "$id"; do
                    warn "端口无效、被占用或是 API 端口"
                    prompt_default "新端口" "$N_PORT"
                    p=$(sanitize_text "$REPLY")
                done
                old_port="$N_PORT"
                N_PORT=$(to_int "$p")
                [ "$N_PUBLIC_PORT" = "$old_port" ] && N_PUBLIC_PORT="$N_PORT"
                save_node
                apply_config || true
                apply_tc_all
                monitor_run --quiet
                ;;
            3)
                prompt_default "新 SNI" "$N_SNI"
                s=$(sanitize_text "$REPLY")
                while ! validate_sni "$s"; do
                    warn "SNI 格式不正确"
                    prompt_default "新 SNI" "$N_SNI"
                    s=$(sanitize_text "$REPLY")
                done
                prompt_default "新目标地址" "$s:443"
                d=$(sanitize_text "$REPLY")
                while ! validate_dest "$d"; do
                    warn "目标地址格式应为 host:port"
                    prompt_default "新目标地址" "$s:443"
                    d=$(sanitize_text "$REPLY")
                done
                N_SNI="$s"
                N_DEST="$d"
                save_node
                apply_config || true
                ;;
            4)
                prompt_default "新流控 (留空表示无)" "$N_FLOW"
                f=$(sanitize_text "$REPLY")
                case "$f" in
                    ''|xtls-rprx-vision) ;;
                    *) warn "仅支持 xtls-rprx-vision 或留空"; f="$N_FLOW" ;;
                esac
                N_FLOW="$f"
                save_node
                apply_config || true
                ;;
            5)
                prompt_default "新指纹" "$N_FP"
                v=$(sanitize_text "$REPLY")
                if printf '%s' "$v" | grep -Eq '^[A-Za-z0-9-]+$'; then
                    N_FP="$v"
                    save_node
                    ok "指纹已修改，客户端链接会变化"
                else
                    warn "指纹格式不正确"
                fi
                ;;
            6)
                printf '确认重置 UUID? 客户端需要更新链接 [y/N]: '
                read -r a 2>/dev/null || a=""
                case "$a" in
                    y|Y)
                        N_UUID=$(gen_uuid)
                        [ -n "$N_UUID" ] || {
                            err "生成 UUID 失败"
                            continue
                        }
                        save_node
                        apply_config || true
                        CACHED_IP=$(get_public_ip)
                        printf '\n%s\n' "$(build_link)"
                        unset CACHED_IP
                        ;;
                esac
                ;;
            7)
                printf '确认重置 Reality 密钥? 客户端需要更新链接 [y/N]: '
                read -r a 2>/dev/null || a=""
                case "$a" in
                    y|Y)
                        keys=$(gen_keys) || {
                            err "生成密钥失败"
                            continue
                        }
                        N_PRIV=${keys%%|*}
                        N_PUB=${keys#*|}
                        save_node
                        apply_config || true
                        CACHED_IP=$(get_public_ip)
                        printf '\n%s\n' "$(build_link)"
                        unset CACHED_IP
                        ;;
                esac
                ;;
            8)
                prompt_default "备注" "$N_REMARK"
                N_REMARK=$(sanitize_text "$REPLY")
                save_node
                ok "备注已保存"
                ;;
            9)
                CACHED_IP=$(get_public_ip)
                printf '\n%s\n\n' "$(build_link)"
                unset CACHED_IP
                ;;
            10)
                prompt_default "外部映射端口" "$N_PUBLIC_PORT"
                p=$(sanitize_text "$REPLY")
                if is_uint "$p" && [ "$(to_int "$p")" -ge 1 ] && [ "$(to_int "$p")" -le 65535 ]; then
                    N_PUBLIC_PORT=$(to_int "$p")
                    save_node || warn "外部端口保存失败"
                    ok "外部端口已更新，客户端链接已按新端口生成"
                    CACHED_IP=$(get_public_ip)
                    printf '%s\n' "$(build_link)"
                    unset CACHED_IP
                else
                    warn "请输入 1-65535 之间的端口"
                fi
                ;;
            0) return 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
        pause
        load_node "$id" || return 1
    done
}

delete_node() {
    ask_node_id || return 1
    id="$NODE_INPUT"
    load_node "$id" || {
        err "节点不存在"
        return 1
    }
    show_node_detail "$id"
    printf '确认删除节点 %s? 此操作不可恢复 [y/N]: ' "$id"
    read -r a 2>/dev/null || a=""
    case "$a" in
        y|Y) ;;
        *) return 0 ;;
    esac
    load_state "$id"
    archive_month
    rm -f "$NODE_DIR/$id.conf" "$STATE_DIR/$id.state"
    log_event "deleted node $id"
    apply_config || true
    apply_tc_all
    monitor_run --quiet
    ok "节点 $id 已删除"
}

toggle_node() {
    ask_node_id || return 1
    id="$NODE_INPUT"
    load_node "$id" || {
        err "节点不存在"
        return 1
    }
    if [ "$N_ENABLED" = "1" ]; then
        N_ENABLED="0"
        msg "节点 $id 已禁用"
    else
        N_ENABLED="1"
        msg "节点 $id 已启用"
    fi
    save_node
    apply_config || true
    apply_tc_all
    monitor_run
}

reset_traffic_menu() {
    ask_node_id || return 1
    id="$NODE_INPUT"
    load_node "$id" || {
        err "节点不存在"
        return 1
    }
    load_state "$id"
    printf '当前本月流量: %s\n当前总流量: %s\n' "$(human_bytes "$(month_used_bytes)")" "$(human_bytes "$(total_used_bytes)")"
    printf '1. 重置本月流量\n2. 重置本月和总流量\n0. 返回\n请选择: '
    read -r c 2>/dev/null || c=""
    case "$c" in
        1)
            acquire_lock || return 1
            if xray_running; then
                if ! reset_user_baseline "$id"; then
                    release_lock
                    err "无法读取 Xray 用户统计，未重置流量"
                    return 1
                fi
            else
                S_LAST_UP="0"
                S_LAST_DOWN="0"
                S_XRAY_GEN=""
                S_HAS_BASELINE="1"
            fi
            S_MONTH_UP="0"
            S_MONTH_DOWN="0"
            save_state
            release_lock
            monitor_run
            ok "节点 $id 本月流量已重置"
            ;;
        2)
            acquire_lock || return 1
            if xray_running; then
                if ! reset_user_baseline "$id"; then
                    release_lock
                    err "无法读取 Xray 用户统计，未重置流量"
                    return 1
                fi
            else
                S_LAST_UP="0"
                S_LAST_DOWN="0"
                S_XRAY_GEN=""
                S_HAS_BASELINE="1"
            fi
            S_TOTAL_UP="0"
            S_TOTAL_DOWN="0"
            S_MONTH_UP="0"
            S_MONTH_DOWN="0"
            save_state
            release_lock
            monitor_run
            ok "节点 $id 全部流量已重置"
            ;;
        0) return 0 ;;
        *) warn "无效选项" ;;
    esac
}

set_quota_menu() {
    ask_node_id || return 1
    id="$NODE_INPUT"
    load_node "$id" || {
        err "节点不存在"
        return 1
    }
    prompt_default "月流量限额 GB (0=不限)" "$N_QUOTA_GB"
    q=$(sanitize_text "$REPLY")
    while ! is_number "$q"; do
        warn "请输入数字"
        prompt_default "月流量限额 GB (0=不限)" "$N_QUOTA_GB"
        q=$(sanitize_text "$REPLY")
    done
    N_QUOTA_GB="$q"
    save_node
    monitor_run
    ok "节点 $id 月限额已设置为 $N_QUOTA_GB GB"
}

set_expiry_menu() {
    ask_node_id || return 1
    id="$NODE_INPUT"
    load_node "$id" || {
        err "节点不存在"
        return 1
    }
    printf '当前到期时间: %s\n' "$(fmt_time "$N_EXPIRES")"
    printf '1. 设置剩余天数\n2. 设置到期日期\n3. 取消到期限制\n0. 返回\n请选择: '
    read -r c 2>/dev/null || c=""
    case "$c" in
        1)
            prompt_default "剩余天数" "30"
            d=$(sanitize_text "$REPLY")
            while ! is_uint "$d" || [ "$(to_int "$d")" -lt 1 ]; do
                warn "请输入大于 0 的整数"
                prompt_default "剩余天数" "30"
                d=$(sanitize_text "$REPLY")
            done
            d=$(to_int "$d")
            N_EXPIRES=$(( $(date +%s) + d * 86400 ))
            save_node
            monitor_run
            ok "节点 $id 到期时间: $(fmt_time "$N_EXPIRES")"
            ;;
        2)
            prompt_default "到期日期 (YYYY-MM-DD)" "$(date +%Y-%m-%d)"
            d=$(sanitize_text "$REPLY")
            while ! validate_date "$d"; do
                warn "日期格式不正确"
                prompt_default "到期日期 (YYYY-MM-DD)" "$(date +%Y-%m-%d)"
                d=$(sanitize_text "$REPLY")
            done
            e=$(date -d "$d 00:00:00" +%s 2>/dev/null)
            [ -n "$e" ] || e=$(date_to_epoch "$d")
            N_EXPIRES="$e"
            save_node
            monitor_run
            ok "节点 $id 到期时间: $(fmt_time "$N_EXPIRES")"
            ;;
        3)
            N_EXPIRES="0"
            save_node
            monitor_run
            ok "节点 $id 已取消到期限制"
            ;;
        0) return 0 ;;
        *) warn "无效选项" ;;
    esac
}

set_rate_menu() {
    ask_node_id || return 1
    id="$NODE_INPUT"
    load_node "$id" || {
        err "节点不存在"
        return 1
    }
    prompt_default "限速 Mbps (0=不限)" "$N_RATE_MBPS"
    r=$(sanitize_text "$REPLY")
    while ! is_number "$r"; do
        warn "请输入数字"
        prompt_default "限速 Mbps (0=不限)" "$N_RATE_MBPS"
        r=$(sanitize_text "$REPLY")
    done
    N_RATE_MBPS="$r"
    save_node
    if apply_tc_all; then
        ok "节点 $id 限速已设置为 $N_RATE_MBPS Mbps"
    else
        warn "限速已保存，但规则应用失败"
    fi
}

live_monitor() {
    require_root
    require_xray
    ensure_deps
    monitor_run --quiet
    ids=$(node_ids)
    [ -n "$ids" ] || {
        warn "还没有节点"
        return 0
    }
    tmpdir=$(mktemp -d 2>/dev/null) || tmpdir="$RYSH_DIR/.live.$$"
    mkdir -p "$tmpdir"
    for id in $ids; do
        printf '0' > "$tmpdir/$id.up"
        printf '0' > "$tmpdir/$id.down"
    done
    RUN=1
    trap 'RUN=0' INT TERM
    first=1
    while [ "$RUN" -eq 1 ]; do
        stats_file="$tmpdir/.stats"
        if ! json=$(stats_query 0); then
            clear_screen
            printf '%s流量 API 不可用，请确认 Xray 正在运行且已应用 rysh 配置%s\n' "$C_RED" "$C_NC"
            sleep 2
            continue
        fi
        printf '%s' "$json" | jq -r '.stat[]? | "\(.name) \(.value)"' > "$stats_file" 2>/dev/null || : > "$stats_file"
        clear_screen
        printf '%s实时流量监控%s  (Ctrl+C 退出)  %s\n\n' "$C_BOLD" "$C_NC" "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '%-4s %-16s %-6s %-14s %-14s %-14s\n' "ID" "名称" "端口" "上传/秒" "下载/秒" "本月/总计"
        for id in $ids; do
            load_node "$id" || continue
            load_state "$id"
            cu=$(get_stat "$stats_file" "user>>>n$id>>>traffic>>>uplink")
            cd=$(get_stat "$stats_file" "user>>>n$id>>>traffic>>>downlink")
            pu=$(cat "$tmpdir/$id.up" 2>/dev/null)
            pd=$(cat "$tmpdir/$id.down" 2>/dev/null)
            if [ "$first" -eq 1 ]; then
                ru=0
                rd=0
            else
                du=$(awk -v c="$cu" -v p="$pu" 'BEGIN{d=c-p; if(d<0)d=0; printf "%.0f", d}')
                dd=$(awk -v c="$cd" -v p="$pd" 'BEGIN{d=c-p; if(d<0)d=0; printf "%.0f", d}')
                ru=$(awk -v d="$du" 'BEGIN{printf "%.0f", d/2}')
                rd=$(awk -v d="$dd" 'BEGIN{printf "%.0f", d/2}')
            fi
            printf '%s' "$cu" > "$tmpdir/$id.up"
            printf '%s' "$cd" > "$tmpdir/$id.down"
            printf '%-4s %-16s %-6s %-14s %-14s %s\n' \
                "$id" "$N_NAME" "$N_PORT" "$(human_bytes "$ru")/s" "$(human_bytes "$rd")/s" \
                "$(human_bytes "$(month_used_bytes)")/$(human_bytes "$(total_used_bytes)")"
        done
        first=0
        sleep 2
    done
    trap - INT TERM
    rm -rf "$tmpdir"
    printf '\n'
}

show_report() {
    month=$(date +%Y-%m)
    printf '%s本月流量统计 (%s)%s\n\n' "$C_BOLD" "$month" "$C_NC"
    ids=$(node_ids)
    if [ -n "$ids" ]; then
        for id in $ids; do
            load_node "$id" || continue
            load_state "$id"
            printf '[%s] %-16s 上行 %s  下行 %s  合计 %s\n' \
                "$id" "$N_NAME" "$(human_bytes "$S_MONTH_UP")" "$(human_bytes "$S_MONTH_DOWN")" "$(human_bytes "$(month_used_bytes)")"
        done
    else
        printf '暂无节点\n'
    fi
    printf '\n%s历史月份%s\n\n' "$C_BOLD" "$C_NC"
    found=0
    for f in $(ls -1 "$HISTORY_DIR"/*.log 2>/dev/null | tail -n 6); do
        [ -f "$f" ] || continue
        found=1
        m=${f##*/}
        m=${m%.log}
        printf '%s:\n' "$m"
        while read -r nid up down total; do
            [ -n "$nid" ] || continue
            printf '  节点 %-4s 上行 %s  下行 %s  合计 %s\n' "$nid" "$(human_bytes "$up")" "$(human_bytes "$down")" "$(human_bytes "$total")"
        done < "$f"
    done
    [ "$found" -eq 0 ] && printf '暂无历史记录\n'
}

apply_all() {
    require_xray
    apply_config || return 1
    apply_tc_all
    monitor_run
    ok "所有规则已应用"
}

xray_control_menu() {
    while :; do
        clear_screen
        printf '%sXray 控制%s  当前状态: %s\n\n' "$C_BOLD" "$C_NC" "$(xray_status_text)"
        printf '1. 启动\n2. 停止\n3. 重启\n4. 查看状态\n0. 返回\n请选择: '
        read -r c 2>/dev/null || c=""
        case "$c" in
            1)
                if xray_start && wait_xray_start; then
                    ok "Xray 已启动"
                else
                    err "Xray 启动失败，请查看 $XRAY_LOG_DIR/error.log"
                fi
                ;;
            2)
                if xray_stop && ! xray_running; then
                    ok "Xray 已停止"
                else
                    err "Xray 停止失败，请检查服务状态"
                fi
                ;;
            3)
                if xray_restart && wait_xray_start; then
                    ok "Xray 已重启"
                else
                    err "Xray 重启失败，请查看 $XRAY_LOG_DIR/error.log"
                fi
                ;;
            4) xray_status_log ;;
            0) return 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
        pause
    done
}

xray_status_log() {
    if [ -x "$XRAY_BIN" ]; then
        printf 'Xray 版本: %s\n' "$("$XRAY_BIN" version 2>/dev/null | head -n 1)"
    else
        printf 'Xray 版本: 未安装\n'
    fi
        printf '运行状态: %s\n' "$(xray_status_text)"
    if openrc_active; then
        printf '服务状态: %s\n' "$(rc-service xray status 2>&1 | head -n 1)"
    elif systemd_active; then
        printf '服务状态: %s\n' "$(systemctl is-active xray.service 2>/dev/null || true)"
    fi
    printf '\n%s最近错误日志%s\n' "$C_BOLD" "$C_NC"
    tail -n 30 "$XRAY_LOG_DIR/error.log" 2>/dev/null || printf '暂无日志\n'
    printf '\n%s最近事件日志%s\n' "$C_BOLD" "$C_NC"
    tail -n 20 "$EVENT_LOG" 2>/dev/null || printf '暂无事件\n'
}

install_cron() {
    [ -n "$MONITOR_INTERVAL" ] || MONITOR_INTERVAL="1"
    if systemd_active; then
        current=$(crontab -l 2>/dev/null || true)
        updated=$(printf '%s\n' "$current" | grep -v 'rysh monitor' || true)
        updated=$(printf '%s\n%s' "$updated" "*/$MONITOR_INTERVAL * * * * /usr/local/bin/rysh monitor --quiet >/dev/null 2>&1")
        printf '%s\n' "$updated" | crontab -
        systemctl enable --now cron.service >/dev/null 2>&1 || systemctl enable --now crond.service >/dev/null 2>&1 || true
        ok "监控定时任务已安装 (每 $MONITOR_INTERVAL 分钟)"
        return 0
    fi
    [ -d /etc/crontabs ] || mkdir -p /etc/crontabs
    touch /etc/crontabs/root
    self_install
    tmp=$(mktemp 2>/dev/null) || tmp="/etc/crontabs/root.tmp.$$"
    grep -v 'rysh monitor' /etc/crontabs/root > "$tmp" 2>/dev/null || true
    printf '*/%s * * * * /usr/local/bin/rysh monitor --quiet >/dev/null 2>&1\n' "$MONITOR_INTERVAL" >> "$tmp"
    mv "$tmp" /etc/crontabs/root
    chmod 600 /etc/crontabs/root
    if openrc_active; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond restart >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || true
    fi
    ok "监控定时任务已安装 (每 $MONITOR_INTERVAL 分钟)"
}

remove_cron() {
    if systemd_active; then
        crontab -l 2>/dev/null | grep -v 'rysh monitor' | crontab - 2>/dev/null || true
        return 0
    fi
    [ -f /etc/crontabs/root ] || return 0
    tmp=$(mktemp 2>/dev/null) || tmp="/etc/crontabs/root.tmp.$$"
    grep -v 'rysh monitor' /etc/crontabs/root > "$tmp" 2>/dev/null || true
    mv "$tmp" /etc/crontabs/root
    chmod 600 /etc/crontabs/root
    if openrc_active; then
        rc-service crond restart >/dev/null 2>&1 || true
    fi
}

global_settings_menu() {
    while :; do
        clear_screen
        printf '%s全局设置%s\n\n' "$C_BOLD" "$C_NC"
        printf '1. 公网 IP/域名      : %s\n' "$([ -n "$PUBLIC_IP" ] && printf '%s' "$PUBLIC_IP" || printf '自动检测')"
        printf '2. 默认 SNI          : %s\n' "$DEFAULT_SNI"
        printf '3. 默认流控          : %s\n' "$DEFAULT_FLOW"
        printf '4. 默认指纹          : %s\n' "$DEFAULT_FP"
        printf '5. 监控间隔(分钟)    : %s\n' "$MONITOR_INTERVAL"
        printf '6. 限速网卡          : %s\n' "$([ -n "$IFACE" ] && printf '%s' "$IFACE" || printf '自动检测')"
        printf '7. 下载代理          : %s\n' "$([ -n "$DOWNLOAD_PROXY" ] && printf '%s' "$DOWNLOAD_PROXY" || printf '未设置')"
        printf '0. 返回\n请选择: '
        read -r c 2>/dev/null || c=""
        case "$c" in
            1)
                prompt_default "公网 IP/域名 (留空自动检测)" "$PUBLIC_IP"
                PUBLIC_IP=$(sanitize_text "$REPLY")
                save_settings
                ok "已保存"
                ;;
            2)
                prompt_default "默认 SNI" "$DEFAULT_SNI"
                v=$(sanitize_text "$REPLY")
                if validate_sni "$v"; then
                    DEFAULT_SNI="$v"
                    save_settings
                    ok "已保存"
                else
                    warn "SNI 格式不正确"
                fi
                ;;
            3)
                prompt_default "默认流控 (留空表示无)" "$DEFAULT_FLOW"
                v=$(sanitize_text "$REPLY")
                case "$v" in
                    ''|xtls-rprx-vision)
                        DEFAULT_FLOW="$v"
                        save_settings
                        ok "已保存"
                        ;;
                    *) warn "仅支持 xtls-rprx-vision 或留空" ;;
                esac
                ;;
            4)
                prompt_default "默认指纹" "$DEFAULT_FP"
                v=$(sanitize_text "$REPLY")
                if printf '%s' "$v" | grep -Eq '^[A-Za-z0-9-]+$'; then
                    DEFAULT_FP="$v"
                    save_settings
                    ok "已保存"
                else
                    warn "指纹格式不正确"
                fi
                ;;
            5)
                prompt_default "监控间隔(分钟, 1-59)" "$MONITOR_INTERVAL"
                v=$(sanitize_text "$REPLY")
                if is_uint "$v" && [ "$(to_int "$v")" -ge 1 ] && [ "$(to_int "$v")" -le 59 ]; then
                    MONITOR_INTERVAL=$(to_int "$v")
                    save_settings
                    install_cron
                else
                    warn "请输入 1-59 之间的整数"
                fi
                ;;
            6)
                prompt_default "限速网卡 (留空自动检测)" "$IFACE"
                IFACE=$(sanitize_text "$REPLY")
                save_settings
                apply_tc_all
                ok "已保存"
                ;;
            7)
                prompt_default "下载代理 (例如 https://ghproxy.com)" "$DOWNLOAD_PROXY"
                DOWNLOAD_PROXY=$(sanitize_text "$REPLY")
                save_settings
                ok "已保存"
                ;;
            0) return 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
        pause
    done
}

backup_config() {
    ensure_dirs
    ts=$(date +%Y%m%d-%H%M%S)
    out="/root/rysh-backup-$ts.tar.gz"
    list=$(mktemp 2>/dev/null) || list="$RYSH_DIR/.backup.list.$$"
    : > "$list"
    for p in etc/rysh usr/local/etc/xray/config.json etc/init.d/xray etc/init.d/rysh etc/crontabs/root; do
        [ -e "/$p" ] && printf '%s\n' "$p" >> "$list"
    done
    if tar czf "$out" -C / -T "$list" 2>/dev/null; then
        rm -f "$list"
        chmod 600 "$out"
        ok "备份完成: $out"
        return 0
    fi
    rm -f "$list"
    err "备份失败"
    return 1
}

restore_config() {
    files=$(ls -1 /root/rysh-backup-*.tar.gz 2>/dev/null)
    if [ -z "$files" ]; then
        warn "没有找到备份文件"
        return 0
    fi
    printf '可用备份:\n%s\n\n' "$files"
    prompt_default "备份文件路径" "$(printf '%s\n' "$files" | tail -n 1)"
    f=$(sanitize_text "$REPLY")
    [ -f "$f" ] || {
        err "备份文件不存在"
        return 1
    }
    printf '确认恢复 %s? 当前配置会被覆盖 [y/N]: ' "$f"
    read -r a 2>/dev/null || a=""
    case "$a" in
        y|Y) ;;
        *) return 0 ;;
    esac
    if ! tar xzf "$f" -C / 2>/dev/null; then
        err "恢复失败"
        return 1
    fi
    load_settings
    if validate_config "$XRAY_CONF"; then
        xray_restart
    else
        warn "恢复后的 Xray 配置校验失败，请检查"
    fi
    apply_tc_all
    monitor_run --quiet
    ok "恢复完成"
}

backup_menu() {
    while :; do
        clear_screen
        printf '%s备份/恢复%s\n\n' "$C_BOLD" "$C_NC"
        printf '1. 备份当前配置\n2. 恢复配置\n3. 查看备份列表\n0. 返回\n请选择: '
        read -r c 2>/dev/null || c=""
        case "$c" in
            1) backup_config; pause ;;
            2) restore_config; pause ;;
            3) ls -lh /root/rysh-backup-*.tar.gz 2>/dev/null || warn "暂无备份"; pause ;;
            0) return 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

system_info() {
    printf '%s系统信息%s\n\n' "$C_BOLD" "$C_NC"
    printf '系统版本 : %s\n' "$(cat /etc/alpine-release 2>/dev/null || uname -s)"
    printf '内核     : %s\n' "$(uname -r)"
    printf '架构     : %s\n' "$(uname -m)"
    printf '公网 IP  : %s\n' "$(get_public_ip)"
    if [ -x "$XRAY_BIN" ]; then
        printf 'Xray     : %s\n' "$("$XRAY_BIN" version 2>/dev/null | head -n 1)"
    else
        printf 'Xray     : 未安装\n'
    fi
    printf 'Xray状态 : %s\n' "$(xray_status_text)"
    printf '节点数量 : %s\n' "$(node_ids | wc -l | tr -d ' ')"
    if systemd_active; then
        cron_count=$(crontab -l 2>/dev/null | grep -c 'rysh monitor')
    else
        cron_count=$(grep -c 'rysh monitor' /etc/crontabs/root 2>/dev/null)
    fi
    [ -n "$cron_count" ] || cron_count=0
    printf '监控任务 : %s\n' "$cron_count"
    printf '磁盘 /   : %s\n' "$(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')"
    printf 'inode /  : %s\n' "$(df -i / 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')"
    if need_cmd free; then
        printf '内存     : %s\n' "$(free -h 2>/dev/null | awk '/^Mem:/{print $3" / "$2}')"
    fi
    printf 'init     : %s\n' "$(if systemd_active; then printf 'systemd'; elif openrc_active; then printf 'OpenRC'; else printf '未知/容器'; fi)"
    printf '\n%s依赖检查%s\n\n' "$C_BOLD" "$C_NC"
    for c in curl wget unzip jq nft tc ss iptables qrencode openssl timeout; do
        if need_cmd "$c"; then
            printf '  %s[OK]%s %s\n' "$C_GREEN" "$C_NC" "$c"
        else
            printf '  %s[--]%s %s\n' "$C_YELLOW" "$C_NC" "$c"
        fi
    done
}

test_nodes() {
    ids=$(node_ids)
    if [ -z "$ids" ]; then
        warn "还没有节点"
        return 0
    fi
    for id in $ids; do
        load_node "$id" || continue
        load_state "$id"
        if port_listening "$N_PORT"; then
            local_status="本地监听正常"
        else
            local_status="本地未监听"
        fi
        printf '[%s] %s 内部 %s -> 外部 %s | 状态 %s | %s\n' \
            "$id" "$N_NAME" "$N_PORT" "$N_PUBLIC_PORT" "$(node_status)" "$local_status"
    done
    printf '\n外部端口映射无法从实例内部可靠确认。请从另一台设备测试公网地址:外部端口，并确认面板 TCP 映射目标为本机监听端口。\n'
}

nat_diagnostics() {
    printf '%sNAT VPS 部署检查%s\n\n' "$C_BOLD" "$C_NC"
    printf '公网地址 : %s\n' "$(get_public_ip)"
    printf '本机地址 : %s\n' "$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i==\"src\"){print $(i+1); exit}}')"
    printf '默认路由 : %s\n' "$(ip route show default 2>/dev/null | head -n 1)"
    printf '服务管理 : %s\n' "$(if systemd_active; then printf 'systemd'; elif openrc_active; then printf 'OpenRC'; else printf '非标准 init/容器'; fi)"
    printf 'Xray 状态: %s\n' "$(xray_status_text)"
    printf 'SSH 监听 : '
    if need_cmd ss; then
        ssh_listeners=$(ss -lnt 2>/dev/null | awk 'NR>1 && $4 ~ /:22$/ {print $4}')
        [ -n "$ssh_listeners" ] && printf '%s\n' "$ssh_listeners" || printf '未发现 TCP/22 监听\n'
    else
        printf '缺少 ss，无法检查\n'
    fi
    printf '\n节点端口检查:\n'
    ids=$(node_ids)
    if [ -z "$ids" ]; then
        printf '  暂无节点\n'
    else
        for id in $ids; do
            load_node "$id" || continue
            if port_listening "$N_PORT"; then local_status='监听中'; else local_status='未监听'; fi
            printf '  [%s] %s 监听 %s -> 映射 %s (%s)\n' \
                "$id" "$N_NAME" "$N_PORT" "$N_PUBLIC_PORT" "$local_status"
        done
    fi
    printf '\n面板中的外部端口必须映射到实例对应监听端口；本检查无法读取 NAT 面板规则。\n'
    printf '请从实例外部网络检查 TCP 连通性；同时核对实例状态、端口额度和防火墙策略。\n'
    printf '资源状态: 内存 %s | 磁盘 %s | inode %s\n' \
        "$(free -h 2>/dev/null | awk '/^Mem:/{print $3"/"$2}')" \
        "$(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')" \
        "$(df -i / 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')"
}

SNI_DATA_DIR="/usr/local/share/rysh"

sni_host_region() {
    awk -F '\t' -v host="$1" '$1==host {print $3; exit}' "$SNI_DATA_DIR/sni-candidates.tsv" 2>/dev/null
}

sni_host_risk() {
    host=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')
    awk -v host="$host" 'host==$0 || (length(host)>length($0) && substr(host, length(host)-length($0), 1)=="." && substr(host, length(host)-length($0)+1)==$0) {found=1; exit} END{exit !found}' "$SNI_DATA_DIR/sni-risk-suffixes.txt" 2>/dev/null
}

sni_category_hosts() {
    awk -F '\t' -v category="$1" '$2==category {print $1}' "$SNI_DATA_DIR/sni-candidates.tsv"
}

sni_region_hosts() {
    region="$1"
    awk -F '\t' -v region="$region" '$3=="global" || $3==region {print $1}' "$SNI_DATA_DIR/sni-candidates.tsv"
}

quick_sni_detect() {
    SNI_DETECTED=""
    [ -f "$SNI_DATA_DIR/sni-candidates.tsv" ] || return 1
    need_cmd openssl && need_cmd curl && need_cmd timeout || return 1
    candidates=$(awk -F '\t' '$2=="cdn" {print $1}' "$SNI_DATA_DIR/sni-candidates.tsv" | awk 'NR<=3')
    best_time=""
    for host in $candidates; do
        if sni_host_risk "$host"; then continue; fi
        result=$(timeout 6 openssl s_client -connect "$host:443" -servername "$host" -tls1_3 -alpn h2 -verify_return_error -verify_hostname "$host" -showcerts </dev/null 2>&1)
        printf '%s\n' "$result" | grep -qiE 'Protocol version: TLSv1\.3|Protocol *: *TLSv1\.3|New, TLSv1\.3' || continue
        printf '%s\n' "$result" | grep -qiE '(Negotiated )?ALPN protocol: h2' || continue
        printf '%s\n' "$result" | grep -qiE 'Verification: OK|Verify return code: 0 \(ok\)' || continue
        printf '%s\n' "$result" | grep -qi 'X25519' || continue
        timing=$(curl -sS -o /dev/null --http1.1 --connect-timeout 4 --max-time 6 -w '%{time_appconnect}' "https://$host/" 2>/dev/null)
        case "$timing" in ''|*[!0-9.]*) continue ;; esac
        if [ -z "$best_time" ] || awk -v a="$timing" -v b="$best_time" 'BEGIN{exit !(a<b)}'; then
            best_time="$timing"
            SNI_DETECTED="$host"
        fi
    done
    [ -n "$SNI_DETECTED" ]
}

prepare_node_sni() {
    if quick_sni_detect; then
        DEFAULT_SNI="$SNI_DETECTED"
        printf '快速识别结果: %s (作为默认 SNI/目标地址，可手动修改)\n' "$SNI_DETECTED"
    else
        printf '快速识别未找到合规候选，继续使用当前默认值: %s\n' "$DEFAULT_SNI"
    fi
}

check_sni_candidates() {
    require_root
    [ -f "$SNI_DATA_DIR/sni-candidates.tsv" ] && [ -f "$SNI_DATA_DIR/sni-risk-suffixes.txt" ] || {
        err "SNI 检测数据文件缺失，请重新安装 rysh"
        return 1
    }
    printf 'SNI 检测: 1.快速测试  2.全部分类  3.选择分类  4.按地区推荐  5.自定义域名\n请选择: '
    read -r mode 2>/dev/null || mode=""
    case "$mode" in
        1) candidates=$(awk -F '\t' '$2=="cdn" || $2=="cloud" || $2=="tech" {print $1}' "$SNI_DATA_DIR/sni-candidates.tsv") ;;
        2) candidates=$(awk -F '\t' '{print $1}' "$SNI_DATA_DIR/sni-candidates.tsv") ;;
        3)
            printf '分类: cdn cloud tech fin edu media social gaming ecom region\n选择一个或多个分类(空格分隔): '
            read -r selected 2>/dev/null || selected=""
            candidates=""
            for category in $selected; do
                case "$category" in cdn|cloud|tech|fin|edu|media|social|gaming|ecom|region) candidates="$candidates $(sni_category_hosts "$category")" ;; esac
            done
            ;;
        4)
            printf '地区: global us eu jp hk sg cn au kr\n请选择地区: '
            read -r region 2>/dev/null || region=""
            case "$region" in global|us|eu|jp|hk|sg|cn|au|kr) candidates=$(sni_region_hosts "$region") ;; *) warn "地区无效"; return 1 ;; esac
            ;;
        5)
            printf '输入域名(空格或逗号分隔): '
            read -r candidates 2>/dev/null || candidates=""
            candidates=$(printf '%s' "$candidates" | tr ',' ' ')
            ;;
        *) warn "无效选项"; return 1 ;;
    esac
    [ -n "$candidates" ] || { warn "没有可检测的域名"; return 1; }
    if ! need_cmd openssl || ! need_cmd curl; then
        err "检测需要 curl 和 openssl，请先安装"
        return 1
    fi
    printf '\n%-34s %-9s %-7s %-5s %-10s %-8s %-9s %s\n' '域名' '握手秒' 'TLS1.3' 'h2' '密钥交换' '证书' '地区' '结果'
    printf '%s\n' '----------------------------------------------------------------------------------------------------------'
    best_host=""
    best_time=""
    for host in $candidates; do
        validate_sni "$host" || {
            printf '%-34s %s\n' "$host" '跳过: 域名格式无效'
            continue
        }
        info=$(timeout 8 openssl s_client -connect "$host:443" -servername "$host" -tls1_3 -alpn h2 -showcerts </dev/null 2>&1)
        tls="否"
        alpn="否"
        key="未知"
        cert="否"
        printf '%s\n' "$info" | grep -qiE 'Protocol version: TLSv1\.3|Protocol *: *TLSv1\.3|New, TLSv1\.3' && tls="是"
        printf '%s\n' "$info" | grep -qiE '(Negotiated )?ALPN protocol: h2' && alpn="是"
        key=$(printf '%s\n' "$info" | awk 'tolower($0) ~ /(peer|server) temp key:/ {sub(/^.*[Tt]emp [Kk]ey: */, ""); sub(/,.*/, ""); print; exit}')
        [ -n "$key" ] || key="未知"
        verify=$(timeout 8 openssl s_client -connect "$host:443" -servername "$host" -tls1_3 -alpn h2 -verify_return_error -verify_hostname "$host" -showcerts </dev/null 2>&1)
        printf '%s\n' "$verify" | grep -qiE 'Verification: OK|Verify return code: 0 \(ok\)' && cert="是"
        timing=$(curl -sS -o /dev/null --http1.1 --connect-timeout 5 --max-time 8 -w '%{time_appconnect}' "https://$host/" 2>/dev/null)
        case "$timing" in ''|*[!0-9.]*) timing="超时" ;; esac
        region=$(sni_host_region "$host")
        [ -n "$region" ] || region="自定义"
        result="不合规"
        risk="否"
        if sni_host_risk "$host"; then risk="是"; fi
        x25519="否"
        printf '%s' "$key" | grep -qi 'X25519' && x25519="是"
        if [ "$x25519" != "是" ] && [ "$tls" = "是" ] && [ "$cert" = "是" ]; then
            openssl_help=$(openssl s_client -help 2>&1)
            case "$openssl_help" in
                *-groups*) group_arg="-groups" ;;
                *-curves*) group_arg="-curves" ;;
                *) group_arg="" ;;
            esac
            if [ -n "$group_arg" ]; then
                xinfo=$(timeout 8 openssl s_client -connect "$host:443" -servername "$host" -tls1_3 -alpn h2 "$group_arg" X25519 -verify_return_error -verify_hostname "$host" </dev/null 2>&1)
                printf '%s\n' "$xinfo" | grep -qi 'X25519' && x25519="是"
            fi
        fi
        if [ "$risk" = "是" ]; then
            result="风险后缀"
        elif [ "$tls" = "是" ] && [ "$alpn" = "是" ] && [ "$cert" = "是" ] && [ "$x25519" = "是" ]; then
            result="推荐"
            if [ "$timing" != "超时" ] && { [ -z "$best_time" ] || awk -v a="$timing" -v b="$best_time" 'BEGIN{exit !(a<b)}'; }; then
                best_time="$timing"
                best_host="$host"
            fi
        elif [ "$tls" = "是" ] && [ "$cert" = "是" ]; then
            missing=""
            [ "$alpn" = "是" ] || missing="h2"
            [ "$x25519" = "是" ] || missing="${missing}${missing:+/}X25519"
            result="可用(缺少 $missing)"
        fi
        printf '%-34s %-9s %-7s %-5s %-10s %-8s %-9s %s\n' "$host" "$timing" "$tls" "$alpn" "$key" "$cert" "$region" "$result"
    done
    if [ -n "$best_host" ]; then
        printf '\n建议 dest/SNI: %s:443 (握手 %ss)\n' "$best_host" "$best_time"
        printf '提示：添加节点时将 SNI 与目标地址主机名设为同一域名。\n'
    else
        warn "没有检测到全部满足 TLS1.3、h2、X25519 和证书校验的候选站点"
    fi
}

service_start() {
    if systemd_active; then
        systemctl start rysh.service xray.service
        wait_xray_start
        return $?
    fi
    if openrc_active; then
        rc-service rysh start >/dev/null 2>&1 || true
        rc-service xray start >/dev/null 2>&1 || true
        wait_xray_start
        return $?
    fi
    xray_start
    apply_tc_all
    monitor_run --quiet
    wait_xray_start
}

service_stop() {
    if systemd_active; then
        systemctl stop xray.service rysh.service >/dev/null 2>&1 || true
        return 0
    fi
    if openrc_active; then
        rc-service xray stop >/dev/null 2>&1 || true
        rc-service rysh stop >/dev/null 2>&1 || true
        return 0
    fi
    xray_stop
    clear_all
}

service_status() {
    printf 'Xray  : %s\n' "$(xray_status_text)"
    if systemd_active; then
        printf 'rysh  : %s\n' "$(systemctl is-active rysh.service 2>/dev/null || true)"
        printf 'cron  : %s\n' "$(systemctl is-active cron.service 2>/dev/null || systemctl is-active crond.service 2>/dev/null || true)"
        return 0
    fi
    if openrc_active; then
        printf 'rysh  : %s\n' "$(rc-service rysh status 2>&1 | head -n 1)"
        printf 'crond : %s\n' "$(rc-service crond status 2>&1 | head -n 1)"
    fi
}

reset_all_credentials() {
    require_root
    require_xray
    ensure_dirs
    ids=$(node_ids)
    if [ -z "$ids" ]; then
        warn "还没有节点，无需重置"
        return 1
    fi
    count=$(printf '%s\n' $ids | wc -l | tr -d ' ')
    if [ "${RYSH_ASSUME_YES:-0}" != "1" ]; then
        printf '将重置 %s 个节点的 UUID、ShortID 与 Reality 密钥，客户端需重新导入。继续? [y/N]: ' "$count"
        read -r a 2>/dev/null || a=""
        case "$a" in
            y|Y) ;;
            *) warn "已取消"; return 1 ;;
        esac
    fi

    changed=0
    failed=0
    for id in $ids; do
        load_node "$id" || continue
        u=$(gen_uuid)
        keys=$(gen_keys)
        sid=$(gen_shortid)
        if [ -z "$u" ] || [ -z "$keys" ] || [ -z "$sid" ]; then
            warn "节点 $id 凭据生成失败，已跳过"
            failed=$((failed + 1))
            continue
        fi
        N_UUID="$u"
        N_PRIV=${keys%%|*}
        N_PUB=${keys#*|}
        N_SID="$sid"
        save_node || {
            warn "节点 $id 保存失败"
            failed=$((failed + 1))
            continue
        }
        changed=$((changed + 1))
    done

    if [ "$changed" -eq 0 ]; then
        err "没有节点被重置"
        return 1
    fi
    log_event "reset credentials for $changed nodes"
    apply_config || {
        warn "凭据已保存，但配置应用失败，请执行 rysh apply"
        return 1
    }
    monitor_run --quiet
    ok "已重置 $changed 个节点的凭据，节点数据保留$([ "$failed" -gt 0 ] && printf '（%s 个失败）' "$failed")"

    CACHED_IP=$(get_public_ip)
    for id in $ids; do
        load_node "$id" || continue
        printf '\n[%s] %s\n%s\n' "$N_ID" "$N_NAME" "$(build_link)"
    done
    unset CACHED_IP
    return 0
}

uninstall_keep_config() {
    remove_cron
    if openrc_active; then
        rc-service rysh stop >/dev/null 2>&1 || true
        rc-update del rysh default >/dev/null 2>&1 || true
    fi
    if systemd_active; then
        systemctl disable --now rysh.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/rysh.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    clear_all
    remove_shortcut
    rm -f /etc/init.d/rysh /usr/local/bin/rysh
    rm -f "$SNI_DATA_DIR/sni-candidates.tsv" "$SNI_DATA_DIR/sni-risk-suffixes.txt"
    rmdir "$SNI_DATA_DIR" 2>/dev/null || true
    ok "rysh 已卸载，配置保留在 $RYSH_DIR"
}

purge_all() {
    remove_cron
    xray_stop
    if openrc_active; then
        rc-update del xray default >/dev/null 2>&1 || true
        rc-update del rysh default >/dev/null 2>&1 || true
        rc-service rysh stop >/dev/null 2>&1 || true
    fi
    if systemd_active; then
        systemctl disable --now xray.service rysh.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/xray.service /etc/systemd/system/rysh.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    clear_all
    remove_shortcut
    rm -f /etc/init.d/xray /etc/init.d/rysh /usr/local/bin/xray /usr/local/bin/xray.bak /usr/local/bin/rysh
    rm -rf "$RYSH_DIR" "$XRAY_CONF_DIR" "$XRAY_ASSET_DIR" "$XRAY_LOG_DIR" "$SNI_DATA_DIR"
    ok "完全卸载完成"
}

uninstall_menu() {
    clear_screen
    printf '%s卸载%s\n\n' "$C_BOLD" "$C_NC"
    printf '1. 卸载 rysh (保留 Xray 和 /etc/rysh 配置)\n'
    printf '2. 完全卸载 (删除 Xray、rysh、配置和日志)\n'
    printf '0. 取消\n请选择: '
    read -r c 2>/dev/null || c=""
    case "$c" in
        1)
            printf '确认卸载 rysh? [y/N]: '
            read -r a 2>/dev/null || a=""
            case "$a" in y|Y) ;; *) return 0 ;; esac
            uninstall_keep_config
            exit 0
            ;;
        2)
            printf '确认完全卸载? 所有节点配置和 Xray 将被删除 [y/N]: '
            read -r a 2>/dev/null || a=""
            case "$a" in y|Y) ;; *) return 0 ;; esac
            printf '再次确认，输入 DELETE 继续: '
            read -r a 2>/dev/null || a=""
            [ "$a" = "DELETE" ] || {
                warn "已取消"
                return 0
            }
            purge_all
            exit 0
            ;;
        0) return 0 ;;
        *) warn "无效选项" ;;
    esac
}

edit_config() {
    require_xray
    [ -f "$XRAY_CONF" ] || {
        warn "配置文件不存在，请先应用配置"
        return 1
    }
    ${EDITOR:-vi} "$XRAY_CONF"
    if validate_config "$XRAY_CONF"; then
        xray_restart
        ok "配置校验通过，Xray 已重启 (节点管理操作会重新生成配置)"
    else
        err "配置校验失败，请修改后重试"
        return 1
    fi
}

main_menu() {
    while :; do
        clear_screen
        node_count=$(node_ids | wc -l | tr -d ' ')
        month_total="0"
        healthy_count=0
        attention_count=0
        disabled_count=0
        for id in $(node_ids); do
            load_node "$id" || continue
            load_state "$id"
            month_total=$(add_bytes "$month_total" "$(month_used_bytes)")
            case "$(node_status)" in
                正常) healthy_count=$((healthy_count + 1)) ;;
                已禁用) disabled_count=$((disabled_count + 1)) ;;
                *) attention_count=$((attention_count + 1)) ;;
            esac
        done
        printf '%s============================================================%s\n' "$C_CYAN" "$C_NC"
        printf '%s rysh %s - Xray Reality 多节点管理 (Alpine Linux)%s\n' "$C_BOLD" "$RYSH_VERSION" "$C_NC"
        printf ' 系统: %s | 节点: %s | Xray: %s | 本月总流量: %s\n' \
            "$(cat /etc/alpine-release 2>/dev/null || printf '未知')" "$node_count" "$(xray_status_text)" "$(human_bytes "$month_total")"
        printf ' 节点状态: %s正常 %s%s待处理 %s%s已禁用%s\n' \
            "$C_GREEN" "$healthy_count" "$C_NC" "$C_YELLOW" "$attention_count" "$C_NC"
        printf '           %s%s已禁用%s\n' "$C_RED" "$disabled_count" "$C_NC"
        printf '%s============================================================%s\n' "$C_CYAN" "$C_NC"
        printf ' 1. 安装/更新 Xray 核心          2. 创建 Reality 节点\n'
        printf ' 3. 批量创建 Reality 节点        4. 查看节点列表\n'
        printf ' 5. 查看节点链接/二维码          6. 导出全部节点链接\n'
        printf ' 7. 修改节点                     8. 删除节点\n'
        printf ' 9. 启用/禁用节点               10. 重置节点流量\n'
        printf '11. 设置月流量限额             12. 设置节点到期时间\n'
        printf '13. 设置节点限速               14. 实时流量监控\n'
        printf '15. 流量统计/月报              16. 应用所有规则\n'
        printf '17. 启动/停止/重启 Xray        18. 查看 Xray 状态/日志\n'
        printf '19. 安装/更新监控定时任务      20. 全局设置\n'
        printf '21. 备份/恢复                  22. 系统信息/依赖检查\n'
        printf '23. 卸载                       24. 编辑 Xray 配置\n'
        printf '25. 测试节点连通性             26. Reality SNI 检测\n'
        printf '27. NAT VPS 部署检查\n'
        printf '                                   0. 退出\n'
        printf '请输入选项: '
        read -r choice 2>/dev/null || exit 0
        is_uint "$choice" && choice=$(to_int "$choice")
        case "$choice" in
            1) install_xray; pause ;;
            2) create_node; pause ;;
            3) batch_create; pause ;;
            4) show_nodes; pause ;;
            5) show_link_menu; pause ;;
            6) export_links; pause ;;
            7) modify_node ;;
            8) delete_node; pause ;;
            9) toggle_node; pause ;;
            10) reset_traffic_menu; pause ;;
            11) set_quota_menu; pause ;;
            12) set_expiry_menu; pause ;;
            13) set_rate_menu; pause ;;
            14) live_monitor; pause ;;
            15) show_report; pause ;;
            16) apply_all; pause ;;
            17) xray_control_menu ;;
            18) xray_status_log; pause ;;
            19) install_cron; pause ;;
            20) global_settings_menu ;;
            21) backup_menu ;;
            22) system_info; pause ;;
            23) uninstall_menu ;;
            24) edit_config; pause ;;
            25) test_nodes; pause ;;
            26) check_sni_candidates; pause ;;
            27) nat_diagnostics; pause ;;
            0) return 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

usage() {
    cat <<'USAGE_EOF'
rysh - Xray Reality 多节点管理脚本 (Alpine Linux)

用法:
  ry                       进入交互菜单（rysh 的快捷命令）
  rysh                     进入交互菜单
  rysh install [--yes]     安装/更新 Xray 与依赖
  rysh monitor [--quiet]   统计流量并执行限额/到期策略
  rysh apply               应用限速和防火墙规则
  rysh clear               清除限速和防火墙规则
  rysh gen                 输出生成的 Xray 配置
  rysh list                列出节点
  rysh start|stop|restart  启动/停止/重启服务
  rysh status              查看服务状态与日志
  rysh reset-credentials   重置全部节点凭据（保留节点数据）
  rysh uninstall [--purge] [--yes]
                           卸载 rysh；--purge 同时删除 Xray 与全部数据
  rysh version             显示脚本版本
USAGE_EOF
}

assume_yes_arg() {
    case "${1:-}" in
        -y|--yes|-f|--force) RYSH_ASSUME_YES=1 ;;
    esac
}

case "${1:-}" in
    ''|-m|menu)
        require_root
        ensure_dirs
        load_settings
        self_install
        main_menu
        ;;
    install)
        require_root
        ensure_dirs
        load_settings
        assume_yes_arg "${2:-}"
        install_xray
        ;;
    monitor)
        require_root
        ensure_dirs
        load_settings
        monitor_run "${2:-}"
        ;;
    apply)
        require_root
        ensure_dirs
        load_settings
        apply_tc_all
        monitor_run --quiet
        ;;
    clear)
        require_root
        ensure_dirs
        load_settings
        clear_all
        ;;
    gen)
        require_root
        ensure_dirs
        load_settings
        gen_config
        ;;
    list)
        require_root
        ensure_dirs
        load_settings
        show_nodes
        ;;
    start)
        require_root
        ensure_dirs
        load_settings
        if service_start; then
            ok "服务已启动"
        else
            err "服务启动失败，请查看 $XRAY_LOG_DIR/error.log"
            exit 1
        fi
        ;;
    stop)
        require_root
        load_settings
        service_stop
        ok "服务已停止"
        ;;
    restart)
        require_root
        ensure_dirs
        load_settings
        service_stop
        if service_start; then
            ok "服务已重启"
        else
            err "服务重启失败，请查看 $XRAY_LOG_DIR/error.log"
            exit 1
        fi
        ;;
    status)
        require_root
        load_settings
        service_status
        ;;
    reset-credentials)
        require_root
        ensure_dirs
        load_settings
        assume_yes_arg "${2:-}"
        reset_all_credentials
        ;;
    uninstall)
        require_root
        ensure_dirs
        load_settings
        mode="keep"
        for arg in "$@"; do
            case "$arg" in
                --purge) mode="purge" ;;
                -y|--yes|-f|--force) RYSH_ASSUME_YES=1 ;;
            esac
        done
        if [ "${RYSH_ASSUME_YES:-0}" != "1" ]; then
            if [ "$mode" = "purge" ]; then
                printf '确认完全卸载? 所有节点配置和 Xray 将被删除，输入 DELETE 继续: '
                read -r a 2>/dev/null || a=""
                [ "$a" = "DELETE" ] || {
                    warn "已取消"
                    exit 1
                }
            else
                printf '确认卸载 rysh? 节点配置会保留 [y/N]: '
                read -r a 2>/dev/null || a=""
                case "$a" in
                    y|Y) ;;
                    *) warn "已取消"; exit 1 ;;
                esac
            fi
        fi
        if [ "$mode" = "purge" ]; then
            purge_all
        else
            uninstall_keep_config
        fi
        ;;
    version|-v|--version)
        printf '%s\n' "$RYSH_VERSION"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
