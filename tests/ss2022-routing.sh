#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export RYSH_DIR="$tmp/data" RYSH_XRAY_CONF_DIR="$tmp/xray"
export RYSH_XRAY_ASSET_DIR="$tmp/assets" RYSH_XRAY_LOG_DIR="$tmp/log"
sed '/^detect_environment$/,$d' "$root/rysh.sh" > "$tmp/functions.sh"
. "$tmp/functions.sh"
ensure_dirs
load_settings

test_port=11000
for method in 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305; do
    test_port=$((test_port + 1))
    password=$(gen_ss2022_password "$method")
    actual=$(printf '%s' "$password" | base64 -d | wc -c | tr -d ' ')
    expected=$(ss2022_key_bytes "$method")
    [ "$actual" = "$expected" ] || exit 1
    id=$(new_ss2022_record "$method" "$method" "$test_port" '' '' '' 0 0 0)
    load_node "$id"
    CACHED_IP=127.0.0.1
    link=$(build_link)
    parse_ss_url "$link"
    [ "$(printf '%s' "$OUT_JSON" | jq -r '.settings.servers[0].password')" = "$N_SS_PASSWORD" ]
done

# Model an old VLESS record, a custom upstream, and invalid/disabled targets.
printf "%s\n" "N_ID='4'" "N_NAME='legacy'" "N_PORT='11004'" "N_ENABLED='1'" \
    "N_UUID='00000000-0000-4000-8000-000000000001'" "N_PRIV='private'" \
    "N_SID='abcd'" "N_SNI='example.com'" "N_DEST='example.com:443'" > "$NODE_DIR/4.conf"
upstream=$(printf '%s' '{"protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":1080}]}}' | base64 | tr -d '\r\n')
printf "%s\n" "N_ID='5'" "N_NAME='upstream'" "N_PORT='11005'" "N_ENABLED='1'" \
    "N_OUT_MODE='custom'" "N_OUT_B64='$upstream'" > "$NODE_DIR/5.conf"
printf "%s\n" "N_ID='6'" "N_NAME='disabled'" "N_PORT='11006'" "N_ENABLED='0'" > "$NODE_DIR/6.conf"
printf '%s\t%s\n' 'invalid:bad' 'direct' 'domain:example.com' 'node:5' \
    'full:direct.example.com' 'direct' 'keyword:skip' 'node:6' > "$ROUTE_DIR/1.routes"
vmess_data=$(b64encode '{"v":"2","add":"example.com","port":"443","id":"00000000-0000-4000-8000-000000000001","net":"tcp","tls":"tls"}')
for test_link in "vmess://$vmess_data" \
    'vless://00000000-0000-4000-8000-000000000001@example.com:443?security=tls&type=tcp' \
    'trojan://test-password@example.com:443?security=tls' "$link"; do
    parse_outbound_any "$test_link"
    route_kind="$OUT_KIND"
    encoded_out=$(b64encode "$OUT_JSON")
    printf '%s\t%s\n' "full:$route_kind.example.com" "link:$encoded_out" >> "$ROUTE_DIR/1.routes"
done
printf '%s\t%s\n' 'full:broken.example.com' 'link:invalid!' >> "$ROUTE_DIR/1.routes"
display=$(show_route_rules 1)
case "$display" in *test-password*|*"$encoded_out"*) exit 1 ;; esac
(
    set +e
    require_xray() { :; }
    outbound_self_test() { :; }
    apply_config() { :; }
    clear_screen() { :; }
    pause() { :; }
    printf '%s\n' 1 1 interactive.example.com \
        'vless://00000000-0000-4000-8000-000000000001@example.com:443?security=tls&type=tcp' 0 |
        route_rules_menu_for_id 2 > /dev/null
)
IFS="$(printf '\t')" read -r saved_match saved_target < "$ROUTE_DIR/2.routes"
[ "$saved_match" = 'domain:interactive.example.com' ]
[ "$(route_target_outbound_json "$saved_target" | jq -r '.protocol')" = vless ]
load_node 4
[ "$N_PROTO" = vless ]
gen_config > "$tmp/config.json"
jq -e '
    ([.inbounds[] | select(.protocol == "shadowsocks")] | length) == 3 and
    ([.inbounds[] | select(.tag == "rysh-4" and .protocol == "vless")] | length) == 1 and
    ([.routing.rules[] | select(.domain == ["domain:example.com"] and .outboundTag == "rysh-route-1-1")] | length) == 1 and
    ([.outbounds[] | select(.tag == "rysh-route-1-1" and .protocol == "socks")] | length) == 1 and
    ([.routing.rules[] | select(.domain == ["full:direct.example.com"] and .outboundTag == "direct")] | length) == 1 and
    ([.routing.rules[] | select(.domain == ["keyword:skip"] and .outboundTag == "block")] | length) == 1 and
    ([.routing.rules[] | select(.domain == ["full:vmess.example.com"] and .outboundTag == "rysh-route-1-4")] | length) == 1 and
    ([.outbounds[] | select(.tag == "rysh-route-1-4" and .protocol == "vmess")] | length) == 1 and
    ([.outbounds[] | select(.tag == "rysh-route-1-5" and .protocol == "vless")] | length) == 1 and
    ([.outbounds[] | select(.tag == "rysh-route-1-6" and .protocol == "trojan")] | length) == 1 and
    ([.outbounds[] | select(.tag == "rysh-route-1-7" and .protocol == "shadowsocks")] | length) == 1 and
    ([.routing.rules[] | select(.domain == ["full:broken.example.com"] and .outboundTag == "block")] | length) == 1
' < "$tmp/config.json" >/dev/null
if [ -n "${RYSH_TEST_XRAY:-}" ]; then
    jq 'del(.log.error) | .inbounds |= map(select(.protocol == "shadowsocks" or .tag == "api")) | .routing.rules |= map(select(.inboundTag != ["rysh-5"]))' < "$tmp/config.json" > "$tmp/xray-test.json"
    config_path="$tmp/xray-test.json"
    if command -v cygpath >/dev/null 2>&1; then config_path=$(cygpath -w "$config_path"); fi
    "$RYSH_TEST_XRAY" run -test -c "$config_path"
fi
printf '%s\n' 'SS2022 and routing tests passed'
