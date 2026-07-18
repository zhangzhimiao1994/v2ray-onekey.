#!/usr/bin/env bash
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
  --cloudflare-port 2443 \
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
assert_eq "2443" "$CLOUDFLARE_PORT" "parsed Cloudflare port"
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

validate_values dual vpn.example.com admin@example.com 1443 2443
assert_eq "1443" "$REALITY_PORT" "custom REALITY port"
assert_eq "2443" "$CLOUDFLARE_PORT" "custom Cloudflare port"

validate_values dual vpn.example.com admin@example.com 01443 02443
assert_eq "1443" "$REALITY_PORT" "canonical REALITY port"
assert_eq "2443" "$CLOUDFLARE_PORT" "canonical Cloudflare port"

reset_options
assert_fails "--mode is required" select_mode </dev/null
for option in --mode --domain --email --reality-port --cloudflare-port --reality-target --reality-uuid --cloudflare-uuid --ws-path; do
  assert_fails "$option requires a value" parse_args "$option"
done
assert_fails "--domain is required" validate_values cloudflare "" admin@example.com "" ""
assert_fails "--email is required" validate_values cloudflare vpn.example.com "" "" ""
assert_fails "Invalid domain" validate_values cloudflare bad_domain admin@example.com "" ""
assert_fails "Invalid REALITY port" validate_values reality "" "" 65536 ""
assert_fails "must be different" validate_values dual vpn.example.com admin@example.com 443 443
assert_fails "must be different" validate_values dual vpn.example.com admin@example.com 0443 443
validate_reality_target_value example.net:443
assert_fails "Invalid REALITY target" validate_reality_target_value example.net
assert_fails "Invalid REALITY target" validate_reality_target_value example.net:65536
assert_fails "Invalid REALITY UUID" validate_values reality "" "" "" "" bad-uuid
assert_fails "Invalid Cloudflare UUID" validate_values cloudflare vpn.example.com admin@example.com "" "" "" bad-uuid
assert_fails "WebSocket path must start with /" validate_values cloudflare vpn.example.com admin@example.com "" "" "" "" private

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
fallback_limit = {
    "afterBytes": 1048576,
    "bytesPerSec": 102400,
    "burstBytesPerSec": 1048576,
}
assert reality_settings["limitFallbackUpload"] == fallback_limit
assert reality_settings["limitFallbackDownload"] == fallback_limit

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
  CLOUDFLARE_PORT="2443"
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
  assert_eq "2443" "$CLOUDFLARE_PORT" "loaded Cloudflare port"
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
  xray() { printf '%s\n' 'tls ping'; }
  timeout() { shift; "$@"; }
  assert_fails "resolves to Cloudflare" validate_reality_target www.microsoft.com:443
  getent() { printf '%s\n' '203.0.113.2 STREAM example.net'; }
  validate_reality_target example.net:443
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

  ss() {
    if [[ "$#" -eq 3 && "$1 $2 $3" == '-H -ltnp sport = :443' ]]; then
      printf '%s\n' 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=1,fd=3))'
    elif [[ "$#" -eq 3 && "$1 $2 $3" == '-H -ltnp sport = :8443' ]]; then
      :
    elif [[ "$#" -eq 1 && "$1" == '-lntp' ]]; then
      printf '%s\n' 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process' \
        'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=1,fd=3))'
    else
      return 1
    fi
  }
  REALITY_PORT="443"
  CLOUDFLARE_PORT="8443"
  assert_fails "State Recv-Q Send-Q" check_public_port_listeners

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
)

test_environment_preflight

execution_output=""
if execution_output="$(
  (
    id() {
      [[ "${1:-}" == "-u" ]] || return 1
      printf '0\n'
    }
    main --mode reality
  ) 2>&1
)"; then
  fail "feature-branch execution must fail closed"
fi
[[ "$execution_output" == *"Deployment backend is being migrated; do not deploy from this feature branch yet."* ]] ||
  fail "execution did not reach the fail-closed migration guard: $execution_output"
for removed_reference in validate_runtime PORT UUID; do
  [[ "$execution_output" != *"$removed_reference"* ]] ||
    fail "execution referenced removed legacy state $removed_reference: $execution_output"
done

printf 'PASS: mode and validation tests\n'
