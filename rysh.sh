#!/bin/sh

RYSH_VERSION="1.0.0"
RYSH_DIR="/etc/rysh"
NODE_DIR="$RYSH_DIR/nodes"
STATE_DIR="$RYSH_DIR/state"
HISTORY_DIR="$RYSH_DIR/history"
SETTINGS_FILE="$RYSH_DIR/settings.conf"
BLOCKED_FILE="$RYSH_DIR/blocked.ports"
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
    DEFAULT_SNI="www.microsoft.com"
    DEFAULT_FLOW="xtls-rprx-vision"
    DEFAULT_FP="chrome"
    MONITOR_INTERVAL="1"
    IFACE=""
    DOWNLOAD_PROXY=""
    if [ -f "$SETTINGS_FILE" ]; then
        . "$SETTINGS_FILE"
    fi
    [ -n "$DEFAULT_SNI" ] || DEFAULT_SNI="www.microsoft.com"
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
        return 0
    fi
    [ -x /usr/local/bin/rysh ] || warn "请将脚本安装到 /usr/local/bin/rysh，否则定时任务无法运行"
}

ensure_deps() {
    if ! need_cmd apk; then
        warn "未找到 apk，这可能不是 Alpine Linux"
        return 0
    fi
    missing=""
    for c in curl unzip jq nft tc ss; do
        need_cmd "$c" || missing="$missing $c"
    done
    if [ -n "$missing" ]; then
        msg "正在安装依赖:$missing"
        apk add --no-cache curl unzip jq nftables iptables iproute2 ca-certificates >/dev/null 2>&1 || {
            err "依赖安装失败，请检查网络或软件源"
            return 1
        }
        need_cmd tc || apk add --no-cache iproute2-tc >/dev/null 2>&1 || true
        need_cmd ss || apk add --no-cache iproute2-ss >/dev/null 2>&1 || true
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
        printf '是否更新到最新版本? [y/N]: '
        read -r ans 2>/dev/null || ans=""
        case "$ans" in
            y|Y|yes|YES) ;;
            *) return 0 ;;
        esac
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

    if [ -x "$XRAY_BIN" ]; then
        cp "$XRAY_BIN" "$XRAY_BIN.bak" 2>/dev/null || true
    fi
    xray_stop
    sleep 1
    if ! cp "$tmp/xray" "$XRAY_BIN"; then
        [ -x "$XRAY_BIN.bak" ] && mv "$XRAY_BIN.bak" "$XRAY_BIN"
        xray_start
        rm -rf "$tmp"
        die "安装 xray 失败"
    fi
    chmod 755 "$XRAY_BIN"
    [ -f "$tmp/geoip.dat" ] && cp "$tmp/geoip.dat" "$XRAY_ASSET_DIR/geoip.dat"
    [ -f "$tmp/geosite.dat" ] && cp "$tmp/geosite.dat" "$XRAY_ASSET_DIR/geosite.dat"
    rm -rf "$tmp"

    if ! "$XRAY_BIN" version >/dev/null 2>&1; then
        if [ -x "$XRAY_BIN.bak" ]; then
            mv "$XRAY_BIN.bak" "$XRAY_BIN"
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

    if [ ! -f "$XRAY_CONF" ]; then
        gen_config > "$XRAY_CONF" || die "生成默认配置失败"
        chmod 600 "$XRAY_CONF"
    fi
    if ! validate_config "$XRAY_CONF"; then
        warn "现有配置校验失败，尝试重新生成"
        gen_config > "$XRAY_CONF" || die "生成配置失败"
        chmod 600 "$XRAY_CONF"
        if ! validate_config "$XRAY_CONF"; then
            die "Xray 配置校验失败，请查看 $XRAY_LOG_DIR/error.log"
        fi
    fi

    if openrc_active; then
        rc-update add xray default >/dev/null 2>&1 || true
        rc-update add rysh default >/dev/null 2>&1 || true
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

validate_config() {
    [ -x "$XRAY_BIN" ] || return 1
    "$XRAY_BIN" run -test -c "$1" >/dev/null 2>&1 && return 0
    "$XRAY_BIN" -test -c "$1" >/dev/null 2>&1 && return 0
    return 1
}

