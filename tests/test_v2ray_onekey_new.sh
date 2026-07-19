#!/usr/bin/env bash
# Test doubles are invoked indirectly by sourced installer functions.
# shellcheck disable=SC2034,SC2120,SC2329
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/outputs/v2ray-onekey-new.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

source_only_output="$(
  SCRIPT="$SCRIPT" bash 2>&1 <<'BASH'
set +e
set +E
set +u
set +o pipefail

record_option_state() {
  OPTION_STATE=""
  [[ "$-" == *e* ]] && OPTION_STATE+="e" || OPTION_STATE+="-"
  [[ "$-" == *E* ]] && OPTION_STATE+="E" || OPTION_STATE+="-"
  [[ "$-" == *u* ]] && OPTION_STATE+="u" || OPTION_STATE+="-"
  shopt -qo pipefail && OPTION_STATE+="p" || OPTION_STATE+="-"
}

id() {
  printf 'root check ran while sourcing\n' >&2
  printf '1000\n'
}

set -- --definitely-unknown-option dummy-value
record_option_state
before_state="$OPTION_STATE"
[[ "$before_state" == "----" ]] || {
  printf 'expected disabled shell options, got %s\n' "$before_state" >&2
  exit 1
}

V2RAY_ONEKEY_SOURCE_ONLY=1
source "$SCRIPT"
source_status=$?

[[ "$source_status" -eq 0 ]] || {
  printf 'source returned %s\n' "$source_status" >&2
  exit 1
}
declare -F main >/dev/null || {
  printf 'main is not defined after sourcing\n' >&2
  exit 1
}
[[ "$#" -eq 2 ]] || {
  printf 'sourcing changed positional argument count to %s\n' "$#" >&2
  exit 1
}
[[ "${1-}" == "--definitely-unknown-option" && "${2-}" == "dummy-value" ]] || {
  printf 'sourcing changed positional arguments\n' >&2
  exit 1
}

record_option_state
after_state="$OPTION_STATE"
[[ "$after_state" == "$before_state" ]] || {
  printf 'sourcing changed shell options from %s to %s\n' "$before_state" "$after_state" >&2
  exit 1
}

printf 'PASS: source-only mode is definition-only\n'
BASH
)" || fail "source-only subprocess failed: $source_only_output"

printf '%s\n' "$source_only_output"

export V2RAY_ONEKEY_SOURCE_ONLY=1
# shellcheck source=../outputs/v2ray-onekey-new.sh
source "$SCRIPT"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "$actual" == "$expected" ]] || fail "$message: expected '$expected', got '$actual'"
}

assert_fails() {
  local expected="$1"
  shift
  local output=""
  if output="$("$@" 2>&1)"; then
    fail "expected command to fail: $*"
  fi
  [[ "$output" == *"$expected"* ]] || fail "failure did not contain '$expected': $output"
}

expected_state_keys="STATE_SCHEMA MODE DOMAIN EMAIL CLOUDFLARE_PORT INTERNAL_WS_PORT CLOUDFLARE_UUID WS_PATH HY2_PORT_RANGE HY2_AUTH HY2_OBFS_PASSWORD HY2_SNI HY2_CERT_PIN SS_PORT SS_METHOD SS_KEY SERVER_ADDRESS ALLOW_BITTORRENT ALLOW_MAIL"
SS_TEST_KEY="MDEyMzQ1Njc4OWFiY2RlZg=="
assert_state_keys() {
  local actual
  actual="$(printf '%s ' "${STATE_KEYS[@]}")"
  assert_eq "$expected_state_keys" "${actual% }" "schema 2 state keys"
}

assert_state_keys

reset_options
MODE="direct"
resolve_default_ports
assert_eq "" "$CLOUDFLARE_PORT" "direct Cloudflare port"
assert_eq "20000-20100" "$HY2_PORT_RANGE" "direct Hysteria2 port range"
assert_eq "8388" "$SS_PORT" "direct Shadowsocks port"
assert_eq "2022-blake3-aes-128-gcm" "$SS_METHOD" "direct Shadowsocks method"
mode_needs_domain && fail "direct mode must not require a domain"
mode_has_cloudflare && fail "direct mode must not include Cloudflare"
mode_has_hysteria || fail "direct mode must include Hysteria2"
mode_has_shadowsocks || fail "direct mode must include Shadowsocks"

reset_options
MODE="cloudflare"
resolve_default_ports
assert_eq "443" "$CLOUDFLARE_PORT" "cloudflare port"
assert_eq "" "$HY2_PORT_RANGE" "cloudflare Hysteria2 range"
assert_eq "" "$SS_PORT" "cloudflare Shadowsocks port"
assert_eq "" "$SS_METHOD" "cloudflare Shadowsocks method"
mode_needs_domain || fail "cloudflare mode must require a domain"
mode_has_cloudflare || fail "cloudflare mode must include Cloudflare"
mode_has_hysteria && fail "cloudflare mode must not include Hysteria2"
mode_has_shadowsocks && fail "cloudflare mode must not include Shadowsocks"

reset_options
MODE="full"
resolve_default_ports
assert_eq "443" "$CLOUDFLARE_PORT" "full Cloudflare port"
assert_eq "20000-20100" "$HY2_PORT_RANGE" "full Hysteria2 port range"
assert_eq "8388" "$SS_PORT" "full Shadowsocks port"
assert_eq "2022-blake3-aes-128-gcm" "$SS_METHOD" "full Shadowsocks method"
mode_needs_domain || fail "full mode must require a domain"
mode_has_cloudflare || fail "full mode must include Cloudflare"
mode_has_hysteria || fail "full mode must include Hysteria2"
mode_has_shadowsocks || fail "full mode must include Shadowsocks"

reset_options
menu_output="$(choose_mode <<<"3")"
choose_mode <<<"3" >/dev/null
assert_eq "full" "$MODE" "menu choice 3"
assert_eq $'1) Direct: Hysteria2 + Shadowsocks 2022 (no domain)\n2) Cloudflare: VLESS + WebSocket + TLS\n3) Full: Cloudflare + Hysteria2 + Shadowsocks 2022 (recommended)' "$menu_output" "interactive menu text"
reset_options
choose_mode <<<"1" >/dev/null
assert_eq "direct" "$MODE" "menu choice 1"
reset_options
choose_mode <<<"2" >/dev/null
assert_eq "cloudflare" "$MODE" "menu choice 2"

valid_domain "vpn.example.com" || fail "valid domain rejected"
valid_domain "bad_domain" && fail "invalid domain accepted"
valid_port "65535" || fail "valid port rejected"
valid_port "65536" && fail "invalid port accepted"
for cloudflare_port in 443 2053 2083 2087 2096 8443; do
  valid_cloudflare_port "$cloudflare_port" || fail "official Cloudflare port rejected: $cloudflare_port"
done
valid_cloudflare_port 2443 && fail "unsupported Cloudflare port accepted"
valid_port "18446744073709551617" && fail "overflowing port accepted"
valid_port "00008" || fail "leading-zero decimal port rejected"
assert_eq "8" "$(normalize_port 00008)" "normalized decimal port"
assert_eq "0" "$(normalize_port 00000)" "normalized all-zero port"
valid_port "00000" && fail "all-zero port accepted"
valid_hy2_port_range "1-1000" || fail "valid Hysteria2 range rejected"
valid_hy2_port_range "20000-20100" || fail "default Hysteria2 range rejected"
valid_hy2_port_range "20000" && fail "single Hysteria2 port accepted as a range"
valid_hy2_port_range "0-100" && fail "zero Hysteria2 range bound accepted"
valid_hy2_port_range "100-99" && fail "reversed Hysteria2 range accepted"
valid_hy2_port_range "1-1001" && fail "Hysteria2 range larger than 1000 ports accepted"
valid_hy2_port_range "65000-65536" && fail "out-of-bounds Hysteria2 range accepted"
valid_server_address "vpn.example.com" || fail "domain server address rejected"
valid_server_address "192.0.2.1" || fail "IPv4 server address rejected"
valid_server_address "2001:db8::1" || fail "IPv6 server address rejected"
valid_server_address "203.0.113.999" && fail "malformed IPv4 server address accepted"
valid_server_address "001.002.003.004" && fail "non-canonical IPv4 server address accepted"
valid_server_address "bad address" && fail "server address containing whitespace accepted"
valid_server_address "https://vpn.example.com" && fail "URL accepted as server address"

reset_options
parse_args \
  --mode full \
  --domain vpn.example.com \
  --email admin@example.com \
  --cloudflare-port 2053 \
  --hy2-port-range 22000-22100 \
  --ss-port 18388 \
  --server-address edge.example.net \
  --cloudflare-uuid 22222222-2222-4222-8222-222222222222 \
  --ws-path /private \
  --rotate \
  --allow-bittorrent \
  --allow-mail
assert_eq "full" "$MODE" "parsed mode"
assert_eq "vpn.example.com" "$DOMAIN" "parsed domain"
assert_eq "admin@example.com" "$EMAIL" "parsed email"
assert_eq "2053" "$CLOUDFLARE_PORT" "parsed Cloudflare port"
assert_eq "22000-22100" "$HY2_PORT_RANGE" "parsed Hysteria2 range"
assert_eq "18388" "$SS_PORT" "parsed Shadowsocks port"
assert_eq "edge.example.net" "$SERVER_ADDRESS" "parsed server address"
assert_eq "22222222-2222-4222-8222-222222222222" "$CLOUDFLARE_UUID" "parsed Cloudflare UUID"
assert_eq "/private" "$WS_PATH" "parsed WebSocket path"
assert_eq "1" "$ROTATE" "parsed rotate flag"
assert_eq "1" "$ALLOW_BITTORRENT" "parsed BitTorrent flag"
assert_eq "1" "$ALLOW_MAIL" "parsed mail flag"

usage_output="$(usage)"
for option in --mode --domain --email --cloudflare-port --hy2-port-range --ss-port --server-address --cloudflare-uuid --ws-path --rotate --allow-bittorrent --allow-mail --help; do
  [[ "$usage_output" == *"$option"* ]] || fail "usage is missing $option"
done
[[ "$usage_output" == *'direct|cloudflare|full'* ]] || fail "usage does not list the supported modes"
[[ "$usage_output" != *"--reality-"* ]] || fail "usage still exposes REALITY options"
[[ "$usage_output" != *$'\n  --port '* ]] || fail "usage still exposes legacy --port"
[[ "$usage_output" != *"--tcp"* ]] || fail "usage still exposes legacy --tcp"
assert_fails "--mode must be direct, cloudflare, or full" parse_args --mode reality
assert_fails "--mode must be direct, cloudflare, or full" parse_args --mode dual
for retired_option in --reality-port --reality-target --reality-uuid; do
  assert_fails "Unknown option" parse_args "$retired_option" retired-value
done

validate_cli_options() {
  reset_options
  parse_args "$@"
  validate_options
}

assert_fails "Invalid Hysteria2 port range" validate_cli_options \
  --mode cloudflare --domain vpn.example.com --email admin@example.com --hy2-port-range invalid
assert_fails "Invalid Shadowsocks port" validate_cli_options \
  --mode cloudflare --domain vpn.example.com --email admin@example.com --ss-port 70000
assert_fails "Invalid server address" validate_cli_options \
  --mode cloudflare --domain vpn.example.com --email admin@example.com --server-address 'bad address'
assert_fails "Unsupported Cloudflare port" validate_cli_options \
  --mode direct --cloudflare-port 2443
assert_fails "Invalid domain" validate_cli_options --mode direct --domain bad_domain
assert_fails "Invalid Cloudflare UUID" validate_cli_options --mode direct --cloudflare-uuid bad-uuid
assert_fails "WebSocket path" validate_cli_options --mode direct --ws-path invalid

for direct_option in \
  '--hy2-port-range 21000-21100' \
  '--ss-port 18388' \
  '--server-address edge.example.com'; do
  read -r option value <<<"$direct_option"
  assert_fails "$option cannot be used with cloudflare mode" validate_cli_options \
    --mode cloudflare --domain vpn.example.com --email admin@example.com "$option" "$value"
done
for cloudflare_option in \
  '--cloudflare-port 2053' \
  '--domain vpn.example.com' \
  '--email admin@example.com' \
  '--cloudflare-uuid 22222222-2222-4222-8222-222222222222' \
  '--ws-path /private'; do
  read -r option value <<<"$cloudflare_option"
  assert_fails "$option cannot be used with direct mode" validate_cli_options \
    --mode direct "$option" "$value"
done

validate_values() {
  reset_options
  MODE="$1"
  DOMAIN="$2"
  EMAIL="$3"
  CLOUDFLARE_PORT="$4"
  HY2_PORT_RANGE="$5"
  SS_PORT="$6"
  SERVER_ADDRESS="$7"
  CLOUDFLARE_UUID="${8:-}"
  WS_PATH="${9:-}"
  validate_options
}

validate_values direct "" "" "" "" "" "vpn.example.com"
assert_eq "" "$CLOUDFLARE_PORT" "validated inactive Cloudflare port"
assert_eq "20000-20100" "$HY2_PORT_RANGE" "validated default Hysteria2 range"
assert_eq "8388" "$SS_PORT" "validated default Shadowsocks port"

validate_values full vpn.example.com admin@example.com 2053 22000-22100 18388 edge.example.net
assert_eq "2053" "$CLOUDFLARE_PORT" "custom Cloudflare port"
assert_eq "22000-22100" "$HY2_PORT_RANGE" "custom Hysteria2 range"
assert_eq "18388" "$SS_PORT" "custom Shadowsocks port"

validate_values full vpn.example.com admin@example.com 02053 02000-02010 08388 192.0.2.1
assert_eq "2053" "$CLOUDFLARE_PORT" "canonical Cloudflare port"
assert_eq "2000-2010" "$HY2_PORT_RANGE" "canonical Hysteria2 range"
assert_eq "8388" "$SS_PORT" "canonical Shadowsocks port"

validate_values cloudflare vpn.example.com admin@example.com "" "" "" "" "" "/valid._~-"

