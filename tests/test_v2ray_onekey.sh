#!/usr/bin/env bash
# Test doubles are invoked indirectly by sourced installer functions.
# shellcheck disable=SC2034,SC2120,SC2329
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/outputs/v2ray-onekey.sh"

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
# shellcheck source=../outputs/v2ray-onekey.sh
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

assert_invalid_uri_host() {
  local address="$1"
  local formatted=""
  local link=""
  if formatted="$(format_uri_host "$address" 2>/dev/null)"; then
    fail "invalid URI host was accepted"
  fi
  [[ -z "$formatted" ]] || fail "invalid URI host produced output: $formatted"
  if link="$(make_reality_link "$address" 2>&1)"; then
    fail "REALITY link accepted an invalid address"
  fi
  [[ "$link" != *"vless://"* ]] || fail "invalid address produced a VLESS URI: $link"
}

reset_options
MODE="reality"
resolve_default_ports
assert_eq "443" "$REALITY_PORT" "reality port"
assert_eq "" "$CLOUDFLARE_PORT" "reality cloudflare port"
mode_needs_domain && fail "reality mode must not require a domain"
mode_has_reality || fail "reality mode must include REALITY"
mode_has_cloudflare && fail "reality mode must not include Cloudflare"

reset_options
MODE="cloudflare"
resolve_default_ports
assert_eq "" "$REALITY_PORT" "cloudflare reality port"
assert_eq "443" "$CLOUDFLARE_PORT" "cloudflare port"
mode_needs_domain || fail "cloudflare mode must require a domain"
mode_has_reality && fail "cloudflare mode must not include REALITY"
mode_has_cloudflare || fail "cloudflare mode must include Cloudflare"

reset_options
MODE="dual"
resolve_default_ports
assert_eq "443" "$REALITY_PORT" "dual reality port"
assert_eq "8443" "$CLOUDFLARE_PORT" "dual cloudflare port"
mode_needs_domain || fail "dual mode must require a domain"
mode_has_reality || fail "dual mode must include REALITY"
mode_has_cloudflare || fail "dual mode must include Cloudflare"

reset_options
choose_mode <<<"3" >/dev/null
assert_eq "dual" "$MODE" "menu choice 3"

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
valid_reality_target "example.net:443" || fail "valid REALITY target rejected"
valid_reality_target "192.0.2.1:443" || fail "valid IPv4 REALITY target rejected"
valid_reality_target "/path:443" && fail "path-like REALITY hostname accepted"
valid_reality_target "*:443" && fail "wildcard REALITY hostname accepted"
valid_reality_target "bad host:443" && fail "whitespace in REALITY hostname accepted"
valid_reality_target "192.0.2.256:443" && fail "out-of-range IPv4 REALITY hostname accepted"
valid_reality_target "example.net" && fail "REALITY target without a port accepted"
valid_reality_target "example.net:65536" && fail "REALITY target with an invalid port accepted"

reset_options
parse_args \
  --mode dual \
  --domain vpn.example.com \
  --email admin@example.com \
  --reality-port 1443 \
  --cloudflare-port 2053 \
  --reality-target example.net:443 \
  --reality-uuid 11111111-1111-4111-8111-111111111111 \
  --cloudflare-uuid 22222222-2222-4222-8222-222222222222 \
  --ws-path /private \
  --rotate \
  --allow-bittorrent
assert_eq "dual" "$MODE" "parsed mode"
assert_eq "vpn.example.com" "$DOMAIN" "parsed domain"
assert_eq "admin@example.com" "$EMAIL" "parsed email"
assert_eq "1443" "$REALITY_PORT" "parsed REALITY port"
assert_eq "2053" "$CLOUDFLARE_PORT" "parsed Cloudflare port"
assert_eq "example.net:443" "$REALITY_TARGET" "parsed REALITY target"
assert_eq "11111111-1111-4111-8111-111111111111" "$REALITY_UUID" "parsed REALITY UUID"
assert_eq "22222222-2222-4222-8222-222222222222" "$CLOUDFLARE_UUID" "parsed Cloudflare UUID"
assert_eq "/private" "$WS_PATH" "parsed WebSocket path"
assert_eq "1" "$ROTATE" "parsed rotate flag"
assert_eq "1" "$ALLOW_BITTORRENT" "parsed BitTorrent flag"

usage_output="$(usage)"
for option in --mode --domain --email --reality-port --cloudflare-port --reality-target --reality-uuid --cloudflare-uuid --ws-path --rotate --allow-bittorrent --help; do
  [[ "$usage_output" == *"$option"* ]] || fail "usage is missing $option"
done
[[ "$usage_output" != *$'\n  --port '* ]] || fail "usage still exposes legacy --port"
[[ "$usage_output" != *"--tcp"* ]] || fail "usage still exposes legacy --tcp"