xray_start() {
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
    S_BLOCK_REASON=""
    f="$STATE_DIR/$1.state"
    [ -f "$f" ] || return 0
    . "$f"
    S_TOTAL_UP=${S_TOTAL_UP:-0}
    S_TOTAL_DOWN=${S_TOTAL_DOWN:-0}
    S_MONTH_UP=${S_MONTH_UP:-0}
    S_MONTH_DOWN=${S_MONTH_DOWN:-0}
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
    enc=$(urlencode "$N_NAME")
    flow=""
    [ -n "$N_FLOW" ] && flow="&flow=$N_FLOW"
    fp="$N_FP"
    [ -n "$fp" ] || fp="chrome"
    printf 'vless://%s@%s:%s?encryption=none%s&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=tcp&headerType=none#%s\n' \
        "$N_UUID" "$ip" "$N_PORT" "$flow" "$N_SNI" "$fp" "$N_PUB" "$N_SID" "$enc"
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
    tmp="$XRAY_CONF.tmp.$$"
    if ! gen_config > "$tmp"; then
        rm -f "$tmp"
        err "生成配置失败"
        return 1
    fi
    if ! validate_config "$tmp"; then
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
    reset="$1"
    if need_cmd timeout; then
        if [ "$reset" = "1" ]; then
            timeout 10 "$XRAY_BIN" api statsquery --server="$API_ADDR" -pattern "user>>>" -reset 2>/dev/null
        else
            timeout 10 "$XRAY_BIN" api statsquery --server="$API_ADDR" -pattern "user>>>" 2>/dev/null
        fi
    else
        if [ "$reset" = "1" ]; then
            "$XRAY_BIN" api statsquery --server="$API_ADDR" -pattern "user>>>" -reset 2>/dev/null
        else
            "$XRAY_BIN" api statsquery --server="$API_ADDR" -pattern "user>>>" 2>/dev/null
        fi
    fi
}

stats_reset_user() {
    uid="$1"
    if need_cmd timeout; then
        timeout 10 "$XRAY_BIN" api statsquery --server="$API_ADDR" -pattern "user>>>n$uid>>>" -reset >/dev/null 2>&1
    else
        "$XRAY_BIN" api statsquery --server="$API_ADDR" -pattern "user>>>n$uid>>>" -reset >/dev/null 2>&1
    fi
}