reset_options
MODE="cloudflare"
DOMAIN="vpn.example.com"
EMAIL="admin@example.com"
HY2_PORT_RANGE="21000-21100"
HY2_AUTH="inactive-auth"
HY2_OBFS_PASSWORD="inactive-obfs"
HY2_SNI="inactive.example.com"
HY2_CERT_PIN="inactive-pin"
SS_PORT="18388"
SS_METHOD="2022-blake3-aes-128-gcm"
SS_KEY="inactive-key"
SERVER_ADDRESS="edge.example.com"
resolve_default_ports
assert_eq "" "$HY2_PORT_RANGE$HY2_AUTH$HY2_OBFS_PASSWORD$HY2_SNI$HY2_CERT_PIN" "inactive Hysteria2 fields"
assert_eq "" "$SS_PORT$SS_METHOD$SS_KEY" "inactive Shadowsocks fields"
assert_eq "" "$SERVER_ADDRESS" "inactive direct server address"

reset_options
MODE="direct"
DOMAIN="vpn.example.com"
EMAIL="admin@example.com"
CLOUDFLARE_PORT="2053"
INTERNAL_WS_PORT="31001"
CLOUDFLARE_UUID="22222222-2222-4222-8222-222222222222"
WS_PATH="/inactive"
resolve_default_ports
assert_eq "" "$DOMAIN$EMAIL$CLOUDFLARE_PORT$INTERNAL_WS_PORT$CLOUDFLARE_UUID$WS_PATH" "inactive Cloudflare fields"

reset_options
assert_fails "--mode is required" select_mode </dev/null
for option in --mode --domain --email --cloudflare-port --hy2-port-range --ss-port --server-address --cloudflare-uuid --ws-path; do
  assert_fails "$option requires a value" parse_args "$option"
done
assert_fails "--domain is required" validate_values cloudflare "" admin@example.com "" "" "" ""
assert_fails "--email is required" validate_values cloudflare vpn.example.com "" "" "" "" ""
assert_fails "Invalid domain" validate_values cloudflare bad_domain admin@example.com "" "" "" ""
assert_fails "Unsupported Cloudflare port" validate_values full vpn.example.com admin@example.com 2443 20000-20100 8388 edge.example.net
assert_fails "Invalid Hysteria2 port range" validate_values direct "" "" "" 20100-20000 8388 edge.example.net
assert_fails "Invalid Shadowsocks port" validate_values direct "" "" "" 20000-20100 65536 edge.example.net
assert_fails "Invalid server address" validate_values direct "" "" "" 20000-20100 8388 'bad address'

validate_values cloudflare VPN.Example.COM admin@example.com 8443 "" "" ""
assert_eq "vpn.example.com" "$DOMAIN" "Cloudflare domain is normalized to lowercase"
assert_fails "Invalid Cloudflare UUID" validate_values cloudflare vpn.example.com admin@example.com "" "" "" "" bad-uuid
assert_fails "WebSocket path" validate_values cloudflare vpn.example.com admin@example.com "" "" "" "" "" private
assert_fails "WebSocket path" validate_values cloudflare vpn.example.com admin@example.com "" "" "" "" "" '/invalid;path'

test_shadowsocks_key_validation() (
  valid_ss_key "$SS_TEST_KEY" || fail "valid 16-byte Shadowsocks key rejected"
  valid_ss_key "MDEyMzQ1Njc4OWFiY2RlZh==" && fail "non-canonical Shadowsocks key accepted"
  valid_ss_key "MDEyMzQ1Njc4OWFiY2Rl" && fail "15-byte Shadowsocks key accepted"
  valid_ss_key "not-base64" && fail "malformed Shadowsocks key accepted"

  reset_options
  MODE="direct"
  SS_METHOD="aes-256-gcm"
  SS_KEY="$SS_TEST_KEY"
  assert_fails "Invalid Shadowsocks method in state" validate_loaded_runtime_values

  SS_METHOD="2022-blake3-aes-128-gcm"
  SS_KEY="MDEyMzQ1Njc4OWFiY2RlZh=="
  assert_fails "Invalid Shadowsocks key in state" validate_loaded_runtime_values
)

test_shadowsocks_key_validation

assert_sensitive_runtime_not_exported() {
  bash -c '[[ -z ${SS_KEY+x} && -z ${HY2_AUTH+x} && -z ${HY2_OBFS_PASSWORD+x} && -z ${HY2_SNI+x} && -z ${HY2_CERT_PIN+x} && -z ${CLOUDFLARE_UUID+x} && -z ${WS_PATH+x} ]]' ||
    fail "sensitive runtime value was inherited by a child process"
}

test_sensitive_runtime_exports() (
  local temp_dir
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  export SS_KEY="sentinel-ss"
  export HY2_AUTH="sentinel-hy2-auth"
  export HY2_OBFS_PASSWORD="sentinel-hy2-obfs"
  export HY2_SNI="sentinel-hy2-sni"
  export HY2_CERT_PIN="sentinel-hy2-pin"
  export CLOUDFLARE_UUID="sentinel-cf-uuid"
  export WS_PATH="sentinel-ws-path"
  reset_options
  assert_sensitive_runtime_not_exported

  MODE="direct"
  resolve_default_ports
  export SS_KEY=""
  generate_runtime_values
  valid_ss_key "$SS_KEY" || fail "generate path did not create a valid Shadowsocks key"
  assert_sensitive_runtime_not_exported

  STATE_FILE="$temp_dir/state.env"
  MODE="full"
  DOMAIN="vpn.example.com"
  EMAIL="admin@example.com"
  CLOUDFLARE_PORT="443"
  INTERNAL_WS_PORT="31001"
  CLOUDFLARE_UUID="22222222-2222-4222-8222-222222222222"
  WS_PATH="/loaded-path"
  HY2_PORT_RANGE="20000-20100"
  HY2_AUTH="loaded-hy2-auth"
  HY2_OBFS_PASSWORD="loaded-hy2-obfs"
  HY2_SNI="loaded.example.com"
  HY2_CERT_PIN="loaded-pin"
  SS_PORT="8388"
  SS_METHOD="2022-blake3-aes-128-gcm"
  SS_KEY="$SS_TEST_KEY"
  SERVER_ADDRESS="edge.example.com"
  save_state

  export SS_KEY="sentinel-ss"
  export HY2_AUTH="sentinel-hy2-auth"
  export HY2_OBFS_PASSWORD="sentinel-hy2-obfs"
  export HY2_SNI="sentinel-hy2-sni"
  export HY2_CERT_PIN="sentinel-hy2-pin"
  export CLOUDFLARE_UUID="sentinel-cf-uuid"
  export WS_PATH="sentinel-ws-path"
  load_state
  assert_eq "$SS_TEST_KEY" "$SS_KEY" "loaded Shadowsocks key after export cleanup"
  assert_eq "loaded-hy2-auth" "$HY2_AUTH" "loaded Hysteria2 auth after export cleanup"
  assert_eq "22222222-2222-4222-8222-222222222222" "$CLOUDFLARE_UUID" "loaded UUID after export cleanup"
  assert_sensitive_runtime_not_exported
)

test_sensitive_runtime_exports