validate_values() {
  reset_options
  MODE="$1"
  DOMAIN="$2"
  EMAIL="$3"
  REALITY_PORT="$4"
  CLOUDFLARE_PORT="$5"
  REALITY_UUID="${6:-}"
  CLOUDFLARE_UUID="${7:-}"
  WS_PATH="${8:-}"
  validate_options
}

validate_reality_target_value() {
  reset_options
  MODE="reality"
  REALITY_TARGET="$1"
  validate_options
}

validate_values reality "" "" "" ""
assert_eq "443" "$REALITY_PORT" "validated default REALITY port"
assert_eq "" "$CLOUDFLARE_PORT" "validated inactive Cloudflare port"

validate_values dual vpn.example.com admin@example.com 1443 2053
assert_eq "1443" "$REALITY_PORT" "custom REALITY port"
assert_eq "2053" "$CLOUDFLARE_PORT" "custom Cloudflare port"

validate_values dual vpn.example.com admin@example.com 01443 02053
assert_eq "1443" "$REALITY_PORT" "canonical REALITY port"
assert_eq "2053" "$CLOUDFLARE_PORT" "canonical Cloudflare port"

validate_values cloudflare vpn.example.com admin@example.com "" "" "" "" "/valid._~-"

reset_options
assert_fails "--mode is required" select_mode </dev/null
for option in --mode --domain --email --reality-port --cloudflare-port --reality-target --reality-uuid --cloudflare-uuid --ws-path; do
  assert_fails "$option requires a value" parse_args "$option"
done
assert_fails "--domain is required" validate_values cloudflare "" admin@example.com "" ""
assert_fails "--email is required" validate_values cloudflare vpn.example.com "" "" ""
assert_fails "Invalid domain" validate_values cloudflare bad_domain admin@example.com "" ""
assert_fails "Invalid REALITY port" validate_values reality "" "" 65536 ""
assert_fails "Unsupported Cloudflare port" validate_values dual vpn.example.com admin@example.com 1443 2443
assert_fails "must be different" validate_values dual vpn.example.com admin@example.com 443 443
assert_fails "must be different" validate_values dual vpn.example.com admin@example.com 0443 443
validate_reality_target_value example.net:443
assert_fails "Invalid REALITY target" validate_reality_target_value example.net

validate_values cloudflare VPN.Example.COM admin@example.com "" 8443
assert_eq "vpn.example.com" "$DOMAIN" "Cloudflare domain is normalized to lowercase"
assert_fails "Invalid REALITY target" validate_reality_target_value example.net:65536
assert_fails "Invalid REALITY UUID" validate_values reality "" "" "" "" bad-uuid
assert_fails "Invalid Cloudflare UUID" validate_values cloudflare vpn.example.com admin@example.com "" "" "" bad-uuid
assert_fails "WebSocket path" validate_values cloudflare vpn.example.com admin@example.com "" "" "" "" private
assert_fails "WebSocket path" validate_values cloudflare vpn.example.com admin@example.com "" "" "" "" '/invalid;path'