get_stat() {
    f="$1"
    k="$2"
    awk -v k="$k" '$1==k {print $2; found=1; exit} END{if(!found) print 0}' "$f" 2>/dev/null
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
    printf '正常'
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

apply_tc_all() {
    dev="$IFACE"
    [ -n "$dev" ] || dev=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    has_rate=0
    for id in $(node_ids); do
        en=$(node_get_field "$id" N_ENABLED)
        [ "$en" = "1" ] || continue
        r=$(node_get_field "$id" N_RATE_MBPS)
        [ -n "$r" ] && awk -v r="$r" 'BEGIN{exit !(r+0>0)}' && has_rate=1
    done
    if ! need_cmd tc; then
        if [ "$has_rate" -eq 1 ]; then
            warn "未安装 tc，无法应用限速 (apk add iproute2-tc)"
            return 1
        fi
        return 0
    fi
    if ! need_cmd ip; then
        if [ "$has_rate" -eq 1 ]; then
            warn "未安装 ip 命令，无法应用限速"
            return 1
        fi
        return 0
    fi
    if [ -z "$dev" ]; then
        if [ "$has_rate" -eq 1 ]; then
            warn "无法检测默认网卡，请在全局设置中指定网卡"
            return 1
        fi
        return 0
    fi

    tc qdisc del dev "$dev" root 2>/dev/null || true
    tc qdisc del dev "$dev" ingress 2>/dev/null || true
    ip link del ifb0 2>/dev/null || true
    [ "$has_rate" -eq 0 ] && return 0

    modprobe sch_htb 2>/dev/null || true
    if ! tc qdisc add dev "$dev" root handle 1: htb default ffff 2>/dev/null; then
        warn "创建 egress 限速队列失败"
        return 1
    fi
    tc class add dev "$dev" parent 1: classid 1:ffff htb rate 100gbit ceil 100gbit 2>/dev/null || true

    ingress_ok=0
    modprobe ifb 2>/dev/null || true
    if ip link add ifb0 type ifb 2>/dev/null; then
        ip link set ifb0 up 2>/dev/null || true
        if tc qdisc add dev "$dev" handle ffff: ingress 2>/dev/null; then
            if ! tc filter add dev "$dev" parent ffff: protocol all prio 1 u32 match u32 0 0 action mirred egress redirect dev ifb0 2>/dev/null; then
                tc filter add dev "$dev" parent ffff: protocol ip prio 1 u32 match u32 0 0 action mirred egress redirect dev ifb0 2>/dev/null || true
            fi
            if tc qdisc add dev ifb0 root handle 2: htb default ffff 2>/dev/null; then
                tc class add dev ifb0 parent 2: classid 2:ffff htb rate 100gbit ceil 100gbit 2>/dev/null || true
                ingress_ok=1
            else
                tc qdisc del dev "$dev" ingress 2>/dev/null || true
                ip link del ifb0 2>/dev/null || true
            fi
        fi
    fi

    for id in $(node_ids); do
        load_node "$id" || continue
        [ "$N_ENABLED" = "1" ] || continue
        rate="$N_RATE_MBPS"
        [ -n "$rate" ] && [ "$rate" != "0" ] || continue
        kbit=$(awk -v m="$rate" 'BEGIN{printf "%d", m*1000}')
        [ "$kbit" -gt 0 ] 2>/dev/null || continue

        if ! tc class add dev "$dev" parent 1: classid "1:$id" htb rate "${kbit}kbit" ceil "${kbit}kbit" 2>/dev/null; then
            warn "节点 $id egress 限速类创建失败"
            continue
        fi
        if ! tc filter add dev "$dev" parent 1: protocol all prio 1 flower ip_proto tcp src_port "$N_PORT" flowid "1:$id" 2>/dev/null; then
            tc filter add dev "$dev" parent 1: protocol ip prio 1 u32 match ip sport "$N_PORT" 0xffff flowid "1:$id" 2>/dev/null || warn "节点 $id egress 过滤规则创建失败"
        fi

        if [ "$ingress_ok" -eq 1 ]; then
            if ! tc class add dev ifb0 parent 2: classid "2:$id" htb rate "${kbit}kbit" ceil "${kbit}kbit" 2>/dev/null; then
                continue
            fi
            if ! tc filter add dev ifb0 parent 2: protocol all prio 1 flower ip_proto tcp dst_port "$N_PORT" flowid "2:$id" 2>/dev/null; then
                tc filter add dev ifb0 parent 2: protocol ip prio 1 u32 match ip dport "$N_PORT" 0xffff flowid "2:$id" 2>/dev/null || warn "节点 $id ingress 过滤规则创建失败"
            fi
        fi
    done
    log_event "tc rules applied on $dev"
    return 0
}

clear_tc() {
    need_cmd tc || return 0
    dev="$IFACE"
    [ -n "$dev" ] || dev=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    [ -n "$dev" ] || return 0
    tc qdisc del dev "$dev" root 2>/dev/null || true
    tc qdisc del dev "$dev" ingress 2>/dev/null || true
    ip link del ifb0 2>/dev/null || true
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
    if [ -x "$XRAY_BIN" ]; then
        if json=$(stats_query 1); then
            stats_ok=1
            printf '%s' "$json" | jq -r '.stat[]? | "\(.name) \(.value)"' > "$stats_file" 2>/dev/null || true
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
            up=$(get_stat "$stats_file" "user>>>n$id>>>traffic>>>uplink")
            down=$(get_stat "$stats_file" "user>>>n$id>>>traffic>>>downlink")
            S_TOTAL_UP=$(add_bytes "$S_TOTAL_UP" "$up")
            S_TOTAL_DOWN=$(add_bytes "$S_TOTAL_DOWN" "$down")
            S_MONTH_UP=$(add_bytes "$S_MONTH_UP" "$up")
            S_MONTH_DOWN=$(add_bytes "$S_MONTH_DOWN" "$down")
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
    printf '端口     : %s\n' "$N_PORT"
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
    for id in $ids; do
        load_node "$id" || continue
        load_state "$id"
        printf '%s[%s]%s %s  (端口 %s)  %s\n' "$C_BOLD" "$id" "$C_NC" "$N_NAME" "$N_PORT" "$(node_status)"
        if is_zero_number "$N_QUOTA_GB"; then
            q="不限"
        else
            q="$N_QUOTA_GB GB"
        fi
        if is_zero_number "$N_RATE_MBPS"; then
            r="不限"
        else
            r="$N_RATE_MBPS Mbps"
        fi
        printf '     本月 %s / %s | 总计 %s | 到期 %s | 限速 %s\n' \
            "$(human_bytes "$(month_used_bytes)")" "$q" "$(human_bytes "$(total_used_bytes)")" "$(fmt_time "$N_EXPIRES")" "$r"
    done
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
                if need_cmd apk; then
                    apk add --no-cache qrencode >/dev/null 2>&1 && qrencode -t ANSIUTF8 "$link" 2>/dev/null || warn "二维码安装或生成失败"
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
        printf ' 1. 修改名称        2. 修改端口\n'
        printf ' 3. 修改 SNI/目标   4. 修改流控\n'
        printf ' 5. 修改指纹        6. 重置 UUID\n'
        printf ' 7. 重置 Reality 密钥  8. 修改备注\n'
        printf ' 9. 查看节点链接    0. 返回\n'
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
                prompt_default "新端口" "$N_PORT"
                p=$(sanitize_text "$REPLY")
                while ! validate_change_port "$p" "$id"; do
                    warn "端口无效、被占用或是 API 端口"
                    prompt_default "新端口" "$N_PORT"
                    p=$(sanitize_text "$REPLY")
                done
                N_PORT=$(to_int "$p")
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
            [ -x "$XRAY_BIN" ] && stats_reset_user "$id"
            S_MONTH_UP="0"
            S_MONTH_DOWN="0"
            save_state
            release_lock
            monitor_run
            ok "节点 $id 本月流量已重置"
            ;;
        2)
            acquire_lock || return 1
            [ -x "$XRAY_BIN" ] && stats_reset_user "$id"
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
            1) xray_start; wait_xray_start; ok "启动完成，当前状态: $(xray_status_text)" ;;
            2) xray_stop; ok "已停止" ;;
            3) xray_restart; wait_xray_start; ok "重启完成，当前状态: $(xray_status_text)" ;;
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
    fi
    printf '\n%s最近错误日志%s\n' "$C_BOLD" "$C_NC"
    tail -n 30 "$XRAY_LOG_DIR/error.log" 2>/dev/null || printf '暂无日志\n'
    printf '\n%s最近事件日志%s\n' "$C_BOLD" "$C_NC"
    tail -n 20 "$EVENT_LOG" 2>/dev/null || printf '暂无事件\n'
}