test_renderers() (
  local temp_dir old_path real_python
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  reset_options
  MODE="full"
  DOMAIN="vpn.example.com"
  CLOUDFLARE_PORT="443"
  INTERNAL_WS_PORT="31001"
  CLOUDFLARE_UUID="22222222-2222-4222-8222-222222222222"
  WS_PATH="/6f4f5304d2e84dc8"
  SS_PORT="8388"
  SS_METHOD="2022-blake3-aes-128-gcm"
  SS_KEY="$SS_TEST_KEY"
  SERVER_ADDRESS="vpn.example.net"
  ALLOW_BITTORRENT="0"

  real_python="$(command -v python3)"
  old_path="$PATH"
  install -d "$temp_dir/bin"
  cat >"$temp_dir/bin/python3" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >>"$PYTHON_ARGV_LOG"
[[ -z ${SS_KEY+x} ]] || printf 'SS_KEY\n' >>"$PYTHON_ENV_LOG"
[[ -z ${HY2_AUTH+x} ]] || printf 'HY2_AUTH\n' >>"$PYTHON_ENV_LOG"
[[ -z ${HY2_OBFS_PASSWORD+x} ]] || printf 'HY2_OBFS_PASSWORD\n' >>"$PYTHON_ENV_LOG"
[[ -z ${HY2_SNI+x} ]] || printf 'HY2_SNI\n' >>"$PYTHON_ENV_LOG"
[[ -z ${HY2_CERT_PIN+x} ]] || printf 'HY2_CERT_PIN\n' >>"$PYTHON_ENV_LOG"
[[ -z ${CLOUDFLARE_UUID+x} ]] || printf 'CLOUDFLARE_UUID\n' >>"$PYTHON_ENV_LOG"
[[ -z ${WS_PATH+x} ]] || printf 'WS_PATH\n' >>"$PYTHON_ENV_LOG"
exec "$REAL_PYTHON" "$@"
EOF
  chmod +x "$temp_dir/bin/python3"
  : >"$temp_dir/python-argv.log"
  : >"$temp_dir/python-env.log"
  export PYTHON_ARGV_LOG="$temp_dir/python-argv.log"
  export PYTHON_ENV_LOG="$temp_dir/python-env.log"
  export REAL_PYTHON="$real_python"
  PATH="$temp_dir/bin:$PATH"
  export SS_KEY HY2_AUTH HY2_OBFS_PASSWORD HY2_SNI HY2_CERT_PIN CLOUDFLARE_UUID WS_PATH

  printf 'old permissive config\n' >"$temp_dir/config.json"
  chmod 0644 "$temp_dir/config.json"
  local old_config_inode
  old_config_inode="$(stat -c '%i' "$temp_dir/config.json")"
  render_xray_config "$temp_dir/config.json"
  assert_eq "600" "$(stat -c '%a' "$temp_dir/config.json")" \
    "replacement config permissions"
  [[ "$(stat -c '%i' "$temp_dir/config.json")" != "$old_config_inode" ]] ||
    fail "renderer did not replace the existing config atomically"
  MODE="direct"
  render_xray_config "$temp_dir/direct.json"
  assert_eq "600" "$(stat -c '%a' "$temp_dir/direct.json")" \
    "new config permissions"
  MODE="cloudflare"
  render_xray_config "$temp_dir/cloudflare.json"
  MODE="full"
  ALLOW_BITTORRENT="1"
  render_xray_config "$temp_dir/allow-bittorrent.json"

  mkdir "$temp_dir/failed-render"
  MODE="cloudflare"
  INTERNAL_WS_PORT="invalid"
  if render_xray_config "$temp_dir/failed-render/config.json" >/dev/null 2>&1; then
    fail "renderer accepted an invalid port"
  fi
  [[ -z "$(find "$temp_dir/failed-render" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
    fail "failed renderer left a temporary file behind"
  INTERNAL_WS_PORT="31001"

  PATH="$old_path"
  unset PYTHON_ARGV_LOG PYTHON_ENV_LOG REAL_PYTHON
  if grep -aFq "$SS_TEST_KEY" "$temp_dir/python-argv.log"; then
    fail "Shadowsocks key was exposed in Python argv"
  fi
  if grep -aFq "2022-blake3-aes-128-gcm:$SS_TEST_KEY" "$temp_dir/python-argv.log"; then
    fail "Shadowsocks authority was exposed in Python argv"
  fi
  [[ ! -s "$temp_dir/python-env.log" ]] ||
    fail "renderer child inherited sensitive variables: $(paste -sd, "$temp_dir/python-env.log")"

  python3 - \
    "$temp_dir/config.json" \
    "$temp_dir/direct.json" \
    "$temp_dir/cloudflare.json" \
    "$temp_dir/allow-bittorrent.json" <<'PY'
import json
import sys


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


full, direct_only, cloudflare_only, allow_bittorrent = map(load, sys.argv[1:])
assert full["log"] == {"loglevel": "warning"}
assert [item["tag"] for item in full["inbounds"]] == [
    "cloudflare-ws-in",
    "shadowsocks-2022-in",
]

cloudflare = full["inbounds"][0]
assert cloudflare["listen"] == "127.0.0.1"
assert cloudflare["port"] == 31001
assert cloudflare["protocol"] == "vless"
assert cloudflare["settings"] == {
    "clients": [
        {
            "id": "22222222-2222-4222-8222-222222222222",
            "email": "cloudflare",
        }
    ],
    "decryption": "none",
}
assert cloudflare["streamSettings"] == {
    "network": "ws",
    "security": "none",
    "wsSettings": {"path": "/6f4f5304d2e84dc8"},
}
sniffing = {
    "enabled": True,
    "destOverride": ["http", "tls", "quic"],
    "routeOnly": True,
}
assert cloudflare["sniffing"] == sniffing
shadowsocks = full["inbounds"][1]
assert shadowsocks == {
    "tag": "shadowsocks-2022-in",
    "listen": "0.0.0.0",
    "port": 8388,
    "protocol": "shadowsocks",
    "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "MDEyMzQ1Njc4OWFiY2RlZg==",
        "network": "tcp,udp",
    },
    "sniffing": sniffing,
}
assert full["outbounds"] == [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"},
]
private_rule = {
    "type": "field",
    "ip": ["geoip:private"],
    "outboundTag": "block",
}
bittorrent_rule = {
    "type": "field",
    "protocol": ["bittorrent"],
    "outboundTag": "block",
}
assert full["routing"] == {
    "domainStrategy": "IPIfNonMatch",
    "rules": [private_rule, bittorrent_rule],
}
assert all(item["protocol"] != "vmess" for item in full["inbounds"])
assert direct_only["inbounds"] == [shadowsocks]
assert [item["tag"] for item in cloudflare_only["inbounds"]] == [
    "cloudflare-ws-in"
]
assert allow_bittorrent["routing"]["rules"] == [private_rule]
assert all(item["tag"] != "reality-in" for item in full["inbounds"])
assert all(item["tag"] != "reality-in" for item in direct_only["inbounds"])
PY

  local cloudflare_link
  ALLOW_BITTORRENT="0"
  cloudflare_link="$(make_cloudflare_link)"
  python3 - "$cloudflare_link" <<'PY'
import sys
import urllib.parse


def parse_link(link):
    assert link.startswith("vless://")
    parsed = urllib.parse.urlsplit(link)
    query = urllib.parse.parse_qs(parsed.query, strict_parsing=True)
    assert urllib.parse.quote(
        urllib.parse.unquote(parsed.fragment), safe=""
    ) == parsed.fragment
    return parsed, {key: values[0] for key, values in query.items()}


cloudflare, cloudflare_query = parse_link(sys.argv[1])
assert cloudflare.username == "22222222-2222-4222-8222-222222222222"
assert cloudflare.hostname == "vpn.example.com"
assert cloudflare.port == 443
assert cloudflare_query["encryption"] == "none"
assert cloudflare_query["security"] == "tls"
assert cloudflare_query["sni"] == "vpn.example.com"
assert cloudflare_query["host"] == "vpn.example.com"
assert cloudflare_query["fp"] == "chrome"
assert cloudflare_query["type"] == "ws"
assert cloudflare_query["path"] == "/6f4f5304d2e84dc8"
assert "path=%2F6f4f5304d2e84dc8" in cloudflare.query
assert urllib.parse.unquote(cloudflare.fragment) == "VLESS-Cloudflare-fallback"
PY

  local ss_ipv4 ss_ipv6 ss_hostname
  MODE="direct"
  SS_PORT="8388"
  SS_METHOD="2022-blake3-aes-128-gcm"
  SS_KEY="$SS_TEST_KEY"
  SERVER_ADDRESS="192.0.2.10"
  ss_ipv4="$(make_shadowsocks_link)"
  SERVER_ADDRESS="2001:db8::10"
  ss_ipv6="$(make_shadowsocks_link)"
  SERVER_ADDRESS="vpn.example.net"
  ss_hostname="$(make_shadowsocks_link)"

  printf '%s\0%s\0%s\0' "$ss_ipv4" "$ss_ipv6" "$ss_hostname" |
    python3 - 3<&0 <<'PY'
import base64
import os
import urllib.parse


links = os.fdopen(3, "rb").read().decode("utf-8").split("\0")[:-1]
expected_hosts = ["192.0.2.10", "2001:db8::10", "vpn.example.net"]
for link, expected_host in zip(links, expected_hosts):
    parsed = urllib.parse.urlsplit(link)
    assert parsed.scheme == "ss"
    assert parsed.hostname == expected_host
    assert parsed.port == 8388
    assert parsed.password is None
    assert parsed.username is not None and "=" not in parsed.username
    padding = "=" * ((4 - len(parsed.username) % 4) % 4)
    authority = base64.urlsafe_b64decode(parsed.username + padding).decode("utf-8")
    assert authority == "2022-blake3-aes-128-gcm:MDEyMzQ1Njc4OWFiY2RlZg=="
    assert urllib.parse.unquote(parsed.fragment) == "Shadowsocks-2022-direct"
assert "@[2001:db8::10]:8388" in links[1]
PY

)

test_renderers

test_state_round_trip() (
  local temp_dir old_inode malicious_value old_path real_python secret
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  STATE_FILE="$temp_dir/private/state.env"
  malicious_value='$(touch SHOULD_NOT_EXIST); spaces and $dollar'

  reset_options
  MODE="full"
  DOMAIN="vpn.example.com"
  EMAIL="$malicious_value"
  CLOUDFLARE_PORT="443"
  INTERNAL_WS_PORT="31001"
  CLOUDFLARE_UUID="22222222-2222-4222-8222-222222222222"
  WS_PATH="/state-path"
  HY2_PORT_RANGE="20000-20100"
  HY2_AUTH="hy2-auth"
  HY2_OBFS_PASSWORD="hy2-obfs"
  HY2_SNI="hy2.example.com"
  HY2_CERT_PIN="sha256:cert-pin"
  SS_PORT="8388"
  SS_METHOD="2022-blake3-aes-128-gcm"
  SS_KEY="$SS_TEST_KEY"
  SERVER_ADDRESS="edge.example.com"
  ALLOW_BITTORRENT="1"
  ALLOW_MAIL="1"
  save_state
  assert_eq "700" "$(stat -c '%a' "$temp_dir/private")" "state directory permissions"
  assert_eq "600" "$(stat -c '%a' "$STATE_FILE")" "state file permissions"
  [[ ! -e SHOULD_NOT_EXIST ]] || fail "state data was executed"
  grep -Fq 'EMAIL=\$\(touch\ SHOULD_NOT_EXIST\)\;\ spaces\ and\ \$dollar' "$STATE_FILE" ||
    fail "state data was not shell escaped"
  grep -Fqx 'STATE_SCHEMA=2' "$STATE_FILE" || fail "state schema 2 was not written"
  assert_eq "${#STATE_KEYS[@]}" "$(wc -l <"$STATE_FILE" | tr -d ' ')" "schema 2 key count"

  real_python="$(command -v python3)"
  old_path="$PATH"
  install -d "$temp_dir/bin"
  cat >"$temp_dir/bin/python3" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >>"$PYTHON_ARGV_LOG"
exec "$REAL_PYTHON" "$@"
EOF
  chmod +x "$temp_dir/bin/python3"
  : >"$temp_dir/python-argv.log"
  export PYTHON_ARGV_LOG="$temp_dir/python-argv.log"
  export REAL_PYTHON="$real_python"
  PATH="$temp_dir/bin:$PATH"
  reset_options
  load_state
  PATH="$old_path"
  unset PYTHON_ARGV_LOG REAL_PYTHON
  assert_eq "2" "$STATE_SCHEMA" "loaded state schema"
  assert_eq "full" "$MODE" "loaded mode"
  assert_eq "vpn.example.com" "$DOMAIN" "loaded domain"
  assert_eq "$malicious_value" "$EMAIL" "loaded shell-metacharacter value"
  assert_eq "443" "$CLOUDFLARE_PORT" "loaded Cloudflare port"
  assert_eq "31001" "$INTERNAL_WS_PORT" "loaded internal WS port"
  assert_eq "22222222-2222-4222-8222-222222222222" "$CLOUDFLARE_UUID" "loaded Cloudflare UUID"
  assert_eq "/state-path" "$WS_PATH" "loaded WS path"
  assert_eq "20000-20100" "$HY2_PORT_RANGE" "loaded Hysteria2 range"
  assert_eq "hy2-auth" "$HY2_AUTH" "loaded Hysteria2 auth"
  assert_eq "hy2-obfs" "$HY2_OBFS_PASSWORD" "loaded Hysteria2 obfuscation password"
  assert_eq "hy2.example.com" "$HY2_SNI" "loaded Hysteria2 SNI"
  assert_eq "sha256:cert-pin" "$HY2_CERT_PIN" "loaded Hysteria2 certificate pin"
  assert_eq "8388" "$SS_PORT" "loaded Shadowsocks port"
  assert_eq "2022-blake3-aes-128-gcm" "$SS_METHOD" "loaded Shadowsocks method"
  assert_eq "$SS_TEST_KEY" "$SS_KEY" "loaded Shadowsocks key"
  assert_eq "edge.example.com" "$SERVER_ADDRESS" "loaded server address"
  assert_eq "1" "$ALLOW_BITTORRENT" "loaded BitTorrent setting"
  assert_eq "1" "$ALLOW_MAIL" "loaded mail setting"
  assert_eq "0" "$ROTATE" "rotate is not persisted"
  for secret in \
    22222222-2222-4222-8222-222222222222 \
    /state-path \
    hy2-auth \
    hy2-obfs \
    "$SS_TEST_KEY"; do
    if grep -aFq "$secret" "$temp_dir/python-argv.log"; then
      fail "state secret was exposed in Python argv: $secret"
    fi
  done

  printf 'old permissive state\n' >"$STATE_FILE"
  chmod 0666 "$STATE_FILE"
  old_inode="$(stat -c '%i' "$STATE_FILE")"
  save_state
  assert_eq "600" "$(stat -c '%a' "$STATE_FILE")" "replaced state permissions"
  [[ "$(stat -c '%i' "$STATE_FILE")" != "$old_inode" ]] ||
    fail "state file was not atomically replaced"
  [[ -z "$(find "$temp_dir/private" -name '.state.env.*' -print -quit)" ]] ||
    fail "state save left a temporary file behind"
)

test_state_security() (
  local temp_dir
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  STATE_FILE="$temp_dir/state.env"
  cat >"$STATE_FILE" <<'EOF'
STATE_SCHEMA=2
MODE=cloudflare
DOMAIN=vpn.example.com
EMAIL=admin@example.com
CLOUDFLARE_PORT=443
INTERNAL_WS_PORT=31001
CLOUDFLARE_UUID=22222222-2222-4222-8222-222222222222
WS_PATH=/ws
HY2_PORT_RANGE=''
HY2_AUTH=''
HY2_OBFS_PASSWORD=''
HY2_SNI=''
HY2_CERT_PIN=''
SS_PORT=''
SS_METHOD=''
SS_KEY=''
SERVER_ADDRESS=edge.example.com
ALLOW_BITTORRENT=0
ALLOW_MAIL=0
EOF
  chmod 0660 "$STATE_FILE"
  assert_fails "group or world writable" load_state
  chmod 0600 "$STATE_FILE"
  if [[ "$(id -u)" -eq 0 ]]; then
    chown 1234 "$STATE_FILE"
    assert_fails "must be owned by root" load_state
    load_state_as_source_only() { V2RAY_ONEKEY_SOURCE_ONLY=1 load_state; }
    assert_fails "must be owned by root" load_state_as_source_only
    chown 0 "$STATE_FILE"
    load_state_as_source_only
  fi
  sed -i "s/^CLOUDFLARE_UUID=.*/CLOUDFLARE_UUID=''/" "$STATE_FILE"
  assert_fails "Invalid Cloudflare UUID" load_state
  sed -i 's/^CLOUDFLARE_UUID=.*/CLOUDFLARE_UUID=22222222-2222-4222-8222-222222222222/' "$STATE_FILE"
  sed -i 's|^WS_PATH=.*|WS_PATH=invalid|' "$STATE_FILE"
  assert_fails "WebSocket path" load_state
  sed -i 's|^WS_PATH=.*|WS_PATH=/ws|' "$STATE_FILE"
  sed -i 's|^WS_PATH=.*|WS_PATH=/ws\\;\\$\\(touch\\ SHOULD_NOT_EXIST\\)|' "$STATE_FILE"
  assert_fails "WebSocket path" load_state
  [[ ! -e SHOULD_NOT_EXIST ]] || fail "invalid WebSocket path executed state data"
  sed -i 's|^WS_PATH=.*|WS_PATH=/ws|' "$STATE_FILE"
  sed -i 's/^DOMAIN=.*/DOMAIN=bad_domain/' "$STATE_FILE"
  assert_fails "Invalid domain" load_state
  sed -i 's/^DOMAIN=.*/DOMAIN=vpn.example.com/' "$STATE_FILE"
  sed -i 's/^STATE_SCHEMA=.*/STATE_SCHEMA=3/' "$STATE_FILE"
  assert_fails "Unsupported state schema" load_state
  sed -i 's/^STATE_SCHEMA=.*/STATE_SCHEMA=2/' "$STATE_FILE"
  printf 'REALITY_UUID=11111111-1111-4111-8111-111111111111\n' >>"$STATE_FILE"
  assert_fails "Schema 2 state contains unexpected assignment: REALITY_UUID" load_state
  printf 'STATE_SCHEMA=2\nMODE=direct\nEVIL=$(touch SHOULD_NOT_EXIST)\n' >"$STATE_FILE"
  assert_fails "unexpected assignment" load_state
  [[ ! -e SHOULD_NOT_EXIST ]] || fail "untrusted state line was executed"
)

test_legacy_state_migration() (
  local temp_dir mutation_log
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  STATE_FILE="$temp_dir/state.env"
  cat >"$STATE_FILE" <<'EOF'
MODE=dual
DOMAIN=vpn.example.com
EMAIL=admin@example.com
REALITY_PORT=1443
CLOUDFLARE_PORT=2053
INTERNAL_WS_PORT=31001
REALITY_UUID=11111111-1111-4111-8111-111111111111
CLOUDFLARE_UUID=22222222-2222-4222-8222-222222222222
REALITY_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
REALITY_PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
REALITY_SHORT_ID=0123456789abcdef
REALITY_TARGET=www.microsoft.com:443
WS_PATH=/legacy-ws
ALLOW_BITTORRENT=1
EOF
  cp "$STATE_FILE" "$temp_dir/reality-state.env"
  sed -i 's/^MODE=dual$/MODE=reality/' "$temp_dir/reality-state.env"
  chmod 0600 "$STATE_FILE"
  reset_options
  load_state
  assert_eq "full" "$MODE" "legacy dual mode migration"
  assert_eq "vpn.example.com" "$DOMAIN" "legacy Cloudflare domain"
  assert_eq "admin@example.com" "$EMAIL" "legacy Cloudflare email"
  assert_eq "2053" "$CLOUDFLARE_PORT" "legacy Cloudflare port"
  assert_eq "31001" "$INTERNAL_WS_PORT" "legacy internal WebSocket port"
  assert_eq "22222222-2222-4222-8222-222222222222" "$CLOUDFLARE_UUID" "legacy Cloudflare UUID"
  assert_eq "/legacy-ws" "$WS_PATH" "legacy WebSocket path"
  assert_eq "" "${REALITY_UUID-}" "legacy REALITY UUID discarded"
  assert_eq "" "${REALITY_PRIVATE_KEY-}" "legacy REALITY private key discarded"
  save_state
  grep -Fqx 'STATE_SCHEMA=2' "$STATE_FILE" || fail "legacy state was not upgraded to schema 2"
  grep -q 'REALITY' "$STATE_FILE" && fail "schema 2 state contains retired REALITY data"
  :

  STATE_FILE="$temp_dir/reality-state.env"
  chmod 0600 "$STATE_FILE"
  mutation_log="$temp_dir/mutations.log"
  reset_options
  deploy_services() { printf 'deploy\n' >>"$mutation_log"; }
  attempt_reality_only_migration() {
    prepare_configuration
    deploy_services
  }
  assert_fails "Automatic REALITY-only migration is unsafe" attempt_reality_only_migration
  [[ ! -e "$mutation_log" ]] || fail "legacy REALITY-only state reached deployment"
)

test_state_round_trip
test_state_security
test_legacy_state_migration

test_runtime_generation() (
  local temp_dir old_path
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  old_path="$PATH"
  PATH="$temp_dir:$PATH"
  cat >"$temp_dir/xray" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  'uuid ') printf '%s\n' 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' ;;
  *) exit 1 ;;