test_renderers() (
  local temp_dir
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  reset_options
  MODE="dual"
  DOMAIN="vpn.example.com"
  REALITY_PORT="443"
  CLOUDFLARE_PORT="8443"
  INTERNAL_WS_PORT="31001"
  REALITY_UUID="11111111-1111-4111-8111-111111111111"
  CLOUDFLARE_UUID="22222222-2222-4222-8222-222222222222"
  REALITY_PRIVATE_KEY="private-key"
  REALITY_PUBLIC_KEY="public-key"
  REALITY_SHORT_ID="0123456789abcdef"
  REALITY_TARGET="www.microsoft.com:443"
  WS_PATH="/6f4f5304d2e84dc8"
  ALLOW_BITTORRENT="0"

  printf 'old permissive config\n' >"$temp_dir/config.json"
  chmod 0644 "$temp_dir/config.json"
  local old_config_inode
  old_config_inode="$(stat -c '%i' "$temp_dir/config.json")"
  render_xray_config "$temp_dir/config.json"
  assert_eq "600" "$(stat -c '%a' "$temp_dir/config.json")" \
    "replacement config permissions"
  [[ "$(stat -c '%i' "$temp_dir/config.json")" != "$old_config_inode" ]] ||
    fail "renderer did not replace the existing config atomically"
  MODE="reality"
  render_xray_config "$temp_dir/reality.json"
  assert_eq "600" "$(stat -c '%a' "$temp_dir/reality.json")" \
    "new config permissions"
  MODE="cloudflare"
  render_xray_config "$temp_dir/cloudflare.json"
  MODE="dual"
  ALLOW_BITTORRENT="1"
  render_xray_config "$temp_dir/allow-bittorrent.json"

  mkdir "$temp_dir/failed-render"
  MODE="reality"
  REALITY_PORT="invalid"
  if render_xray_config "$temp_dir/failed-render/config.json" >/dev/null 2>&1; then
    fail "renderer accepted an invalid port"
  fi
  [[ -z "$(find "$temp_dir/failed-render" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
    fail "failed renderer left a temporary file behind"
  REALITY_PORT="443"

  python3 - \
    "$temp_dir/config.json" \
    "$temp_dir/reality.json" \
    "$temp_dir/cloudflare.json" \
    "$temp_dir/allow-bittorrent.json" <<'PY'
import json
import sys


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


dual, reality_only, cloudflare_only, allow_bittorrent = map(load, sys.argv[1:])
assert dual["log"] == {"loglevel": "warning"}
assert [item["tag"] for item in dual["inbounds"]] == [
    "reality-in",
    "cloudflare-ws-in",
]

reality, cloudflare = dual["inbounds"]
assert reality["tag"] == "reality-in"
assert reality["listen"] == "0.0.0.0"
assert reality["port"] == 443
assert reality["protocol"] == "vless"
assert reality["settings"] == {
    "clients": [
        {
            "id": "11111111-1111-4111-8111-111111111111",
            "flow": "xtls-rprx-vision",
            "email": "reality",
        }
    ],
    "decryption": "none",
}
assert reality["streamSettings"]["network"] == "raw"
assert reality["streamSettings"]["security"] == "reality"
reality_settings = reality["streamSettings"]["realitySettings"]
assert reality_settings["show"] is False
assert reality_settings["target"] == "www.microsoft.com:443"
assert reality_settings["serverNames"] == ["www.microsoft.com"]
assert reality_settings["privateKey"] == "private-key"
assert reality_settings["shortIds"] == ["0123456789abcdef"]
assert "limitFallbackUpload" not in reality_settings
assert "limitFallbackDownload" not in reality_settings

assert cloudflare["tag"] == "cloudflare-ws-in"
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
assert reality["sniffing"] == sniffing
assert cloudflare["sniffing"] == sniffing
assert dual["outbounds"] == [
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
assert dual["routing"] == {
    "domainStrategy": "IPIfNonMatch",
    "rules": [private_rule, bittorrent_rule],
}
assert all(item["protocol"] != "vmess" for item in dual["inbounds"])
assert [item["tag"] for item in reality_only["inbounds"]] == ["reality-in"]
assert [item["tag"] for item in cloudflare_only["inbounds"]] == [
    "cloudflare-ws-in"
]
assert allow_bittorrent["routing"]["rules"] == [private_rule]
PY

  local reality_link cloudflare_link ipv6_link
  ALLOW_BITTORRENT="0"
  assert_eq "203.0.113.10" "$(format_uri_host "203.0.113.10")" \
    "formatted IPv4 host"
  assert_eq "[2001:db8::1]" "$(format_uri_host "2001:db8::1")" \
    "formatted IPv6 host"
  reality_link="$(make_reality_link "203.0.113.10")"
  ipv6_link="$(make_reality_link "2001:db8::1")"
  [[ "$ipv6_link" == "vless://$REALITY_UUID@[2001:db8::1]:443"* ]] ||
    fail "bad IPv6 REALITY URI: $ipv6_link"
  cloudflare_link="$(make_cloudflare_link)"
  python3 - "$reality_link" "$cloudflare_link" "$ipv6_link" <<'PY'
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


reality, reality_query = parse_link(sys.argv[1])
assert reality.username == "11111111-1111-4111-8111-111111111111"
assert reality.hostname == "203.0.113.10"
assert reality.port == 443
assert reality_query["encryption"] == "none"
assert reality_query["flow"] == "xtls-rprx-vision"
assert reality_query["security"] == "reality"
assert reality_query["sni"] == "www.microsoft.com"
assert reality_query["fp"] == "chrome"
assert reality_query["pbk"] == "public-key"
assert reality_query["sid"] == "0123456789abcdef"
assert reality_query["type"] == "tcp"
assert urllib.parse.unquote(reality.fragment) == "VLESS-REALITY-direct"

ipv6, ipv6_query = parse_link(sys.argv[3])
assert ipv6.username == "11111111-1111-4111-8111-111111111111"
assert ipv6.hostname == "2001:db8::1"
assert ipv6.port == 443
assert ipv6_query == reality_query

cloudflare, cloudflare_query = parse_link(sys.argv[2])
assert cloudflare.username == "22222222-2222-4222-8222-222222222222"
assert cloudflare.hostname == "vpn.example.com"
assert cloudflare.port == 8443
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

  local invalid_address
  for invalid_address in \
    "vpn.example.com" \
    "203.0.113.999" \
    "203.0.113.10 " \
    "203.0.113.10/path" \
    $'203.0.113.10\n@example.com'; do
    assert_invalid_uri_host "$invalid_address"
  done
)

test_renderers

test_state_round_trip() (
  local temp_dir old_inode malicious_value
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  STATE_FILE="$temp_dir/private/state.env"
  malicious_value='$(touch SHOULD_NOT_EXIST); spaces and $dollar'

  reset_options
  MODE="dual"
  DOMAIN="vpn.example.com"
  EMAIL="$malicious_value"
  REALITY_PORT="1443"
  CLOUDFLARE_PORT="2053"
  INTERNAL_WS_PORT="31001"
  REALITY_UUID="11111111-1111-4111-8111-111111111111"
  CLOUDFLARE_UUID="22222222-2222-4222-8222-222222222222"
  REALITY_PRIVATE_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  REALITY_PUBLIC_KEY="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
  REALITY_SHORT_ID="0123456789abcdef"
  REALITY_TARGET="www.microsoft.com:443"
  WS_PATH="/state-path"
  ALLOW_BITTORRENT="1"
  save_state
  assert_eq "700" "$(stat -c '%a' "$temp_dir/private")" "state directory permissions"
  assert_eq "600" "$(stat -c '%a' "$STATE_FILE")" "state file permissions"
  [[ ! -e SHOULD_NOT_EXIST ]] || fail "state data was executed"
  grep -Fq 'EMAIL=\$\(touch\ SHOULD_NOT_EXIST\)\;\ spaces\ and\ \$dollar' "$STATE_FILE" ||
    fail "state data was not shell escaped"

  reset_options
  load_state
  assert_eq "dual" "$MODE" "loaded mode"
  assert_eq "vpn.example.com" "$DOMAIN" "loaded domain"
  assert_eq "$malicious_value" "$EMAIL" "loaded shell-metacharacter value"
  assert_eq "1443" "$REALITY_PORT" "loaded REALITY port"
  assert_eq "2053" "$CLOUDFLARE_PORT" "loaded Cloudflare port"
  assert_eq "31001" "$INTERNAL_WS_PORT" "loaded internal WS port"
  assert_eq "11111111-1111-4111-8111-111111111111" "$REALITY_UUID" "loaded REALITY UUID"
  assert_eq "22222222-2222-4222-8222-222222222222" "$CLOUDFLARE_UUID" "loaded Cloudflare UUID"
  assert_eq "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "$REALITY_PRIVATE_KEY" "loaded private key"
  assert_eq "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" "$REALITY_PUBLIC_KEY" "loaded public key"
  assert_eq "0123456789abcdef" "$REALITY_SHORT_ID" "loaded short ID"
  assert_eq "www.microsoft.com:443" "$REALITY_TARGET" "loaded target"
  assert_eq "/state-path" "$WS_PATH" "loaded WS path"
  assert_eq "1" "$ALLOW_BITTORRENT" "loaded BitTorrent setting"
  assert_eq "0" "$ROTATE" "rotate is not persisted"

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
MODE=reality
DOMAIN=''
EMAIL=''
REALITY_PORT=443
CLOUDFLARE_PORT=''
INTERNAL_WS_PORT=''
REALITY_UUID=11111111-1111-4111-8111-111111111111
CLOUDFLARE_UUID=''
REALITY_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
REALITY_PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
REALITY_SHORT_ID=0123456789abcdef
REALITY_TARGET=www.microsoft.com:443
WS_PATH=''
ALLOW_BITTORRENT=0
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
  sed -i "s/^REALITY_UUID=.*/REALITY_UUID=''/" "$STATE_FILE"
  assert_fails "Invalid REALITY UUID" load_state
  sed -i 's/^REALITY_UUID=.*/REALITY_UUID=11111111-1111-4111-8111-111111111111/' "$STATE_FILE"
  sed -i 's/^REALITY_PRIVATE_KEY=.*/REALITY_PRIVATE_KEY=not-a-key/' "$STATE_FILE"
  assert_fails "Invalid REALITY private key" load_state
  sed -i 's/^REALITY_PRIVATE_KEY=.*/REALITY_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/' "$STATE_FILE"
  sed -i 's/^REALITY_SHORT_ID=.*/REALITY_SHORT_ID=not-hex/' "$STATE_FILE"
  assert_fails "Invalid REALITY short ID" load_state
  sed -i 's/^REALITY_SHORT_ID=.*/REALITY_SHORT_ID=0123456789abcdef/' "$STATE_FILE"
  sed -i 's/^REALITY_SHORT_ID=.*/REALITY_SHORT_ID=0123456789abcde/' "$STATE_FILE"
  assert_fails "Invalid REALITY short ID" load_state
  sed -i 's/^REALITY_SHORT_ID=.*/REALITY_SHORT_ID=0123456789abcdef/' "$STATE_FILE"
  sed -i 's/^CLOUDFLARE_UUID=.*/CLOUDFLARE_UUID=22222222-2222-4222-8222-222222222222/' "$STATE_FILE"
  assert_fails "Inactive Cloudflare state" load_state

  cat >"$STATE_FILE" <<'EOF'
MODE=cloudflare
DOMAIN=vpn.example.com
EMAIL=admin@example.com
REALITY_PORT=''
CLOUDFLARE_PORT=443
INTERNAL_WS_PORT=31001
REALITY_UUID=''
CLOUDFLARE_UUID=22222222-2222-4222-8222-222222222222
REALITY_PRIVATE_KEY=''
REALITY_PUBLIC_KEY=''
REALITY_SHORT_ID=''
REALITY_TARGET=www.microsoft.com:443
WS_PATH=/ws
ALLOW_BITTORRENT=0
EOF
  chmod 0600 "$STATE_FILE"
  load_state
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
  sed -i 's/^REALITY_UUID=.*/REALITY_UUID=11111111-1111-4111-8111-111111111111/' "$STATE_FILE"
  assert_fails "Inactive REALITY state" load_state

  cat >"$STATE_FILE" <<'EOF'
MODE=cloudflare
DOMAIN=bad_domain
EMAIL=admin@example.com
REALITY_PORT=''
CLOUDFLARE_PORT=99999
INTERNAL_WS_PORT=31001
REALITY_UUID=''
CLOUDFLARE_UUID=''
REALITY_PRIVATE_KEY=''
REALITY_PUBLIC_KEY=''
REALITY_SHORT_ID=''
REALITY_TARGET=www.microsoft.com:443
WS_PATH=/ws
ALLOW_BITTORRENT=0
EOF
  chmod 0600 "$STATE_FILE"
  assert_fails "Invalid domain" load_state
  printf 'MODE=reality\nEVIL=$(touch SHOULD_NOT_EXIST)\n' >"$STATE_FILE"
  assert_fails "unexpected assignment" load_state
  [[ ! -e SHOULD_NOT_EXIST ]] || fail "untrusted state line was executed"
)

test_state_round_trip
test_state_security

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
  'x25519 ') printf '%s\n' 'Private key: generated-private' 'Password: generated-public' ;;
  *) exit 1 ;;
esac
EOF
  cat >"$temp_dir/openssl" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2 $3" == 'rand -hex 8' ]] && { printf '0123456789abcdef\n'; exit; }
[[ "$1 $2 $3" == 'rand -hex 12' ]] && { printf '0123456789abcdef01234567\n'; exit; }
exit 1
EOF
  cat >"$temp_dir/shuf" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *'20000-50000'* ]] || exit 1
