#!/bin/sh

ONECLICK_VERSION="1.0.2"
REPO_RAW="${RYSH_REPO_RAW:-https://github.com/HlONGlin/rysh/raw/main}"
RYSH_BIN="/usr/local/bin/rysh"
RYSH_SRC_URL="$REPO_RAW/rysh.sh"
TMP_FILE="/tmp/rysh-install.$$"

if [ -t 1 ]; then
    C_RED=$(printf '\033[31m')
    C_GREEN=$(printf '\033[32m')
    C_YELLOW=$(printf '\033[33m')
    C_CYAN=$(printf '\033[36m')
    C_BOLD=$(printf '\033[1m')
    C_DIM=$(printf '\033[2m')
    C_NC=$(printf '\033[0m')
else
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
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
    printf '%s按回车返回菜单...%s' "$C_DIM" "$C_NC"
    read -r _ 2>/dev/null || true
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行此脚本"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

cleanup() {
    rm -f "$TMP_FILE" 2>/dev/null
}
trap 'cleanup' EXIT INT TERM

ensure_downloader() {
    need_cmd curl && return 0
    need_cmd wget && return 0
    if need_cmd apk; then
        msg "未找到 curl/wget，正在安装 curl..."
        apk add --no-cache curl ca-certificates >/dev/null 2>&1 || true
    elif need_cmd apt-get; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq curl ca-certificates >/dev/null 2>&1 || true
    elif need_cmd dnf; then
        dnf install -y curl ca-certificates >/dev/null 2>&1 || true
    elif need_cmd yum; then
        yum install -y curl ca-certificates >/dev/null 2>&1 || true
    fi
    need_cmd curl || need_cmd wget || die "缺少 curl/wget，请先安装后再运行"
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

rysh_installed() {
    [ -x "$RYSH_BIN" ]
}

status_line() {
    if rysh_installed; then
        ver=$("$RYSH_BIN" version 2>/dev/null | head -n 1)
        [ -n "$ver" ] || ver="未知"
        state=$("$RYSH_BIN" status 2>/dev/null | head -n 1 | sed 's/^[^:]*: *//')
        printf 'rysh: %s版本 %s%s' "$C_GREEN" "$ver" "$C_NC"
        [ -n "$state" ] && printf ' | %s' "$state"
        printf '\n'
    else
        printf 'rysh: %s未安装%s\n' "$C_YELLOW" "$C_NC"
    fi
}

install_rysh() {
    require_root
    ensure_downloader
    msg "下载 rysh: $RYSH_SRC_URL"
    if ! download "$RYSH_SRC_URL" "$TMP_FILE"; then
        rm -f "$TMP_FILE"
        die "下载失败，请检查网络或 GitHub 访问情况"
    fi
    if ! grep -q 'RYSH_VERSION' "$TMP_FILE" 2>/dev/null; then
        rm -f "$TMP_FILE"
        die "下载内容无效，请稍后重试"
    fi
    chmod 755 "$TMP_FILE"
    mkdir -p /usr/local/bin 2>/dev/null
    if ! mv "$TMP_FILE" "$RYSH_BIN"; then
        rm -f "$TMP_FILE"
        die "安装到 $RYSH_BIN 失败"
    fi
    chmod 755 "$RYSH_BIN"
    ok "rysh 已安装到 $RYSH_BIN"

    ensure_shortcut

    if ! "$RYSH_BIN" install --yes; then
        err "安装依赖或 Xray 失败，请查看上方输出"
        return 1
    fi
    ensure_shortcut
    ok "安装完成"
    printf '\n以后在任意目录输入 %sry%s 即可唤出面板，也可以选择 %s6%s 进入节点管理菜单。\n' "$C_BOLD" "$C_NC" "$C_BOLD" "$C_NC"
}

ensure_shortcut() {
    [ -x "$RYSH_BIN" ] || return 0
    if [ -e /usr/local/bin/ry ] && [ ! -L /usr/local/bin/ry ]; then
        if ! cmp -s /usr/local/bin/ry "$RYSH_BIN" 2>/dev/null; then
            warn "/usr/local/bin/ry 已被其他程序占用，未创建快捷命令"
            return 0
        fi
    fi
    if ln -sf "$RYSH_BIN" /usr/local/bin/ry 2>/dev/null; then
        return 0
    fi
    cp "$RYSH_BIN" /usr/local/bin/ry 2>/dev/null && chmod 755 /usr/local/bin/ry 2>/dev/null
}

start_rysh() {
    require_root
    rysh_installed || die "rysh 尚未安装，请先选择 1"
    if "$RYSH_BIN" start; then
        ok "已启动"
    else
        err "启动失败，请查看 /var/log/xray/error.log"
    fi
}

stop_rysh() {
    require_root
    rysh_installed || die "rysh 尚未安装，请先选择 1"
    "$RYSH_BIN" stop
}

purge_rysh() {
    require_root
    rysh_installed || {
        warn "rysh 尚未安装"
        return 0
    }
    printf '%s警告: 将删除 rysh、Xray、全部节点配置、流量记录和限速/防火墙规则。%s\n' "$C_RED" "$C_NC"
    printf '输入 DELETE 确认彻底卸载: '
    read -r a 2>/dev/null || a=""
    [ "$a" = "DELETE" ] || {
        warn "已取消"
        return 0
    }
    "$RYSH_BIN" uninstall --purge --yes
}

reset_credentials() {
    require_root
    rysh_installed || die "rysh 尚未安装，请先选择 1"
    "$RYSH_BIN" reset-credentials
}

open_menu() {
    require_root
    rysh_installed || {
        warn "rysh 尚未安装，请先选择 1"
        return 0
    }
    "$RYSH_BIN"
}

main_menu() {
    while :; do
        clear_screen
        printf '%s============================================================%s\n' "$C_CYAN" "$C_NC"
        printf '%s rysh 一键部署 %s - Xray Reality 多节点管理%s\n' "$C_BOLD" "$ONECLICK_VERSION" "$C_NC"
        printf ' 系统: %s\n' "$(cat /etc/alpine-release 2>/dev/null || uname -s)"
        status_line
        printf '%s============================================================%s\n' "$C_CYAN" "$C_NC"
        printf ' 1. 安装或更新 rysh（含 Xray 核心与依赖）\n'
        printf ' 2. 启动 rysh / Xray 服务\n'
        printf ' 3. 停止 rysh / Xray 服务\n'
        printf ' 4. 彻底卸载并清除全部数据\n'
        printf ' 5. 重置节点凭据（保留节点数据）\n'
        printf ' 6. 进入 rysh 节点管理菜单\n'
        printf ' 0. 退出\n'
        printf '%s提示：安装完成后，在任意目录输入 ry 即可直接唤出面板。%s\n' "$C_DIM" "$C_NC"
        printf '请输入选项: '
        read -r choice 2>/dev/null || exit 0
        case "$choice" in
            1) install_rysh; pause ;;
            2) start_rysh; pause ;;
            3) stop_rysh; pause ;;
            4) purge_rysh; pause ;;
            5) reset_credentials; pause ;;
            6) open_menu ;;
            0) exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

usage() {
    cat <<'USAGE_EOF'
rysh 一键部署脚本

用法:
  bash <(curl -fsSL https://github.com/HlONGlin/rysh/raw/main/one-click.sh)
  one-click.sh [install|start|stop|purge|reset|menu]

命令:
  install   安装或更新 rysh（含 Xray 与依赖）
  start     启动 rysh / Xray
  stop      停止 rysh / Xray
  purge     彻底卸载并清除全部数据（需输入 DELETE）
  reset     重置节点凭据（保留节点数据）
  menu      进入交互菜单（默认）
USAGE_EOF
}

case "${1:-}" in
    ''|menu) require_root; main_menu ;;
    install) install_rysh ;;
    start) start_rysh ;;
    stop) stop_rysh ;;
    purge) purge_rysh ;;
    reset|reset-credentials) reset_credentials ;;
    version|-v|--version) printf '%s\n' "$ONECLICK_VERSION" ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
esac