esac
EOF
  cat >"$temp_dir/openssl" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2 $3" == 'rand -hex 12' ]] && { printf '0123456789abcdef01234567\n'; exit; }
[[ "$1 $2 $3" == 'rand -base64 16' ]] && { printf 'YWJjZGVmZ2hpamtsbW5vcA==\n'; exit; }
if [[ "$1 $2" == 'base64 -d' && "${3:-}" == '-A' ]]; then
  exec /usr/bin/openssl "$@"
fi
if [[ "$1 $2" == 'base64 -A' ]]; then
  exec /usr/bin/openssl "$@"
fi
exit 1
EOF
  cat >"$temp_dir/shuf" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *'20000-50000'* ]] || exit 1
printf '31001\n'
EOF
  chmod +x "$temp_dir/xray" "$temp_dir/openssl" "$temp_dir/shuf"

  reset_options
  MODE="direct"
  generate_runtime_values
  assert_eq "" "$CLOUDFLARE_UUID" "direct mode does not generate Cloudflare UUID"
  assert_eq "" "$INTERNAL_WS_PORT" "direct mode does not generate internal port"
  assert_eq "" "$WS_PATH" "direct mode does not generate WS path"
  assert_eq "2022-blake3-aes-128-gcm" "$SS_METHOD" "generated Shadowsocks method"
  assert_eq "YWJjZGVmZ2hpamtsbW5vcA==" "$SS_KEY" "generated Shadowsocks key"

  reset_options
  MODE="cloudflare"
  generate_runtime_values
  assert_eq "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" "$CLOUDFLARE_UUID" "generated Cloudflare UUID"
  assert_eq "31001" "$INTERNAL_WS_PORT" "generated internal port"
  assert_eq "/0123456789abcdef01234567" "$WS_PATH" "generated WS path"

  reset_options
  MODE="full"
  CLOUDFLARE_PORT="443"
  generate_runtime_values
  [[ -n "$CLOUDFLARE_UUID" ]] || fail "full mode did not generate Cloudflare credentials"
  CLOUDFLARE_UUID="existing-cloudflare"
  INTERNAL_WS_PORT="32001"
  WS_PATH="/existing"
  SS_KEY="$SS_TEST_KEY"
  generate_runtime_values
  assert_eq "existing-cloudflare" "$CLOUDFLARE_UUID" "existing Cloudflare UUID reused"
  assert_eq "32001" "$INTERNAL_WS_PORT" "existing internal port reused"
  assert_eq "/existing" "$WS_PATH" "existing path reused"
  assert_eq "$SS_TEST_KEY" "$SS_KEY" "existing Shadowsocks key reused"

  reset_options
  MODE="full"
  DOMAIN="vpn.example.com"
  EMAIL="admin@example.com"
  CLOUDFLARE_PORT="443"
  HY2_PORT_RANGE="20000-20100"
  SS_PORT="8388"
  SERVER_ADDRESS="edge.example.com"
  ALLOW_BITTORRENT="1"
  ALLOW_MAIL="1"
  CLOUDFLARE_UUID="two"
  INTERNAL_WS_PORT="31001"
  WS_PATH="/six"
  HY2_AUTH="seven"
  HY2_OBFS_PASSWORD="eight"
  HY2_SNI="nine"
  HY2_CERT_PIN="ten"
  SS_METHOD="2022-blake3-aes-128-gcm"
  SS_KEY="$SS_TEST_KEY"
  rotate_runtime_values
  [[ -z "$CLOUDFLARE_UUID$INTERNAL_WS_PORT$WS_PATH$HY2_AUTH$HY2_OBFS_PASSWORD$HY2_SNI$HY2_CERT_PIN$SS_KEY" ]] ||
    fail "rotate did not clear generated runtime values"
  assert_eq "full" "$MODE" "rotate retains mode"
  assert_eq "vpn.example.com" "$DOMAIN" "rotate retains domain"
  assert_eq "admin@example.com" "$EMAIL" "rotate retains email"
  assert_eq "443" "$CLOUDFLARE_PORT" "rotate retains Cloudflare port"
  assert_eq "20000-20100" "$HY2_PORT_RANGE" "rotate retains Hysteria2 range"
  assert_eq "8388" "$SS_PORT" "rotate retains Shadowsocks port"
  assert_eq "edge.example.com" "$SERVER_ADDRESS" "rotate retains server address"
  assert_eq "1" "$ALLOW_BITTORRENT" "rotate retains BitTorrent setting"
  assert_eq "1" "$ALLOW_MAIL" "rotate retains mail setting"
  generate_runtime_values
  assert_eq "YWJjZGVmZ2hpamtsbW5vcA==" "$SS_KEY" "rotate generated a new Shadowsocks key"
  [[ "$SS_KEY" != "$SS_TEST_KEY" ]] || fail "rotate reused the old Shadowsocks key"
  PATH="$old_path"
)

test_runtime_generation

test_cloudflare_preflight() (
  local temp_dir old_path
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  CLOUDFLARE_IPV4_FILE="$temp_dir/ips-v4"
  CLOUDFLARE_IPV6_FILE="$temp_dir/ips-v6"
  printf '%s\n' '104.16.0.0/13' >"$CLOUDFLARE_IPV4_FILE"
  printf '%s\n' '2606:4700::/32' >"$CLOUDFLARE_IPV6_FILE"
  address_in_cloudflare_ranges 104.16.1.1 || fail "known Cloudflare IPv4 rejected"
  address_in_cloudflare_ranges 2606:4700::1234 || fail "known Cloudflare IPv6 rejected"
  address_in_cloudflare_ranges 203.0.113.1 && fail "outside IPv4 accepted as Cloudflare"
  address_in_cloudflare_ranges bad-ip && fail "malformed IP accepted as Cloudflare"
  : >"$temp_dir/empty-ranges"
  validate_cloudflare_range_file "$temp_dir/empty-ranges" 4 &&
    fail "empty Cloudflare range file accepted"
  printf ' \n\t\n' >"$temp_dir/whitespace-ranges"
  validate_cloudflare_range_file "$temp_dir/whitespace-ranges" 6 &&
    fail "whitespace-only Cloudflare range file accepted"
  printf '%s\n' '2606:4700::/32' >"$temp_dir/wrong-family-ranges"
  validate_cloudflare_range_file "$temp_dir/wrong-family-ranges" 4 &&
    fail "wrong-family Cloudflare range accepted"
  printf '%s\n' '104.16.1.1/13' >"$temp_dir/non-strict-ranges"
  validate_cloudflare_range_file "$temp_dir/non-strict-ranges" 4 &&
    fail "non-strict Cloudflare range accepted"

  getent() {
    case "$1 $2" in
      'ahostsv4 vpn.example.com') printf '%s\n' '104.16.1.1 STREAM vpn.example.com' ;;
      'ahostsv6 vpn.example.com') printf '%s\n' '2606:4700:0:0:0:0:0:1 STREAM vpn.example.com' ;;
      'ahosts vpn.example.com') printf '%s\n' '104.16.1.1 DGRAM vpn.example.com' ;;
      *) return 1 ;;
    esac
  }
  local resolved
  resolved="$(resolve_host_addresses vpn.example.com)"
  assert_eq $'104.16.1.1\n2606:4700::1' "$resolved" "unique normalized resolved addresses"
  host_resolves_to_cloudflare vpn.example.com || fail "Cloudflare hostname was not recognized"
  DOMAIN="vpn.example.com"
  validate_cloudflare_domain
  getent() {
    case "$1 $2" in
      'ahostsv4 ipv6-only.example.com') return 2 ;;
      'ahostsv6 ipv6-only.example.com') printf '%s\n' '2606:4700:0:0:0:0:0:2 STREAM ipv6-only.example.com' ;;
      'ahosts ipv6-only.example.com') return 2 ;;
      *) return 1 ;;
    esac
  }
  validate_cloudflare_domain ipv6-only.example.com
  getent() { printf '%s\n' '203.0.113.1 STREAM outside.example.com'; }
  host_resolves_to_cloudflare outside.example.com && fail "outside hostname accepted as Cloudflare"
  assert_fails "does not resolve to Cloudflare" validate_cloudflare_domain outside.example.com

  unset CLOUDFLARE_IPV4_FILE CLOUDFLARE_IPV6_FILE
  RUNTIME_DIR="$temp_dir/run"
  curl_log="$temp_dir/curl.log"
  curl() {
    local url="" output="" connect_timeout="" max_time=""
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        -fsS) ;;
        --connect-timeout) connect_timeout="$2"; shift ;;
        --max-time) max_time="$2"; shift ;;
        -o) output="$2"; shift ;;
        https://www.cloudflare.com/ips-v4|https://www.cloudflare.com/ips-v6) url="$1" ;;
        *) return 1 ;;
      esac
      shift
    done
    [[ -n "$output" && "$connect_timeout" -gt 0 && "$max_time" -gt 0 ]] ||
      fail "Cloudflare range download did not set finite timeouts"
    printf '%s %s %s\n' "$url" "$connect_timeout" "$max_time" >>"$curl_log"
    if [[ "$url" == 'https://www.cloudflare.com/ips-v4' ]]; then
      printf '%s\n' '104.16.0.0/13' >"$output"
    else
      printf '%s\n' '2606:4700::/32' >"$output"
    fi
  }
  download_cloudflare_ranges
  assert_eq "2" "$(wc -l <"$curl_log")" "Cloudflare range download count"
  grep -Fq 'https://www.cloudflare.com/ips-v4 10 30' "$curl_log" ||
    fail "IPv4 range download did not receive timeout flags"
  grep -Fq 'https://www.cloudflare.com/ips-v6 10 30' "$curl_log" ||
    fail "IPv6 range download did not receive timeout flags"
  CLOUDFLARE_CONNECT_TIMEOUT=0
  assert_fails "Invalid Cloudflare connect timeout" download_cloudflare_ranges
  CLOUDFLARE_CONNECT_TIMEOUT=abc
  assert_fails "Invalid Cloudflare connect timeout" download_cloudflare_ranges
  CLOUDFLARE_CONNECT_TIMEOUT=10
  CLOUDFLARE_MAX_TIME=301
  assert_fails "Invalid Cloudflare max timeout" download_cloudflare_ranges
  CLOUDFLARE_MAX_TIME=30
  [[ -f "$RUNTIME_DIR/ips-v4" && -f "$RUNTIME_DIR/ips-v6" ]] || fail "range files were not downloaded"
)

test_cloudflare_preflight

test_interim_bundle_readiness() (
  local temp_dir mutation_log
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  mutation_log="$temp_dir/mutations.log"

  reset_options
  MODE="direct"
  uname() { printf 'environment-probe\n' >>"$mutation_log"; printf 'Linux\n'; }
  assert_fails "Direct bundle is not available in this build yet" preflight_environment
  [[ ! -e "$mutation_log" ]] || fail "direct readiness gate ran after environment preflight"

  begin_transaction() { printf 'transaction\n' >>"$mutation_log"; }
  assert_fails "Direct bundle is not available in this build yet" deploy_services
  [[ ! -e "$mutation_log" ]] || fail "direct readiness gate ran after transaction start"

  MODE="full"
  assert_fails "Direct bundle is not available in this build yet" require_mode_ready

  MODE="cloudflare"
  require_mode_ready
)

test_interim_bundle_readiness
printf 'PASS: interim bundle readiness tests\n'