printf '31001\n'
EOF
  chmod +x "$temp_dir/xray" "$temp_dir/openssl" "$temp_dir/shuf"

  reset_options
  MODE="reality"
  generate_runtime_values
  assert_eq "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" "$REALITY_UUID" "generated REALITY UUID"
  assert_eq "generated-private" "$REALITY_PRIVATE_KEY" "generated REALITY private key"
  assert_eq "generated-public" "$REALITY_PUBLIC_KEY" "generated REALITY public key"
  assert_eq "0123456789abcdef" "$REALITY_SHORT_ID" "generated REALITY short ID"
  assert_eq "" "$CLOUDFLARE_UUID" "reality does not generate Cloudflare UUID"
  assert_eq "" "$INTERNAL_WS_PORT" "reality does not generate internal port"
  assert_eq "" "$WS_PATH" "reality does not generate WS path"

  reset_options
  MODE="cloudflare"
  generate_runtime_values
  assert_eq "" "$REALITY_UUID" "Cloudflare does not generate REALITY UUID"
  assert_eq "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" "$CLOUDFLARE_UUID" "generated Cloudflare UUID"
  assert_eq "31001" "$INTERNAL_WS_PORT" "generated internal port"
  assert_eq "/0123456789abcdef01234567" "$WS_PATH" "generated WS path"

  reset_options
  MODE="dual"
  REALITY_PORT="443"
  CLOUDFLARE_PORT="8443"
  generate_runtime_values
  [[ -n "$REALITY_UUID" && -n "$CLOUDFLARE_UUID" && -n "$REALITY_PRIVATE_KEY" ]] ||
    fail "dual mode did not generate both credential sets"
  REALITY_UUID="existing-reality"
  CLOUDFLARE_UUID="existing-cloudflare"
  REALITY_PRIVATE_KEY="existing-private"
  REALITY_PUBLIC_KEY="existing-public"
  REALITY_SHORT_ID="existing-short"
  INTERNAL_WS_PORT="32001"
  WS_PATH="/existing"
  generate_runtime_values
  assert_eq "existing-reality" "$REALITY_UUID" "existing REALITY UUID reused"
  assert_eq "existing-cloudflare" "$CLOUDFLARE_UUID" "existing Cloudflare UUID reused"
  assert_eq "existing-private" "$REALITY_PRIVATE_KEY" "existing private key reused"
  assert_eq "existing-public" "$REALITY_PUBLIC_KEY" "existing public key reused"
  assert_eq "existing-short" "$REALITY_SHORT_ID" "existing short ID reused"
  assert_eq "32001" "$INTERNAL_WS_PORT" "existing internal port reused"
  assert_eq "/existing" "$WS_PATH" "existing path reused"

  reset_options
  MODE="dual"
  DOMAIN="vpn.example.com"
  EMAIL="admin@example.com"
  REALITY_PORT="443"
  CLOUDFLARE_PORT="8443"
  REALITY_TARGET="www.microsoft.com:443"
  ALLOW_BITTORRENT="1"
  REALITY_UUID="one"
  CLOUDFLARE_UUID="two"
  REALITY_PRIVATE_KEY="three"
  REALITY_PUBLIC_KEY="four"
  REALITY_SHORT_ID="five"
  INTERNAL_WS_PORT="31001"
  WS_PATH="/six"
  rotate_runtime_values
  [[ -z "$REALITY_UUID$CLOUDFLARE_UUID$REALITY_PRIVATE_KEY$REALITY_PUBLIC_KEY$REALITY_SHORT_ID$INTERNAL_WS_PORT$WS_PATH" ]] ||
    fail "rotate did not clear generated runtime values"
  assert_eq "dual" "$MODE" "rotate retains mode"
  assert_eq "vpn.example.com" "$DOMAIN" "rotate retains domain"
  assert_eq "443" "$REALITY_PORT" "rotate retains public ports"
  assert_eq "www.microsoft.com:443" "$REALITY_TARGET" "rotate retains target"
  assert_eq "1" "$ALLOW_BITTORRENT" "rotate retains BitTorrent setting"

  xray() { printf '%s\n' 'Private key: private-from-public-label' 'Public key: public-fallback'; }
  read_x25519_keypair
  assert_eq "private-from-public-label" "$REALITY_PRIVATE_KEY" "parsed Private key label"
  assert_eq "public-fallback" "$REALITY_PUBLIC_KEY" "parsed Public key fallback"
  xray() { printf '%s\n' 'unparseable output'; }
  assert_fails "Unable to parse" read_x25519_keypair
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

  getent() { printf '%s\n' '104.16.1.1 STREAM www.microsoft.com'; }
  local tls_ping_target=""
  xray() {
    [[ "$1 $2" == 'tls ping' ]] || return 1
    tls_ping_target="$3"
  }
  timeout() { shift; "$@"; }
  assert_fails "resolves to Cloudflare" validate_reality_target www.microsoft.com:443
  getent() { printf '%s\n' '203.0.113.2 STREAM example.net'; }
  validate_reality_target example.net:443
  assert_eq "example.net:443" "$tls_ping_target" "REALITY TLS ping target includes port"
  xray() { return 1; }
  assert_fails "TLS ping failed" validate_reality_target example.net:443

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

