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

test_renderers() {
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
}

test_renderers

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