test_environment_preflight() (
  reset_options
  MODE="cloudflare"
  CLOUDFLARE_PORT="8443"
  legacy_nginx_config_path /etc/nginx/conf.d/v2ray-vpn.example.com.conf || fail "legacy Nginx path rejected"
  legacy_nginx_config_path /tmp/v2ray-vpn.example.com.conf && fail "non-project Nginx path accepted"

  nginx() {
    [[ "$1" == '-T' ]] || return 1
    cat <<'NGINX'
# configuration file /etc/nginx/conf.d/v2ray-vpn.example.com.conf:
server {
  listen 8443 ssl;
  location / { return 200 "ok\n"; }
  proxy_set_header Upgrade $http_upgrade;
  proxy_pass http://127.0.0.1:31001;
}
NGINX
  }
  legacy_nginx_config_for_port_is_project_owned 8443 ||
    fail "matching legacy Nginx listener was not recognized"
  legacy_nginx_config_for_port_is_project_owned 443 &&
    fail "legacy Nginx config was accepted for an unrelated port"

  nginx() {
    [[ "$1" == '-T' ]] || return 1
    cat <<'NGINX'
# configuration file /etc/nginx/conf.d/v2ray-vpn.example.com.conf:
server {
  listen 443 ssl;
  location / { return 200 "ok\n"; }
  proxy_set_header Upgrade $http_upgrade;
  proxy_pass http://127.0.0.1:31001;
}
# configuration file /etc/nginx/conf.d/unrelated.conf:
server {
  listen 443 ssl;
}
NGINX
  }
  legacy_nginx_config_for_port_is_project_owned 443 &&
    fail "mixed owned and unrelated Nginx listeners were accepted"

  NGINX_SITE=/etc/nginx/conf.d/v2ray-onekey.conf
  nginx() {
    [[ "$1" == '-T' ]] || return 1
    cat <<'NGINX'
# configuration file /etc/nginx/conf.d/v2ray-onekey.conf:
# Managed by v2ray-onekey
server {
  listen 8443 ssl;
  server_name vpn.example.com;
  location / { return 200 "ok\n"; }
  proxy_set_header Upgrade $http_upgrade;
  proxy_pass http://127.0.0.1:31001;
}
NGINX
  }
  legacy_nginx_config_for_port_is_project_owned 8443 ||
    fail "current managed Nginx site was not recognized on rerun"

  DOMAIN="vpn.example.com"
  nginx() {
    [[ "$1" == '-T' ]] || return 1
    cat <<'NGINX'
# configuration file /etc/nginx/conf.d/v2ray-onekey.conf:
# Managed by v2ray-onekey
server {
  listen 8443 ssl;
  server_name vpn.example.com;
  location / { return 200 "ok\n"; }
  proxy_set_header Upgrade $http_upgrade;
  proxy_pass http://127.0.0.1:31001;
}
# configuration file /etc/nginx/conf.d/unrelated.conf:
server {
  listen 8443 ssl;
  server_name other.example.com;
}
NGINX
  }
  ss() { printf '%s\n' 'LISTEN 0 4096 0.0.0.0:8443 0.0.0.0:* users:(("nginx",pid=1,fd=3))'; }
  port_listener_conflicts cloudflare 8443 &&
    fail "unrelated Nginx virtual host prevented Cloudflare port sharing"

  nginx() {
    [[ "$1" == '-T' ]] || return 1
    cat <<'NGINX'
# configuration file /etc/nginx/conf.d/unrelated.conf:
server {
  listen 8443 ssl;
  server_name vpn.example.com;
}
NGINX
  }
  port_listener_conflicts cloudflare 8443 ||
    fail "same-domain Cloudflare Nginx conflict was not rejected"

  nginx() {
    [[ "$1" == '-T' ]] || return 1
    cat <<'NGINX'
# configuration file /etc/nginx/conf.d/v2ray-mixed.example.com.conf:
server {
  listen 443 ssl;
  server_name vpn.example.com;
  location / { return 200 "ok\n"; }
  proxy_set_header Upgrade $http_upgrade;
  proxy_pass http://127.0.0.1:31001;
}
server {
  listen 443 ssl;
  server_name unrelated.example.com;
}
NGINX
  }
  legacy_nginx_config_for_port_is_project_owned 443 &&
    fail "mixed multi-vhost file was classified wholly project-owned"

  nginx() {
    [[ "$1" == '-T' ]] || return 1
    cat <<'NGINX'
# configuration file /etc/nginx/conf.d/unrelated.conf:
server {
  listen 8443 ssl;
  server_name other.example.com;
}
server {
  listen 443 ssl;
  server_name vpn.example.com;
}
NGINX
  }
  nginx_has_unmanaged_domain_conflict 8443 vpn.example.com &&
    fail "server_name from a different server block caused a false conflict"

  nginx() {
    [[ "$1" == '-T' ]] || return 1
    cat <<'NGINX'
# configuration file /etc/nginx/conf.d/implicit-http.conf:
server {
  server_name vpn.example.com;
}
NGINX
  }
  nginx_has_unmanaged_domain_conflict 80 vpn.example.com ||
    fail "same-domain implicit TCP 80 Nginx block was not rejected"
  nginx_has_unmanaged_domain_conflict 8443 vpn.example.com &&
    fail "implicit TCP 80 Nginx block was treated as a non-80 listener"

  nginx() {
    [[ "$1" == '-T' ]] || return 1
    cat <<'NGINX'
# configuration file /etc/nginx/conf.d/implicit-other.conf:
server {
  server_name other.example.com;
}
NGINX
  }
  nginx_has_unmanaged_domain_conflict 80 vpn.example.com &&
    fail "different-domain implicit TCP 80 block caused a conflict"

  nginx() {
    [[ "$1" == '-T' ]] || return 1
    cat <<'NGINX'
# configuration file /etc/nginx/conf.d/explicit-non-http.conf:
server {
  listen 8443 ssl;
  server_name vpn.example.com;
}
NGINX
  }
  nginx_has_unmanaged_domain_conflict 80 vpn.example.com &&
    fail "explicit non-80 Nginx block was also treated as implicit TCP 80"
  nginx_has_unmanaged_domain_conflict 8443 vpn.example.com ||
    fail "explicit non-80 same-domain Nginx conflict was missed"

  nginx() {
    [[ "$1" == '-T' ]] || return 1
    cat <<'NGINX'
# configuration file /etc/nginx/conf.d/v2ray-vpn.example.com.conf:
server {
  listen 80;
  listen 443 ssl; # managed by Certbot
  server_name vpn.example.com;
  proxy_set_header Upgrade $http_upgrade;
  proxy_pass http://127.0.0.1:31001;
  return 200 "ok\n";
}
server {
  if ($host = vpn.example.com) {
    return 301 https://$host$request_uri;
  } # managed by Certbot
  listen 80;
  server_name vpn.example.com;
  return 404; # managed by Certbot
}
NGINX
  }
  nginx_has_unmanaged_domain_conflict 80 vpn.example.com &&
    fail "Certbot redirect block was treated as an unmanaged ACME conflict"
  legacy_nginx_config_for_port_is_project_owned 80 ||
    fail "Certbot-modified legacy TCP 80 blocks were not recognized"
  legacy_nginx_config_for_port_is_project_owned 443 ||
    fail "Certbot-modified legacy TLS block was not recognized"

  nginx() {
    [[ "$1" == '-T' ]] || return 1
    cat <<'NGINX'
# configuration file /etc/nginx/conf.d/unrelated.conf:
server {
  listen 80;
  server_name other.example.com;
}
NGINX
  }
  ss() { printf '%s\n' 'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=1,fd=3))'; }
  port_listener_conflicts acme 80 &&
    fail "different-domain Nginx HTTP site prevented port 80 sharing"

  nginx() {
    [[ "$1" == '-T' ]] || return 1
    cat <<'NGINX'
# configuration file /etc/nginx/conf.d/unrelated.conf:
server {
  listen 80;
  server_name vpn.example.com;
}
NGINX
  }
  port_listener_conflicts acme 80 ||
    fail "same-domain unmanaged Nginx HTTP site was not rejected"

  ss() {
    if [[ "$*" == '-H -lntp sport = :443' ]]; then
      printf '%s\n' 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=1,fd=3))'
    elif [[ "$*" == '-H -lntp sport = :8443' ]]; then
      :
    elif [[ "$*" == '-H -lntp sport = :80' ]]; then
      :
    elif [[ "$*" == '-lntp' ]]; then
      printf '%s\n' 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process' \
        'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=1,fd=3))'
    else
      return 1
    fi
  }
  CLOUDFLARE_PORT="8443"
  stdin_is_tty() { return 1; }
  local conflict_output=""

  nginx() {
    [[ "$1" == '-T' ]] || return 1
    cat <<'NGINX'
# configuration file /etc/nginx/conf.d/v2ray-vpn.example.com.conf:
server {
  listen 443 ssl;
  location / { return 200 "ok\n"; }
  proxy_set_header Upgrade $http_upgrade;
  proxy_pass http://127.0.0.1:31001;
}
NGINX
  }
  check_public_port_listeners

  MODE="cloudflare"
  CLOUDFLARE_PORT="8443"
  nginx() {
    [[ "$1" == '-T' ]] || return 1
    cat <<'NGINX'
# configuration file /etc/nginx/conf.d/unrelated.conf:
server {
  listen 8443 ssl;
  server_name other.example.com;
}
NGINX
  }
  ss() {
    if [[ "$*" == '-H -lntp sport = :8443' ]]; then
      :
    elif [[ "$*" == '-H -lntp sport = :80' ]]; then
      printf '%s\n' 'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:(("caddy",pid=8,fd=3))'
    elif [[ "$*" == '-lntp' ]]; then
      printf '%s\n' 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process' \
        'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:(("caddy",pid=8,fd=3))' \
        'LISTEN 0 4096 0.0.0.0:9090 0.0.0.0:* users:(("unrelated",pid=9,fd=3))'
    else
      return 1
    fi
  }
  if conflict_output="$(resolve_public_port_conflicts 2>&1)"; then
    fail "noninteractive ACME conflict unexpectedly passed"
  fi
  [[ "$conflict_output" == *'TCP port 80'* && "$conflict_output" == *'ss -lntp output:'* ]] ||
    fail "ACME conflict lacks full listener diagnostics: $conflict_output"
  [[ "$conflict_output" == *'0.0.0.0:9090'* ]] ||
    fail "ACME conflict omitted unrelated full-listener row: $conflict_output"

  INTERNAL_WS_PORT="31001"
  ss() {
    if [[ "$*" == '-H -lntp sport = :31001' ]]; then
      printf '%s\n' 'LISTEN 0 128 127.0.0.1:31001 0.0.0.0:* users:(("other",pid=4,fd=3))'
    elif [[ "$*" == '-H -lntp sport = :32002' ]]; then
      :
    elif [[ "$*" == '-lntp' ]]; then
      printf '%s\n' 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process' \
        'LISTEN 0 128 127.0.0.1:31001 0.0.0.0:* users:(("other",pid=4,fd=3))'
    else
      return 1
    fi
  }
  random_internal_ws_port() { printf '32002\n'; }
  check_internal_ws_port_listener
  assert_eq "32002" "$INTERNAL_WS_PORT" "occupied internal WebSocket port was reselected"

  INTERNAL_WS_PORT="31001"
  ss() { printf '%s\n' 'LISTEN 0 128 127.0.0.1:31001 0.0.0.0:* users:(("xray",pid=4,fd=3))'; }
  check_internal_ws_port_listener
)

test_environment_preflight