test_environment_preflight() (
  reset_options
  MODE="dual"
  REALITY_PORT="443"
  CLOUDFLARE_PORT="8443"
  validate_unique_public_ports
  CLOUDFLARE_PORT="443"
  assert_fails "must be different" validate_unique_public_ports
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
  REALITY_PORT="443"
  CLOUDFLARE_PORT="8443"
  stdin_is_tty() { return 1; }
  local conflict_output=""
  if conflict_output="$(check_public_port_listeners 2>&1)"; then
    fail "noninteractive REALITY conflict unexpectedly passed"
  fi
  [[ "$conflict_output" == *'--reality-port PORT'* ]] ||
    fail "REALITY conflict lacks rerun advice: $conflict_output"
  [[ "$conflict_output" == *'ss -lntp output:'* && "$conflict_output" == *'State Recv-Q Send-Q'* ]] ||
    fail "REALITY conflict lacks complete ss output: $conflict_output"

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
  REALITY_PORT=""
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
  REALITY_PRIVATE_KEY="private-proxy-secret"
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
  grep -Fq "$REALITY_PRIVATE_KEY" "$temp_dir/site.conf" && fail "Nginx config contains proxy credentials"
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
  local temp_dir owned mixed malformed owned_disabled
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  owned="$temp_dir/v2ray-owned.conf"
  mixed="$temp_dir/v2ray-mixed.conf"
  malformed="$temp_dir/v2ray-malformed.conf"
  NGINX_SITE="$temp_dir/v2ray-onekey.conf"
  BACKUP_DIR="$temp_dir/backup"
  RUN_TIMESTAMP="20260719T010000Z"
  legacy_nginx_config_path() { [[ "$1" == "$owned" || "$1" == "$mixed" || "$1" == "$malformed" ]]; }
  legacy_nginx_config_paths() { printf '%s\n' "$owned" "$mixed" "$malformed"; }

  cat >"$owned" <<'EOF'
# comments outside the only server block are allowed
server {
  proxy_set_header Upgrade $http_upgrade;
  proxy_pass http://127.0.0.1:31001;
  return 200 "ok\n";
}
EOF
  cat >"$mixed" <<'EOF'
server {
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
  proxy_set_header Upgrade $http_upgrade;
  proxy_pass http://127.0.0.1:31001;
  return 200 "ok\n";
EOF

  python3() { return 127; }
  legacy_nginx_config_is_project_owned "$owned" ||
    fail "valid legacy Nginx file required python3 for ownership classification"
  legacy_nginx_config_is_project_owned "$mixed" &&
    fail "mixed legacy Nginx file was accepted without python3"
  legacy_nginx_config_is_project_owned "$malformed" &&
    fail "malformed legacy Nginx file was accepted without python3"

  init_backup_metadata
  collect_owned_legacy_nginx_files
  grep -Fqx "$owned" "$BACKUP_DIR/legacy-files" || fail "owned legacy Nginx file was not collected"
  grep -Fqx "$mixed" "$BACKUP_DIR/legacy-files" && fail "mixed legacy Nginx file was collected"
  grep -Fqx "$malformed" "$BACKUP_DIR/legacy-files" && fail "malformed legacy Nginx file was collected"
  [[ -f "$BACKUP_DIR$owned" ]] || fail "owned legacy Nginx file was not backed up"
  [[ ! -e "$BACKUP_DIR$mixed" ]] || fail "mixed legacy Nginx file was backed up"

  disable_owned_legacy_nginx_files
  owned_disabled="${owned}.v2ray-onekey-disabled-${RUN_TIMESTAMP}"
  [[ -f "$owned_disabled" && ! -e "$owned" ]] || fail "owned legacy Nginx file was not disabled"
  [[ -f "$mixed" ]] || fail "mixed legacy Nginx file was renamed or disabled"
  if grep -Fq "$mixed" "$BACKUP_DIR/legacy-renames"; then
    fail "mixed legacy Nginx rename was recorded"
  fi
)

test_mixed_legacy_nginx_file_is_never_disabled
printf 'PASS: mixed legacy Nginx ownership tests\n'

test_reality_mode_removes_owned_cloudflare_files_transactionally() (
  local temp_dir service_log
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  MODE="reality"
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
  [[ ! -e "$NGINX_SITE" && ! -e "$RENEWAL_HOOK" ]] || fail "owned Cloudflare files remained in reality mode"
  grep -Fq 'nginx -t' "$service_log" || fail "Nginx was not validated after reality-mode cleanup"
  grep -Fq 'systemctl reload nginx' "$service_log" || fail "Nginx was not reloaded after reality-mode cleanup"
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
  [[ -f "$NGINX_SITE" ]] || fail "reality transition removed a mixed current Nginx site"
  assert_eq "$mixed_site_content" "$(cat "$NGINX_SITE")" "mixed current Nginx site preservation"
  grep -Fqx 'echo unrelated' "$RENEWAL_HOOK" || fail "extra-command renewal hook was modified"
)

test_reality_mode_removes_owned_cloudflare_files_transactionally
printf 'PASS: reality mode Cloudflare-file transition tests\n'

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
  MODE="dual"
  DOMAIN="vpn.example.com"
  EMAIL="admin@example.com"
  REALITY_PORT="443"
  CLOUDFLARE_PORT="8443"
  INTERNAL_WS_PORT="31001"
  REALITY_UUID="11111111-1111-4111-8111-111111111111"
  CLOUDFLARE_UUID="22222222-2222-4222-8222-222222222222"
  REALITY_PRIVATE_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  REALITY_PUBLIC_KEY="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
  REALITY_SHORT_ID="0123456789abcdef"
  REALITY_TARGET="www.microsoft.com:443"
  WS_PATH="/saved-path"
  save_state

  reset_options
  parse_args
  prepare_configuration
  assert_eq "dual" "$MODE" "existing state mode reused without prompt"
  assert_eq "/saved-path" "$WS_PATH" "existing credentials reused"

  reset_options
  parse_args --rotate
  prepare_configuration
  assert_eq "dual" "$MODE" "rotate retained saved mode"
  assert_eq "vpn.example.com" "$DOMAIN" "rotate retained saved domain"
  assert_eq "443" "$REALITY_PORT" "rotate retained saved public port"
  assert_eq "" "$REALITY_UUID" "rotate cleared REALITY UUID"
  assert_eq "" "$CLOUDFLARE_UUID" "rotate cleared Cloudflare UUID"
  assert_eq "" "$WS_PATH" "rotate cleared WebSocket path"
)