install_cron() {
    [ -n "$MONITOR_INTERVAL" ] || MONITOR_INTERVAL="1"
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
    cron_count=$(grep -c 'rysh monitor' /etc/crontabs/root 2>/dev/null)
    [ -n "$cron_count" ] || cron_count=0
    printf '监控任务 : %s\n' "$cron_count"
    printf '磁盘 /   : %s\n' "$(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')"
    printf '\n%s依赖检查%s\n\n' "$C_BOLD" "$C_NC"
    for c in curl wget unzip jq nft tc ss iptables qrencode; do
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
    ip=$(get_public_ip)
    for id in $ids; do
        load_node "$id" || continue
        load_state "$id"
        if port_listening "$N_PORT"; then
            local_status="本地监听正常"
        else
            local_status="本地未监听"
        fi
        ext_status="未测试"
        if need_cmd nc; then
            if nc -z -w 3 "$ip" "$N_PORT" >/dev/null 2>&1; then
                ext_status="公网端口可达"
            else
                ext_status="公网端口不可达/被防火墙拦截"
            fi
        fi
        printf '[%s] %s 端口 %s | 状态 %s | %s | %s\n' "$id" "$N_NAME" "$N_PORT" "$(node_status)" "$local_status" "$ext_status"
    done
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
            remove_cron
            if openrc_active; then
                rc-service rysh stop >/dev/null 2>&1 || true
                rc-update del rysh default >/dev/null 2>&1 || true
            fi
            clear_all
            rm -f /etc/init.d/rysh /usr/local/bin/rysh
            ok "rysh 已卸载，配置保留在 $RYSH_DIR"
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
            remove_cron
            xray_stop
            if openrc_active; then
                rc-update del xray default >/dev/null 2>&1 || true
                rc-update del rysh default >/dev/null 2>&1 || true
                rc-service rysh stop >/dev/null 2>&1 || true
            fi
            clear_all
            rm -f /etc/init.d/xray /etc/init.d/rysh /usr/local/bin/xray /usr/local/bin/xray.bak /usr/local/bin/rysh
            rm -rf "$RYSH_DIR" "$XRAY_CONF_DIR" "$XRAY_ASSET_DIR" "$XRAY_LOG_DIR"
            ok "完全卸载完成"
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
        for id in $(node_ids); do
            load_state "$id"
            month_total=$(add_bytes "$month_total" "$(month_used_bytes)")
        done
        printf '%s============================================================%s\n' "$C_CYAN" "$C_NC"
        printf '%s rysh %s - Xray Reality 多节点管理 (Alpine Linux)%s\n' "$C_BOLD" "$RYSH_VERSION" "$C_NC"
        printf ' 系统: %s | 节点: %s | Xray: %s | 本月总流量: %s\n' \
            "$(cat /etc/alpine-release 2>/dev/null || printf '未知')" "$node_count" "$(xray_status_text)" "$(human_bytes "$month_total")"
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
        printf '25. 测试节点连通性              0. 退出\n'
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
            0) exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

usage() {
    cat <<'USAGE_EOF'
rysh - Xray Reality 多节点管理脚本 (Alpine Linux)

用法:
  rysh                 进入交互菜单
  rysh install         安装/更新 Xray
  rysh monitor         统计流量并执行限额/到期策略
  rysh apply           应用限速和防火墙规则
  rysh clear           清除限速和防火墙规则
  rysh gen             输出生成的 Xray 配置
  rysh list            列出节点
  rysh start|stop|restart|status
  rysh version         显示脚本版本
USAGE_EOF
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
        load_settings
        xray_start
        ;;
    stop)
        require_root
        load_settings
        xray_stop
        ;;
    restart)
        require_root
        load_settings
        xray_restart
        ;;
    status)
        require_root
        load_settings
        xray_status_log
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