test_nginx_and_acme() (
  local temp_dir old_inode certbot_log hook_path output strict_output
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  reset_options
  MODE="cloudflare"
  DOMAIN="VPN.Example.COM"
  EMAIL="admin@example.com"
  CLOUDFLARE_PORT="8443"
  INTERNAL_WS_PORT="31001"
  WS_PATH="/6f4f5304d2e84dc8"
  ACME_WEBROOT="$temp_dir/acme-webroot"
  SS_KEY="private-proxy-secret"
  CLOUDFLARE_UUID="22222222-2222-4222-8222-222222222222"

  printf 'old site\n' >"$temp_dir/site.conf"
  old_inode="$(stat -c '%i' "$temp_dir/site.conf")"
  render_nginx_site "$temp_dir/site.conf" initial
  [[ "$(stat -c '%i' "$temp_dir/site.conf")" != "$old_inode" ]] ||
    fail "initial Nginx site was not atomically replaced"
  grep -Fq 'listen 80;' "$temp_dir/site.conf" || fail "initial HTTP IPv4 listener missing"
  grep -Fq 'listen [::]:80;' "$temp_dir/site.conf" || fail "initial HTTP IPv6 listener missing"
  grep -Fq 'server_name vpn.example.com;' "$temp_dir/site.conf" || fail "initial server name missing"
  grep -Fq "root $ACME_WEBROOT;" "$temp_dir/site.conf" || fail "ACME webroot missing"
  grep -Fq 'location / {' "$temp_dir/site.conf" || fail "initial ordinary location missing"
  grep -Fq 'return 200 "ok\n";' "$temp_dir/site.conf" || fail "initial ordinary response missing"
  grep -Fq 'ssl_certificate ' "$temp_dir/site.conf" && fail "initial site unexpectedly contains TLS"
  NGINX_SITE="$temp_dir/site.conf"
  current_nginx_config_is_project_owned "$NGINX_SITE" ||
    fail "installer-generated initial Nginx site was not recognized"

  render_nginx_site "$temp_dir/site.conf" final
  assert_eq "644" "$(stat -c '%a' "$temp_dir/site.conf")" "Nginx site permissions"
  grep -Fq 'listen 8443 ssl;' "$temp_dir/site.conf" || fail "Nginx TLS IPv4 listener missing"
  grep -Fq 'listen [::]:8443 ssl;' "$temp_dir/site.conf" || fail "Nginx TLS IPv6 listener missing"
  grep -Fq 'ssl_certificate /etc/letsencrypt/live/vpn.example.com/fullchain.pem;' "$temp_dir/site.conf" || fail "certificate path missing"
  grep -Fq 'ssl_certificate_key /etc/letsencrypt/live/vpn.example.com/privkey.pem;' "$temp_dir/site.conf" || fail "certificate key path missing"
  grep -Fq 'ssl_protocols TLSv1.2 TLSv1.3;' "$temp_dir/site.conf" || fail "TLS versions missing"
  grep -Fq 'location = /6f4f5304d2e84dc8 {' "$temp_dir/site.conf" || fail "exact WebSocket location missing"
  grep -Fq 'proxy_pass http://127.0.0.1:31001;' "$temp_dir/site.conf" || fail "Xray upstream missing"
  grep -Fq 'proxy_http_version 1.1;' "$temp_dir/site.conf" || fail "WebSocket HTTP version missing"
  grep -Fq 'proxy_set_header Upgrade $http_upgrade;' "$temp_dir/site.conf" || fail "literal upgrade variable missing"
  grep -Fq 'proxy_set_header Connection "upgrade";' "$temp_dir/site.conf" || fail "upgrade connection header missing"
  grep -Fq 'proxy_set_header Host $host;' "$temp_dir/site.conf" || fail "literal host variable missing"
  grep -Fq 'proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' "$temp_dir/site.conf" || fail "literal XFF variable missing"
  grep -Fq 'proxy_read_timeout 3600s;' "$temp_dir/site.conf" || fail "WebSocket read timeout missing"
  grep -Fq 'proxy_send_timeout 3600s;' "$temp_dir/site.conf" || fail "WebSocket send timeout missing"
  grep -Fq 'proxy_buffering off;' "$temp_dir/site.conf" || fail "WebSocket buffering not disabled"
  grep -Fq 'return 200 "ok\n";' "$temp_dir/site.conf" || fail "final ordinary response missing"
  grep -Fq "$SS_KEY" "$temp_dir/site.conf" && fail "Nginx config contains proxy credentials"
  grep -Fq "$CLOUDFLARE_UUID" "$temp_dir/site.conf" && fail "Nginx config contains proxy credentials"
  current_nginx_config_is_project_owned "$NGINX_SITE" ||
    fail "installer-generated final Nginx site was not recognized"
  cat >>"$NGINX_SITE" <<'EOF'

server {
    listen 9443 ssl;
    server_name unrelated.example.com;
}
EOF
  current_nginx_config_is_project_owned "$NGINX_SITE" &&
    fail "mixed current Nginx site was classified as project-owned"
  assert_fails "Refusing to overwrite Nginx site" validate_managed_destination_ownership
  render_nginx_site "$NGINX_SITE" final
  assert_fails "Invalid Nginx render mode" render_nginx_site "$temp_dir/site.conf" unsupported
  CLOUDFLARE_PORT="2443"
  assert_fails "Unsupported Cloudflare port" render_nginx_site "$temp_dir/site.conf" final
  CLOUDFLARE_PORT="8443"
  WS_PATH='invalid path'
  assert_fails "WebSocket path" render_nginx_site "$temp_dir/site.conf" final
  WS_PATH="/6f4f5304d2e84dc8"

  certbot_log="$temp_dir/certbot.log"
  certbot() { printf '<%s>\n' "$*" >"$certbot_log"; }
  request_certificate
  assert_eq "vpn.example.com" "$DOMAIN" "certificate domain is normalized to lowercase"
  assert_eq '<certonly --webroot -w /tmp/placeholder --non-interactive --agree-tos --email admin@example.com --keep-until-expiring -d vpn.example.com>' \
    "$(sed "s#${temp_dir}/acme-webroot#/tmp/placeholder#" "$certbot_log")" "Certbot webroot arguments"

  hook_path="$temp_dir/renewal-hooks/deploy/v2ray-onekey-nginx.sh"
  create_renewal_hook "$hook_path"
  assert_eq "755" "$(stat -c '%a' "$hook_path")" "renewal hook permissions"
  assert_eq $'#!/usr/bin/env bash\nset -e\nnginx -t\nsystemctl reload nginx' "$(cat "$hook_path")" "renewal hook content"

  local service_log="$temp_dir/nginx-service.log"
  nginx() { printf 'nginx %s\n' "$*" >>"$service_log"; }
  systemctl() {
    if [[ "$*" == 'is-active --quiet nginx' ]]; then return 0; fi
    printf 'systemctl %s\n' "$*" >>"$service_log"
  }
  activate_nginx_config
  grep -Fq 'systemctl enable nginx' "$service_log" || fail "active Nginx was not enabled"
  grep -Fq 'systemctl reload nginx' "$service_log" || fail "active Nginx was not reloaded"
  grep -Fq 'systemctl start nginx' "$service_log" && fail "active Nginx was started instead of reloaded"

  CLOUDFLARE_IPV4_FILE="$temp_dir/ips-v4"
  CLOUDFLARE_IPV6_FILE="$temp_dir/ips-v6"
  printf '%s\n' '104.16.0.0/13' >"$CLOUDFLARE_IPV4_FILE"
  printf '%s\n' '2606:4700::/32' >"$CLOUDFLARE_IPV6_FILE"
  curl() {
    [[ "$*" == *'--connect-timeout 10'* && "$*" == *'--max-time 30'* ]] ||
      fail "edge check did not use finite curl timeouts"
    printf '%s\n' 'HTTP/2 200' 'cf-ray: test-edge'
  }
  check_cloudflare_edge || fail "CF-Ray edge response was rejected"

  CLOUDFLARE_PORT="2443"
  if output="$(probe_cloudflare_edge 2>&1)"; then
    fail "unsupported Cloudflare edge port unexpectedly passed"
  fi
  CLOUDFLARE_PORT="8443"

  curl() { printf '%s\n' 'HTTP/2 200' '' '104.16.1.1'; }
  check_cloudflare_edge || fail "Cloudflare edge address was rejected"

  curl() { printf '%s\n' 'HTTP/2 200' '' '203.0.113.1'; }
  if output="$(probe_cloudflare_edge 2>&1)"; then
    fail "non-Cloudflare edge response unexpectedly passed"
  fi
  strict_output="$(
    (
      set -eE
      trap 'printf "ERR trap fired\\n" >&2' ERR
      check_cloudflare_edge
      printf 'strict mode continued\\n'
    ) 2>&1
  )"
  [[ "$strict_output" == *"Cloudflare edge check could not be confirmed"* ]] ||
    fail "failed edge check did not warn: $strict_output"
  [[ "$strict_output" == *"strict mode continued"* ]] ||
    fail "failed edge check interrupted strict mode: $strict_output"
  [[ "$strict_output" != *"ERR trap fired"* ]] ||
    fail "failed edge check triggered ERR: $strict_output"
)

test_nginx_and_acme

test_transaction_backup_and_rollback() (
  local temp_dir original_mode legacy disabled service_log
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  XRAY_CONFIG="$temp_dir/xray/config.json"
  MODE="cloudflare"
  DOMAIN="vpn.example.com"
  CLOUDFLARE_PORT="8443"
  INTERNAL_WS_PORT="31001"
  WS_PATH="/transaction-path"
  STATE_FILE="$temp_dir/state/state.env"
  NGINX_SITE="$temp_dir/nginx/v2ray-onekey.conf"
  RENEWAL_HOOK="$temp_dir/hooks/v2ray-onekey-nginx.sh"
  LEGACY_V2RAY_CONFIG="$temp_dir/v2ray/config.json"
  BACKUP_DIR="$temp_dir/backup"
  install -d -m 700 "$(dirname "$XRAY_CONFIG")" "$BACKUP_DIR"
  install -d "$(dirname "$NGINX_SITE")"
  printf 'server { listen 8443 ssl; }\n' >"$NGINX_SITE"
  assert_fails "Refusing to overwrite Nginx site" validate_managed_destination_ownership
  render_nginx_site "$NGINX_SITE" final
  validate_managed_destination_ownership
  install -d "$(dirname "$RENEWAL_HOOK")"
  cat >"$RENEWAL_HOOK" <<'EOF'
#!/usr/bin/env bash
set -e
nginx -t
systemctl reload nginx
EOF
  validate_managed_destination_ownership
  printf 'echo unexpected\n' >>"$RENEWAL_HOOK"
  assert_fails "renewal hook" validate_managed_destination_ownership
  rm -f "$RENEWAL_HOOK"
  printf 'target\n' >"$temp_dir/hook-target"
  ln -s "$temp_dir/hook-target" "$RENEWAL_HOOK"
  assert_fails "renewal hook" validate_managed_destination_ownership
  rm -f "$RENEWAL_HOOK"
  mkdir "$RENEWAL_HOOK"
  assert_fails "renewal hook" validate_managed_destination_ownership
  rmdir "$RENEWAL_HOOK"
  rm -f "$NGINX_SITE"
  printf 'old-config\n' >"$XRAY_CONFIG"
  init_backup_metadata
  backup_file "$XRAY_CONFIG"
  backup_file "$STATE_FILE"
  backup_file "$XRAY_CONFIG"

  [[ -f "$BACKUP_DIR$XRAY_CONFIG" ]] || fail "backup path missing"
  assert_eq "old-config" "$(cat "$BACKUP_DIR$XRAY_CONFIG")" "backup content"
  grep -Fqx $'present\t'"$XRAY_CONFIG" "$BACKUP_DIR/manifest" || fail "present path not recorded"
  grep -Fqx $'absent\t'"$STATE_FILE" "$BACKUP_DIR/manifest" || fail "absent path not recorded"
  assert_eq "2" "$(wc -l <"$BACKUP_DIR/manifest" | tr -d ' ')" "duplicate manifest entries"
  assert_eq "700" "$(stat -c '%a' "$BACKUP_DIR")" "backup directory mode"
  assert_eq "600" "$(stat -c '%a' "$BACKUP_DIR/manifest")" "manifest mode"
  ln -s "$XRAY_CONFIG" "$temp_dir/symlink"
  original_mode="$XRAY_CONFIG"
  XRAY_CONFIG="$temp_dir/symlink"
  assert_fails "Refusing to back up symlink" backup_file "$XRAY_CONFIG"
  XRAY_CONFIG="$original_mode"
  assert_fails "unmanaged path" backup_file "$temp_dir/arbitrary"

  printf 'new-config\n' >"$XRAY_CONFIG"
  install -d "$(dirname "$STATE_FILE")"
  printf 'new-state\n' >"$STATE_FILE"
  service_log="$temp_dir/services.log"
  cat >"$BACKUP_DIR/services" <<'EOF'
v2ray	active	enabled
xray	active	disabled
nginx	active	enabled
EOF
  systemctl() { printf '%s\n' "$*" >>"$service_log"; }
  rollback_current_run
  assert_eq "old-config" "$(cat "$XRAY_CONFIG")" "rollback restored config"
  [[ ! -e "$STATE_FILE" ]] || fail "rollback did not remove newly created state"
  grep -Fq 'restart v2ray' "$service_log" || fail "rollback did not restart active V2Ray with restored config"
  grep -Fq 'restart xray' "$service_log" || fail "rollback did not restart active Xray with restored config"
  grep -Fq 'restart nginx' "$service_log" || fail "rollback did not restart active Nginx with restored config"
  local service
  for service in v2ray xray nginx; do
    grep -Fqx "stop $service" "$service_log" || fail "rollback did not stop $service before restoration"
    grep -Fqx "restart $service" "$service_log" || fail "rollback did not restart active $service"
  done
  [[ "$(grep -n '^stop ' "$service_log" | tail -n 1 | cut -d: -f1)" -lt \
    "$(grep -n '^restart ' "$service_log" | head -n 1 | cut -d: -f1)" ]] ||
    fail "rollback restarted a proxy before every managed service was stopped"
  grep -Fq 'enable v2ray' "$service_log" || fail "rollback did not restore enabled V2Ray"
  grep -Fq 'disable xray' "$service_log" || fail "rollback did not restore disabled Xray"

  legacy="$temp_dir/v2ray-owned.conf"
  NGINX_SITE="$temp_dir/current-site.conf"
  legacy_nginx_config_path() { [[ "$1" == "$legacy" ]]; }
  cat >"$legacy" <<'EOF'
# legacy comment outside the server block
server {
  server_name vpn.example.com;
  proxy_set_header Upgrade $http_upgrade;
  proxy_pass http://127.0.0.1:31001;
  return 200 "ok\n";
}
EOF
  BACKUP_DIR="$temp_dir/legacy-backup"
  RUN_TIMESTAMP="20260718T000000Z"
  init_backup_metadata
  backup_file "$legacy"
  printf '%s\n' "$legacy" >"$BACKUP_DIR/legacy-files"
  disable_owned_legacy_nginx_files
  disabled="${legacy}.v2ray-onekey-disabled-${RUN_TIMESTAMP}"
  [[ -f "$disabled" && ! -e "$legacy" ]] || fail "legacy Nginx file was not disabled by rename"
  : >"$BACKUP_DIR/services"
  rollback_current_run
  [[ -f "$legacy" && ! -e "$disabled" ]] || fail "legacy Nginx rename was not reversed"
  [[ -f "$BACKUP_DIR$legacy" ]] || fail "legacy backup was not preserved"
)

test_transaction_backup_and_rollback
printf 'PASS: transactional backup and rollback tests\n'

