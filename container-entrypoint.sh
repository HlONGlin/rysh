#!/bin/sh
set -eu

RYSH_BIN="${RYSH_BIN:-/usr/local/bin/rysh}"
XRAY_BIN="${RYSH_XRAY_BIN:-/usr/local/bin/xray}"
RYSH_DIR="${RYSH_DIR:-/etc/rysh}"
XRAY_CONF_DIR="${RYSH_XRAY_CONF_DIR:-/usr/local/etc/xray}"
XRAY_CONF="$XRAY_CONF_DIR/config.json"
XRAY_ASSET_DIR="${RYSH_XRAY_ASSET_DIR:-/usr/local/share/xray}"
XRAY_LOG_DIR="${RYSH_XRAY_LOG_DIR:-/var/log/xray}"
SNI_DATA_DIR="${RYSH_SNI_DATA_DIR:-/usr/local/share/rysh}"

[ "$(id -u)" -eq 0 ] || {
    printf '%s\n' "container-entrypoint 必须以 root 运行" >&2
    exit 1
}

mkdir -p "$RYSH_DIR" "$XRAY_CONF_DIR" "$(dirname "$XRAY_BIN")" "$XRAY_ASSET_DIR" "$XRAY_LOG_DIR" "$SNI_DATA_DIR"

for data_file in sni-candidates.tsv sni-risk-suffixes.txt; do
    if [ ! -f "$SNI_DATA_DIR/$data_file" ] && [ -f "/usr/share/rysh/$data_file" ]; then
        cp "/usr/share/rysh/$data_file" "$SNI_DATA_DIR/$data_file"
    fi
done
chmod 644 "$SNI_DATA_DIR"/* 2>/dev/null || true

if [ ! -x "$XRAY_BIN" ]; then
    printf '%s\n' "首次启动：安装 Xray 与运行依赖"
    "$RYSH_BIN" install --yes
fi

exec "$RYSH_BIN" serve