test_prepare_configuration_reuse_and_rotate
printf 'PASS: state reuse and rotation tests\n'

test_port_resolution() (
  reset_options
  MODE="dual"
  DOMAIN="vpn.example.com"
  REALITY_PORT="443"
  CLOUDFLARE_PORT="8443"
  stdin_is_tty() { return 0; }
  port_listener_conflicts() {
    local role="$1" port="$2"
    PORT_CONFLICT_DETAILS="mock conflict"
    [[ "$role:$port" == "reality:443" || "$role:$port" == "cloudflare:8443" ]]
  }
  resolve_public_port_conflicts <<'EOF'
8443
4443
2443
2053
EOF
  assert_eq "4443" "$REALITY_PORT" "interactive REALITY replacement"
  assert_eq "2053" "$CLOUDFLARE_PORT" "Cloudflare allowlisted replacement"
  validate_unique_public_ports

  reset_options
  MODE="reality"
  REALITY_PORT="443"
  stdin_is_tty() { return 1; }
  port_listener_conflicts() { PORT_CONFLICT_DETAILS="occupied by other"; return 0; }
  assert_fails "--reality-port PORT" resolve_public_port_conflicts
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
  MODE="reality"
  install_required_packages
  grep -Fq 'curl ca-certificates openssl python3 coreutils iproute2' "$package_log" ||
    fail "base package set is incomplete"
  grep -Eq 'nginx|certbot' "$package_log" && fail "reality-only installed Cloudflare packages"
  : >"$package_log"
  MODE="cloudflare"
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

test_deployment_order_and_failure_trap() (
  local temp_dir order_log status
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  order_log="$temp_dir/order.log"
  event() { printf '%s\n' "$1" >>"$order_log"; }
  reset_options
  MODE="reality"
  REALITY_PORT="443"
  REALITY_TARGET="example.net:443"
  RUNTIME_DIR="$temp_dir/run"
  ACME_WEBROOT="$temp_dir/acme"
  begin_transaction() { RUN_TIMESTAMP="test"; BACKUP_DIR="$temp_dir/backup"; install -d "$BACKUP_DIR"; event backup; }
  validate_managed_destination_ownership() { event ownership; }
  install_required_packages() { event packages; }
  install_xray_core() { event xray-install; }
  generate_runtime_values() { event generate; }
  validate_loaded_runtime_values() { event runtime-validate; }
  download_cloudflare_ranges() { event cf-download; }
  write_builtin_cloudflare_ranges() { event cf-builtin; }
  validate_reality_target() { event target; }
  public_ip() { printf '1.1.1.1'; }
  valid_public_ip() { [[ "$1" == "1.1.1.1" ]]; }
  format_uri_host() { printf '%s\n' "$1"; }
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
  grep -Fq 'cf-download' "$order_log" && fail "reality-only downloaded Cloudflare ranges"
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
  valid_public_ip "1.1.1.1" || fail "public IP validator rejected a global address"
  valid_public_ip "203.0.113.10" && fail "documentation-only address was accepted as public"
  valid_public_ip "10.0.0.1" && fail "private address was accepted as public"
  reset_options
  MODE="dual"
  DOMAIN="vpn.example.com"
  REALITY_PORT="4443"
  CLOUDFLARE_PORT="2053"
  REALITY_TARGET="www.microsoft.com:443"
  REALITY_UUID="11111111-1111-4111-8111-111111111111"
  CLOUDFLARE_UUID="22222222-2222-4222-8222-222222222222"
  REALITY_PUBLIC_KEY="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
  REALITY_SHORT_ID="0123456789abcdef"
  WS_PATH="/saved-path"
  PUBLIC_ADDRESS="1.1.1.1"
  STATE_FILE="/etc/v2ray-onekey/state.env"
  BACKUP_DIR="/var/backups/v2ray-onekey/test"
  local output
  output="$(print_deployment_summary)"
  [[ "$output" == *'Primary direct entry: VLESS + REALITY + XTLS Vision'* ]] || fail "dual output lacks direct label"
  [[ "$output" == *'Fallback entry: VLESS + WebSocket + TLS + Cloudflare'* ]] || fail "dual output lacks CF label"
  [[ "$output" == *'@1.1.1.1:4443'* && "$output" == *'@vpn.example.com:2053'* ]] || fail "final selected ports not printed"
  MODE="reality"
  output="$(print_deployment_summary)"
  [[ "$output" == *'Primary direct entry:'* && "$output" != *'Fallback entry:'* ]] || fail "reality output labels are wrong"
  MODE="cloudflare"
  output="$(print_deployment_summary)"
  [[ "$output" != *'Primary direct entry:'* && "$output" == *'Fallback entry:'* ]] || fail "Cloudflare output labels are wrong"
)

test_mode_specific_output
printf 'PASS: mode-specific output tests\n'

printf 'PASS: mode and validation tests\n'