test_mixed_legacy_nginx_file_is_never_disabled() (
  local temp_dir owned certbot mixed malformed owned_disabled certbot_disabled
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  owned="$temp_dir/v2ray-owned.conf"
  certbot="$temp_dir/v2ray-certbot.conf"
  mixed="$temp_dir/v2ray-mixed.conf"
  malformed="$temp_dir/v2ray-malformed.conf"
  NGINX_SITE="$temp_dir/v2ray-onekey.conf"
  BACKUP_DIR="$temp_dir/backup"
  RUN_TIMESTAMP="20260719T010000Z"
  legacy_nginx_config_path() {
    [[ "$1" == "$owned" || "$1" == "$certbot" || "$1" == "$mixed" || "$1" == "$malformed" ]]
  }
  legacy_nginx_config_paths() { printf '%s\n' "$owned" "$certbot" "$mixed" "$malformed"; }

  cat >"$owned" <<'EOF'
# comments outside the only server block are allowed
server {
  server_name vpn.example.com;
  proxy_set_header Upgrade $http_upgrade;
  proxy_pass http://127.0.0.1:31001;
  return 200 "ok\n";
}
EOF
  cat >"$certbot" <<'EOF'
server {
  listen 80;
  server_name vpn.example.com;
  proxy_set_header Upgrade $http_upgrade;
  proxy_pass http://127.0.0.1:31001;
  return 200 "ok\n";
  listen 443 ssl; # managed by Certbot
  ssl_certificate /etc/letsencrypt/live/vpn.example.com/fullchain.pem; # managed by Certbot
  ssl_certificate_key /etc/letsencrypt/live/vpn.example.com/privkey.pem; # managed by Certbot
}
server {
  if ($host = vpn.example.com) {
    return 301 https://$host$request_uri;
  } # managed by Certbot
  listen 80;
  server_name vpn.example.com;
  return 404; # managed by Certbot
}
EOF
  cat >"$mixed" <<'EOF'
server {
  server_name vpn.example.com;
  proxy_set_header Upgrade $http_upgrade;
  proxy_pass http://127.0.0.1:31001;
  return 200 "ok\n";
}
server {
  listen 9443 ssl;
  server_name unrelated.example.com;
}
EOF
  cat >"$malformed" <<'EOF'
server {
  server_name vpn.example.com;
  proxy_set_header Upgrade $http_upgrade;
  proxy_pass http://127.0.0.1:31001;
  return 200 "ok\n";
EOF

  python3() { return 127; }
  legacy_nginx_config_is_project_owned "$owned" ||
    fail "valid legacy Nginx file required python3 for ownership classification"
  legacy_nginx_config_is_project_owned "$certbot" ||
    fail "Certbot-modified legacy Nginx file was not recognized"
  legacy_nginx_config_is_project_owned "$mixed" &&
    fail "mixed legacy Nginx file was accepted without python3"
  legacy_nginx_config_is_project_owned "$malformed" &&
    fail "malformed legacy Nginx file was accepted without python3"

  init_backup_metadata
  collect_owned_legacy_nginx_files
  grep -Fqx "$owned" "$BACKUP_DIR/legacy-files" || fail "owned legacy Nginx file was not collected"
  grep -Fqx "$certbot" "$BACKUP_DIR/legacy-files" || fail "Certbot legacy Nginx file was not collected"
  grep -Fqx "$mixed" "$BACKUP_DIR/legacy-files" && fail "mixed legacy Nginx file was collected"
  grep -Fqx "$malformed" "$BACKUP_DIR/legacy-files" && fail "malformed legacy Nginx file was collected"
  [[ -f "$BACKUP_DIR$owned" ]] || fail "owned legacy Nginx file was not backed up"
  [[ -f "$BACKUP_DIR$certbot" ]] || fail "Certbot legacy Nginx file was not backed up"
  [[ ! -e "$BACKUP_DIR$mixed" ]] || fail "mixed legacy Nginx file was backed up"

  disable_owned_legacy_nginx_files
  owned_disabled="${owned}.v2ray-onekey-disabled-${RUN_TIMESTAMP}"
  certbot_disabled="${certbot}.v2ray-onekey-disabled-${RUN_TIMESTAMP}"
  [[ -f "$owned_disabled" && ! -e "$owned" ]] || fail "owned legacy Nginx file was not disabled"
  [[ -f "$certbot_disabled" && ! -e "$certbot" ]] || fail "Certbot legacy Nginx file was not disabled"
  [[ -f "$mixed" ]] || fail "mixed legacy Nginx file was renamed or disabled"
  if grep -Fq "$mixed" "$BACKUP_DIR/legacy-renames"; then
    fail "mixed legacy Nginx rename was recorded"
  fi
)

test_mixed_legacy_nginx_file_is_never_disabled
printf 'PASS: mixed legacy Nginx ownership tests\n'

test_direct_mode_removes_owned_cloudflare_files_transactionally() (
  local temp_dir service_log
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  MODE="direct"
  NGINX_SITE="$temp_dir/nginx/v2ray-onekey.conf"
  RENEWAL_HOOK="$temp_dir/hooks/v2ray-onekey-nginx.sh"
  XRAY_CONFIG="$temp_dir/xray/config.json"
  STATE_FILE="$temp_dir/state/state.env"
  LEGACY_V2RAY_CONFIG="$temp_dir/v2ray/config.json"
  BACKUP_DIR="$temp_dir/backup"
  RUN_TIMESTAMP="test"
  DOMAIN="vpn.example.com"
  CLOUDFLARE_PORT="8443"
  INTERNAL_WS_PORT="31001"
  WS_PATH="/transition-path"
  install -d "$(dirname "$NGINX_SITE")" "$(dirname "$RENEWAL_HOOK")"
  render_nginx_site "$NGINX_SITE" final
  cat >"$RENEWAL_HOOK" <<'EOF'
#!/usr/bin/env bash
set -e
nginx -t
systemctl reload nginx
EOF
  init_backup_metadata
  backup_file "$NGINX_SITE"
  backup_file "$RENEWAL_HOOK"
  : >"$BACKUP_DIR/services"
  service_log="$temp_dir/service.log"
  systemctl() {
    if [[ "$*" == 'is-active --quiet nginx' ]]; then return 0; fi
    printf 'systemctl %s\n' "$*" >>"$service_log"
  }
  nginx() { printf 'nginx %s\n' "$*" >>"$service_log"; }
  release_legacy_nginx_listeners
  [[ ! -e "$NGINX_SITE" && ! -e "$RENEWAL_HOOK" ]] || fail "owned Cloudflare files remained in direct mode"
  grep -Fq 'nginx -t' "$service_log" || fail "Nginx was not validated after direct-mode cleanup"
  grep -Fq 'systemctl reload nginx' "$service_log" || fail "Nginx was not reloaded after direct-mode cleanup"
  rollback_current_run
  [[ -f "$NGINX_SITE" && -f "$RENEWAL_HOOK" ]] || fail "rollback did not restore Cloudflare files"

  cat >>"$NGINX_SITE" <<'EOF'

server {
    listen 9443 ssl;
    server_name unrelated.example.com;
}
EOF
  local mixed_site_content
  mixed_site_content="$(cat "$NGINX_SITE")"
  printf 'echo unrelated\n' >>"$RENEWAL_HOOK"
  release_legacy_nginx_listeners >/dev/null
  [[ -f "$NGINX_SITE" ]] || fail "direct transition removed a mixed current Nginx site"
  assert_eq "$mixed_site_content" "$(cat "$NGINX_SITE")" "mixed current Nginx site preservation"
  grep -Fqx 'echo unrelated' "$RENEWAL_HOOK" || fail "extra-command renewal hook was modified"
)

test_direct_mode_removes_owned_cloudflare_files_transactionally
printf 'PASS: direct mode Cloudflare-file transition tests\n'

test_deployment_lock_and_backup_collision() (
  local temp_dir base first_lock_owner
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  DEPLOYMENT_LOCK_DIR="$temp_dir/deployment.lock"
  LOCK_HELD="0"
  acquire_deployment_lock
  [[ -d "$DEPLOYMENT_LOCK_DIR" ]] || fail "deployment lock directory was not created"
  assert_eq "700" "$(stat -c '%a' "$DEPLOYMENT_LOCK_DIR")" "deployment lock mode"
  first_lock_owner="$(cat "$DEPLOYMENT_LOCK_DIR/owner")"
  [[ "$first_lock_owner" =~ ^[0-9]+$ ]] || fail "deployment lock owner is not a PID"
  competing_lock() { LOCK_HELD="0"; acquire_deployment_lock; }
  assert_fails "already running" competing_lock
  release_deployment_lock
  [[ ! -e "$DEPLOYMENT_LOCK_DIR" ]] || fail "deployment lock was not released"

  mkdir -m 700 "$DEPLOYMENT_LOCK_DIR"
  printf '2147483647\n' >"$DEPLOYMENT_LOCK_DIR/owner"
  chmod 600 "$DEPLOYMENT_LOCK_DIR/owner"
  LOCK_HELD="0"
  assert_fails "manually remove this exact lock directory: $DEPLOYMENT_LOCK_DIR" acquire_deployment_lock
  [[ -d "$DEPLOYMENT_LOCK_DIR" ]] || fail "stale deployment lock was removed"
  assert_eq "2147483647" "$(cat "$DEPLOYMENT_LOCK_DIR/owner")" "stale lock owner preservation"
  printf 'invalid-pid\n' >"$DEPLOYMENT_LOCK_DIR/owner"
  assert_fails "manually remove this exact lock directory: $DEPLOYMENT_LOCK_DIR" acquire_deployment_lock
  assert_eq "invalid-pid" "$(cat "$DEPLOYMENT_LOCK_DIR/owner")" "invalid lock owner preservation"

  BACKUP_ROOT="$temp_dir/backups"
  RUN_TIMESTAMP="20260719T000000Z"
  install -d -m 700 "$BACKUP_ROOT"
  base="$BACKUP_ROOT/$RUN_TIMESTAMP"
  mkdir -m 700 "$base"
  create_unique_backup_directory
  [[ "$BACKUP_DIR" != "$base" && -d "$BACKUP_DIR" ]] || fail "backup collision was not resolved atomically"
  assert_eq "700" "$(stat -c '%a' "$BACKUP_DIR")" "unique backup directory mode"
)

test_deployment_lock_and_backup_collision
printf 'PASS: deployment lock and backup collision tests\n'

test_prepare_configuration_reuse_and_rotate() (
  local temp_dir
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  STATE_FILE="$temp_dir/state/state.env"
  reset_options
  MODE="full"
  DOMAIN="vpn.example.com"
  EMAIL="admin@example.com"
  CLOUDFLARE_PORT="443"
  INTERNAL_WS_PORT="31001"
  CLOUDFLARE_UUID="22222222-2222-4222-8222-222222222222"
  WS_PATH="/saved-path"
  HY2_PORT_RANGE="20000-20100"
  HY2_AUTH="saved-hy2-auth"
  HY2_OBFS_PASSWORD="saved-hy2-obfs"
  HY2_SNI="saved.example.com"
  HY2_CERT_PIN="saved-pin"
  SS_PORT="8388"
  SS_METHOD="2022-blake3-aes-128-gcm"
  SS_KEY="$SS_TEST_KEY"
  SERVER_ADDRESS="edge.example.com"
  ALLOW_MAIL="1"
  save_state

  reset_options
  parse_args
  prepare_configuration
  assert_eq "full" "$MODE" "existing state mode reused without prompt"
  assert_eq "/saved-path" "$WS_PATH" "existing credentials reused"

  reset_options
  parse_args --rotate
  prepare_configuration
  assert_eq "full" "$MODE" "rotate retained saved mode"
  assert_eq "vpn.example.com" "$DOMAIN" "rotate retained saved domain"
  assert_eq "admin@example.com" "$EMAIL" "rotate retained saved email"
  assert_eq "443" "$CLOUDFLARE_PORT" "rotate retained Cloudflare port"
  assert_eq "20000-20100" "$HY2_PORT_RANGE" "rotate retained Hysteria2 range"
  assert_eq "8388" "$SS_PORT" "rotate retained Shadowsocks port"
  assert_eq "edge.example.com" "$SERVER_ADDRESS" "rotate retained server address"
  assert_eq "" "$CLOUDFLARE_UUID" "rotate cleared Cloudflare UUID"
  assert_eq "" "$INTERNAL_WS_PORT" "rotate cleared internal WebSocket port"
  assert_eq "" "$WS_PATH" "rotate cleared WebSocket path"
  assert_eq "" "$HY2_AUTH$HY2_OBFS_PASSWORD$HY2_SNI$HY2_CERT_PIN" "rotate cleared Hysteria2 credentials"
  assert_eq "" "$SS_KEY" "rotate cleared Shadowsocks credentials"
  assert_eq "2022-blake3-aes-128-gcm" "$SS_METHOD" "rotate retained Shadowsocks method"
  assert_eq "1" "$ALLOW_MAIL" "rotate retained mail setting"

  reset_options
  parse_args --mode cloudflare --rotate
  prepare_configuration
  assert_eq "cloudflare" "$MODE" "full state rotated to Cloudflare mode"
  assert_eq "vpn.example.com" "$DOMAIN" "full-to-Cloudflare domain"
  assert_eq "admin@example.com" "$EMAIL" "full-to-Cloudflare email"
  assert_eq "" "$HY2_PORT_RANGE$HY2_AUTH$HY2_OBFS_PASSWORD$HY2_SNI$HY2_CERT_PIN" "full-to-Cloudflare Hysteria2 cleanup"
  assert_eq "" "$SS_PORT$SS_METHOD$SS_KEY" "full-to-Cloudflare Shadowsocks cleanup"
  assert_eq "" "$SERVER_ADDRESS" "full-to-Cloudflare server address cleanup"

  reset_options
  MODE="direct"
  HY2_PORT_RANGE="22000-22100"
  HY2_AUTH="direct-auth"
  HY2_OBFS_PASSWORD="direct-obfs"
  HY2_SNI="direct.example.com"
  HY2_CERT_PIN="direct-pin"
  SS_PORT="18388"
  SS_METHOD="2022-blake3-aes-128-gcm"
  SS_KEY="$SS_TEST_KEY"
  SERVER_ADDRESS="198.51.100.10"
  save_state

  reset_options
  parse_args --mode cloudflare --domain vpn.example.com --email admin@example.com --rotate
  prepare_configuration
  assert_eq "cloudflare" "$MODE" "direct state rotated to Cloudflare mode"
  assert_eq "vpn.example.com" "$DOMAIN" "direct-to-Cloudflare domain"
  assert_eq "admin@example.com" "$EMAIL" "direct-to-Cloudflare email"
  assert_eq "" "$HY2_PORT_RANGE$HY2_AUTH$HY2_OBFS_PASSWORD$HY2_SNI$HY2_CERT_PIN" "direct-to-Cloudflare Hysteria2 cleanup"
  assert_eq "" "$SS_PORT$SS_METHOD$SS_KEY" "direct-to-Cloudflare Shadowsocks cleanup"
  assert_eq "" "$SERVER_ADDRESS" "direct-to-Cloudflare server address cleanup"
)

test_prepare_configuration_reuse_and_rotate
printf 'PASS: state reuse and rotation tests\n'

test_interactive_full_mode_collects_domain_and_email() (
  local temp_dir
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  STATE_FILE="$temp_dir/missing-state.env"
  stdin_is_tty() { return 0; }

  reset_options
  parse_args
  prepare_configuration <<< $'3\nVPN.Example.COM\nadmin@example.com\n'

  assert_eq "full" "$MODE" "interactive mode selection"
  assert_eq "vpn.example.com" "$DOMAIN" "interactive Cloudflare domain"
  assert_eq "admin@example.com" "$EMAIL" "interactive certificate email"
  assert_eq "443" "$CLOUDFLARE_PORT" "interactive Cloudflare default port"
  assert_eq "20000-20100" "$HY2_PORT_RANGE" "interactive Hysteria2 default range"
  assert_eq "8388" "$SS_PORT" "interactive Shadowsocks default port"
)

test_interactive_full_mode_collects_domain_and_email
printf 'PASS: interactive Cloudflare identity tests\n'

test_port_resolution() (
  reset_options
  MODE="full"
  DOMAIN="vpn.example.com"
  CLOUDFLARE_PORT="8443"
  stdin_is_tty() { return 0; }
  port_listener_conflicts() {
    local role="$1" port="$2"
    PORT_CONFLICT_DETAILS="mock conflict"
    [[ "$role:$port" == "cloudflare:8443" ]]
  }
  resolve_public_port_conflicts <<'EOF'
2443
2053
EOF
  assert_eq "2053" "$CLOUDFLARE_PORT" "Cloudflare allowlisted replacement"

  reset_options
  MODE="cloudflare"
  DOMAIN="vpn.example.com"
  CLOUDFLARE_PORT="443"
  stdin_is_tty() { return 1; }
  port_listener_conflicts() { PORT_CONFLICT_DETAILS="occupied by other"; return 0; }
  assert_fails "--cloudflare-port PORT" resolve_public_port_conflicts

  reset_options
  MODE="direct"
  port_listener_conflicts() { fail "direct mode checked a public TCP listener"; }
  resolve_public_port_conflicts
)

test_port_resolution
printf 'PASS: port resolution tests\n'

test_packages_permissions_and_firewall() (
  local temp_dir package_log firewall_log current_user current_group installer_log
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  package_log="$temp_dir/packages.log"
  install_packages() {
    printf '%s\n' "$*" >>"$package_log"
    [[ "$*" != "python3-certbot-nginx" ]]
  }
  reset_options
  MODE="direct"
  PKG_MANAGER="apt"
  install_required_packages
  grep -Fq 'curl ca-certificates openssl python3 coreutils gawk iproute2' "$package_log" ||
    fail "APT base package set is incomplete"
  grep -Eq 'nginx|certbot' "$package_log" && fail "direct-only installed Cloudflare packages"
  : >"$package_log"
  PKG_MANAGER="dnf"
  install_required_packages
  grep -Fq 'curl ca-certificates openssl python3 coreutils gawk iproute' "$package_log" ||
    fail "RPM base package set does not include iproute"
  grep -Fq 'iproute2' "$package_log" && fail "RPM package set incorrectly uses iproute2"
  : >"$package_log"
  MODE="cloudflare"
  PKG_MANAGER="apt"
  install_required_packages
  grep -Fq 'nginx certbot' "$package_log" || fail "Cloudflare packages missing"
  grep -Fq 'python3-certbot-nginx' "$package_log" || fail "optional Certbot Nginx package not attempted"

  XRAY_CONFIG="$temp_dir/xray/config.json"
  printf '{}\n' >"$temp_dir/staged.json"
  current_user="$(id -un)"
  current_group="$(id -gn)"
  xray_service_identity() { printf '%s:%s\n' "$current_user" "$current_group"; }
  install_validated_xray_config "$temp_dir/staged.json"
  assert_eq "400" "$(stat -c '%a' "$XRAY_CONFIG")" "Xray private config mode"
  assert_eq "$(id -u)" "$(stat -c '%u' "$XRAY_CONFIG")" "Xray config owner"

  firewall_log="$temp_dir/firewall.log"
  ufw_state="inactive"
  firewalld_state="inactive"
  ufw() {
    if [[ "$1" == "status" ]]; then printf 'Status: %s\n' "$ufw_state"; else printf 'ufw %s\n' "$*" >>"$firewall_log"; fi
  }
  firewall-cmd() { printf 'firewall %s\n' "$*" >>"$firewall_log"; }
  systemctl() { [[ "$1 $2 $3" == 'is-active --quiet firewalld' && "$firewalld_state" == "active" ]]; }
  open_firewall_port 443 tcp
  [[ ! -s "$firewall_log" ]] || fail "inactive firewall was modified"
  ufw_state="active"
  firewalld_state="active"
  open_firewall_port 8443 tcp
  grep -Fq 'ufw allow 8443/tcp' "$firewall_log" || fail "active UFW was not updated"
  grep -Fq 'firewall --add-port=8443/tcp' "$firewall_log" || fail "firewalld runtime rule missing"
  grep -Fq 'firewall --permanent --add-port=8443/tcp' "$firewall_log" || fail "active firewalld was not updated"
  grep -Fq -- '--reload' "$firewall_log" && fail "firewalld global reload was used"

  : >"$firewall_log"
  ufw_state="inactive"
  firewall-cmd() { printf 'firewall %s\n' "$*" >>"$firewall_log"; return 1; }
  local firewall_warning=""
  firewall_warning="$(open_firewall_port 2053 tcp 2>&1)"
  [[ "$firewall_warning" == *'firewalld'* && "$firewall_warning" == *'2053/tcp'* ]] ||
    fail "firewalld failure was silent: $firewall_warning"
  grep -Eq '(apt-get|dnf|yum).*(remove|erase)' "$SCRIPT" &&
    fail "installer contains package-removal behavior"

  installer_log="$temp_dir/installer.log"
  curl() {
    [[ "$*" == *'-LfsS'* && "$*" == *'--connect-timeout 10'* && "$*" == *'--max-time 120'* ]] ||
      fail "Xray installer download lacks finite timeout flags"
    printf 'official-installer-body'
  }
  bash() { printf '%s\n' "$*" >"$installer_log"; }
  install_xray_core >/dev/null
  assert_eq "-c official-installer-body @ install" "$(cat "$installer_log")" "official Xray installer invocation"
)

test_packages_permissions_and_firewall
printf 'PASS: package, permission, and firewall tests\n'

test_listener_readiness_waits_for_delayed_bind() (
  local temp_dir attempt_log sleep_log
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  attempt_log="$temp_dir/attempts.log"
  sleep_log="$temp_dir/sleeps.log"

  listener_output() {
    printf '%s\n' "$1" >>"$attempt_log"
    if [[ "$(wc -l <"$attempt_log" | tr -d ' ')" -ge 3 ]]; then
      printf 'LISTEN 0 4096 0.0.0.0:%s 0.0.0.0:* users:(("xray",pid=42,fd=3))\n' "$1"
    fi
  }
  sleep() { printf '%s\n' "$1" >>"$sleep_log"; }

  LISTENER_WAIT_ATTEMPTS=4
  LISTENER_WAIT_INTERVAL=1
  wait_for_listener_owner 443 xray

  assert_eq "3" "$(wc -l <"$attempt_log" | tr -d ' ')" "delayed listener attempt count"
  assert_eq "2" "$(wc -l <"$sleep_log" | tr -d ' ')" "delayed listener sleep count"
)

test_listener_readiness_waits_for_delayed_bind
printf 'PASS: delayed listener readiness tests\n'

test_listener_timeout_prints_service_diagnostics() (
  local output
  listener_output() { :; }
  sleep() { :; }
  systemctl() {
    printf 'mock xray status: failed\n'
    return 3
  }
  journalctl() { printf 'mock xray journal: bind failed\n'; }

  LISTENER_WAIT_ATTEMPTS=2
  LISTENER_WAIT_INTERVAL=1
  if output="$(wait_for_listener_owner 443 xray 2>&1)"; then
    fail "missing listener unexpectedly passed readiness verification"
  fi
  [[ "$output" == *'mock xray status: failed'* ]] || fail "listener failure omitted systemd status: $output"
  [[ "$output" == *'mock xray journal: bind failed'* ]] || fail "listener failure omitted journal output: $output"
  [[ "$output" == *'Expected xray listener on TCP 443'* ]] || fail "listener failure omitted final error: $output"
)

test_listener_timeout_prints_service_diagnostics
printf 'PASS: listener failure diagnostic tests\n'

test_deployment_order_and_failure_trap() (
  local temp_dir order_log status
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  order_log="$temp_dir/order.log"
  event() { printf '%s\n' "$1" >>"$order_log"; }
  reset_options
  MODE="direct"
  direct_bundle_ready() { return 0; }
  HY2_PORT_RANGE="20000-20100"
  SS_PORT="8388"
  RUNTIME_DIR="$temp_dir/run"
  ACME_WEBROOT="$temp_dir/acme"
  begin_transaction() { RUN_TIMESTAMP="test"; BACKUP_DIR="$temp_dir/backup"; install -d "$BACKUP_DIR"; event backup; }
  validate_managed_destination_ownership() { event ownership; }
  install_required_packages() { event packages; }
  install_xray_core() { event xray-install; }
  generate_runtime_values() { event generate; }
  validate_loaded_runtime_values() { event runtime-validate; }
  download_cloudflare_ranges() { event cf-download; }
  check_public_port_listeners() { event public-ports; }
  check_internal_ws_port_listener() { event internal-port; }
  render_xray_config() { printf '{}\n' >"$1"; event render; }
  xray() { event xray-test; }
  stop_legacy_service_for_cutover() { event v2ray-stop; }
  release_legacy_nginx_listeners() { event nginx-release; }
  install_validated_xray_config() { event config-install; }
  systemctl() { event "systemctl:$*"; }
  verify_started_services() { event listeners-ok; }
  disable_legacy_v2ray_after_success() { event v2ray-disable; }
  save_state() { event state-save; }
  configure_firewall() { event firewall; }
  print_deployment_summary() { event output; }
  set +e
  ( set -Eeuo pipefail; deploy_services )
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || fail "mock deployment failed unexpectedly: $(tr '\n' ',' <"$order_log")"
  grep -Fq 'cf-download' "$order_log" && fail "direct-only downloaded Cloudflare ranges"
  [[ "$(grep -n '^xray-test$' "$order_log" | cut -d: -f1)" -lt "$(grep -n '^config-install$' "$order_log" | cut -d: -f1)" ]] ||
    fail "Xray test did not precede config installation"
  [[ "$(grep -n '^listeners-ok$' "$order_log" | cut -d: -f1)" -lt "$(grep -n '^v2ray-disable$' "$order_log" | cut -d: -f1)" ]] ||
    fail "V2Ray was disabled before listener validation"

  : >"$order_log"
  verify_started_services() { event listeners-failed; return 1; }
  rollback_current_run() { event rollback; }
  set +e
  (
    set -Eeuo pipefail
    activate_transaction_traps
    deploy_services
  ) >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "failed deployment unexpectedly succeeded"
  grep -Fq 'rollback' "$order_log" || fail "ERR trap did not roll back"
  grep -Fq 'v2ray-disable' "$order_log" && fail "failed deployment disabled V2Ray"
  :
)

test_deployment_order_and_failure_trap
printf 'PASS: deployment ordering tests\n'

test_transaction_exit_trap() (
  local temp_dir managed rollback_log status
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  managed="$temp_dir/managed.conf"
  rollback_log="$temp_dir/rollback.log"
  printf 'old\n' >"$managed"
  rollback_current_run() {
    printf 'old\n' >"$managed"
    printf 'rollback\n' >>"$rollback_log"
  }

  set +e
  (
    set -Eeuo pipefail
    activate_transaction_traps
    DEPLOYMENT_LOCK_DIR="$temp_dir/explicit-exit.lock"
    LOCK_HELD="0"
    acquire_deployment_lock
    printf 'changed\n' >"$managed"
    die "forced explicit exit"
  ) >/dev/null 2>&1
  status=$?
  set -e
  assert_eq "1" "$status" "explicit die exit status"
  assert_eq "old" "$(cat "$managed")" "explicit die rollback"
  assert_eq "1" "$(wc -l <"$rollback_log" | tr -d ' ')" "explicit die rollback count"
  [[ ! -e "$temp_dir/explicit-exit.lock" ]] || fail "explicit die left deployment lock behind"

  : >"$rollback_log"
  set +e
  (
    set -Eeuo pipefail
    activate_transaction_traps
    DEPLOYMENT_LOCK_DIR="$temp_dir/failure.lock"
    LOCK_HELD="0"
    acquire_deployment_lock
    false
  ) >/dev/null 2>&1
  status=$?
  set -e
  assert_eq "1" "$status" "ordinary failure exit status"
  assert_eq "1" "$(wc -l <"$rollback_log" | tr -d ' ')" "ordinary failure rollback count"
  [[ ! -e "$temp_dir/failure.lock" ]] || fail "ordinary failure left deployment lock behind"

  : >"$rollback_log"
  (
    set -Eeuo pipefail
    activate_transaction_traps
    DEPLOYMENT_LOCK_DIR="$temp_dir/success.lock"
    LOCK_HELD="0"
    acquire_deployment_lock
    true
    complete_transaction
  )
  [[ ! -s "$rollback_log" ]] || fail "successful transaction rolled back"
  [[ ! -e "$temp_dir/success.lock" ]] || fail "successful transaction left deployment lock behind"

  : >"$rollback_log"
  set +e
  (
    set -Eeuo pipefail
    activate_transaction_traps
    DEPLOYMENT_LOCK_DIR="$temp_dir/term.lock"
    LOCK_HELD="0"
    acquire_deployment_lock
    kill -TERM "$BASHPID"
  ) >/dev/null 2>&1
  status=$?
  set -e
  assert_eq "143" "$status" "TERM transaction exit status"
  assert_eq "1" "$(wc -l <"$rollback_log" | tr -d ' ')" "TERM rollback count"
  [[ ! -e "$temp_dir/term.lock" ]] || fail "TERM left deployment lock behind"
)

test_transaction_exit_trap
printf 'PASS: transaction EXIT trap tests\n'

test_mode_specific_output() (
  reset_options
  MODE="full"
  DOMAIN="vpn.example.com"
  CLOUDFLARE_PORT="2053"
  CLOUDFLARE_UUID="22222222-2222-4222-8222-222222222222"
  WS_PATH="/saved-path"
  STATE_FILE="/etc/v2ray-onekey/state.env"
  BACKUP_DIR="/var/backups/v2ray-onekey/test"
  local output
  output="$(print_deployment_summary)"
  [[ "$output" == *'Cloudflare entry: VLESS + WebSocket + TLS'* ]] || fail "full output lacks Cloudflare label"
  [[ "$output" == *'@vpn.example.com:2053'* ]] || fail "full output omits the Cloudflare link"
  [[ "$output" != *'REALITY'* ]] || fail "full output exposes retired protocol behavior"
  MODE="direct"
  output="$(print_deployment_summary)"
  [[ "$output" != *'vless://'* ]] || fail "direct output contains an unimplemented public link"
  [[ "$output" == *'No public listeners are configured for direct mode'* ]] || fail "direct output does not explain the interim listener state"
  MODE="cloudflare"
  output="$(print_deployment_summary)"
  [[ "$output" == *'Cloudflare entry:'* && "$output" == *'@vpn.example.com:2053'* ]] || fail "Cloudflare output labels are wrong"
)

test_mode_specific_output
printf 'PASS: mode-specific output tests\n'

printf 'PASS: mode and validation tests\n'
