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
HY2_TEST_AUTH="MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY"
HY2_TEST_OBFS="ZmVkY2JhOTg3NjU0MzIxMGZlZGNiYTk4NzY1NDMyMTA"
HY2_TEST_SNI="0123456789abcdef.invalid"
HY2_TEST_PIN="$(printf 'AB:%.0s' {1..31})AB"
assert_state_keys() {
  local actual
  actual="$(printf '%s ' "${STATE_KEYS[@]}")"
  assert_eq "$expected_state_keys" "${actual% }" "schema 2 state keys"
}

assert_state_keys
assert_eq "https://download.hysteria.network/app/latest/hysteria-linux-amd64" \
  "${HYSTERIA_DOWNLOAD_URL-}" "official Hysteria2 download URL"
assert_eq "/usr/local/bin/hysteria" "${HYSTERIA_BIN-}" "Hysteria2 binary path"
assert_eq "/etc/hysteria/config.yaml" "${HYSTERIA_CONFIG-}" "Hysteria2 config path"
assert_eq "/etc/hysteria/acl.txt" "${HYSTERIA_ACL-}" "Hysteria2 ACL path"
assert_eq "/etc/hysteria/server.crt" "${HYSTERIA_CERT-}" "Hysteria2 certificate path"
assert_eq "/etc/hysteria/server.key" "${HYSTERIA_KEY-}" "Hysteria2 key path"
assert_eq "/etc/systemd/system/hysteria-server.service" "${HYSTERIA_UNIT-}" \
  "Hysteria2 systemd unit path"
grep -Fqx '  local staged="$1" staged_dir effective_file="" hashes_file="" effective_url=""' \
  "$SCRIPT" || fail "Hysteria2 cleanup trap temporary paths must be explicitly initialized"
inherited_hysteria_paths="$(
  HYSTERIA_BIN=/tmp/injected-bin \
  HYSTERIA_CONFIG=$'/tmp/injected\nconfig' \
  HYSTERIA_ACL=/tmp/injected-acl \
  HYSTERIA_CERT=/tmp/injected-cert \
  HYSTERIA_KEY=/tmp/injected-key \
  HYSTERIA_UNIT=/tmp/injected-unit \
  V2RAY_ONEKEY_SOURCE_ONLY=1 bash -c \
    'source "$1"; printf "%s\n%s\n%s\n%s\n%s\n%s\n" "$HYSTERIA_BIN" "$HYSTERIA_CONFIG" "$HYSTERIA_ACL" "$HYSTERIA_CERT" "$HYSTERIA_KEY" "$HYSTERIA_UNIT"' \
    bash "$SCRIPT"
)"
assert_eq $'/usr/local/bin/hysteria\n/etc/hysteria/config.yaml\n/etc/hysteria/acl.txt\n/etc/hysteria/server.crt\n/etc/hysteria/server.key\n/etc/systemd/system/hysteria-server.service' \
  "$inherited_hysteria_paths" "inherited Hysteria2 path overrides must be ignored"

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
valid_hy2_port_range "1-1001" || fail "Hysteria2 range with span 1000 rejected"
valid_hy2_port_range "1-1002" && fail "Hysteria2 range with span larger than 1000 accepted"
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
  HY2_AUTH="$HY2_TEST_AUTH"
  HY2_OBFS_PASSWORD="$HY2_TEST_OBFS"
  HY2_SNI="$HY2_TEST_SNI"
  HY2_CERT_PIN="$HY2_TEST_PIN"
  SS_METHOD="aes-256-gcm"
  SS_KEY="$SS_TEST_KEY"
  assert_fails "Invalid Shadowsocks method in state" validate_loaded_runtime_values

  SS_METHOD="2022-blake3-aes-128-gcm"
  SS_KEY="MDEyMzQ1Njc4OWFiY2RlZh=="
  assert_fails "Invalid Shadowsocks key in state" validate_loaded_runtime_values
)

test_shadowsocks_key_validation

test_hysteria_validation_and_rendering() (
  local temp_dir old_path real_openssl expected_acl expected_acl_mail expected_unit
  local ipv4_link ipv6_link hostname_link uppercase_link secret expected_pin
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  valid_hy2_secret "$HY2_TEST_AUTH" || fail "valid Hysteria2 auth rejected"
  valid_hy2_secret "$HY2_TEST_OBFS" || fail "valid Hysteria2 obfs password rejected"
  valid_hy2_secret "${HY2_TEST_AUTH}A" && fail "oversized Hysteria2 secret accepted"
  valid_hy2_secret "bad+secret" && fail "non-URL-safe Hysteria2 secret accepted"
  valid_hy2_sni "$HY2_TEST_SNI" || fail "valid generated Hysteria2 SNI rejected"
  valid_hy2_sni "VPN.example.com" && fail "non-generated Hysteria2 SNI accepted"
  valid_hy2_cert_pin "$HY2_TEST_PIN" || fail "valid certificate pin rejected"
  valid_hy2_cert_pin "sha256:$HY2_TEST_PIN" && fail "prefixed certificate pin accepted"
  valid_hy2_cert_pin "${HY2_TEST_PIN,,}" && fail "lowercase certificate pin accepted"

  reset_options
  MODE="direct"
  HY2_AUTH="$HY2_TEST_AUTH"
  HY2_OBFS_PASSWORD="$HY2_TEST_OBFS"
  HY2_SNI="$HY2_TEST_SNI"
  HY2_CERT_PIN="$HY2_TEST_PIN"
  SS_METHOD="2022-blake3-aes-128-gcm"
  SS_KEY="$SS_TEST_KEY"
  validate_loaded_runtime_values
  HY2_AUTH="short"
  assert_fails "Invalid Hysteria2 authentication value in state" validate_loaded_runtime_values
  HY2_AUTH="$HY2_TEST_AUTH"
  HY2_SNI="vpn.example.com"
  assert_fails "Invalid Hysteria2 SNI in state" validate_loaded_runtime_values
  HY2_SNI="$HY2_TEST_SNI"
  HY2_CERT_PIN="invalid"
  assert_fails "Invalid Hysteria2 certificate pin in state" validate_loaded_runtime_values

  old_path="$PATH"
  install -d -m 700 "$temp_dir/runtime" "$temp_dir/bin"
  cat >"$temp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HY2_CURL_LOG"
output="" url="" write_out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) output="$2"; shift 2 ;;
    -w|--write-out) write_out="$2"; shift 2 ;;
    --proto|--proto-redir|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
[[ -n "$output" && -n "$url" ]] || exit 2
if [[ "$url" == *'/hashes.txt' ]]; then
  hash="$(sha256sum "$HY2_DOWNLOADED_BINARY" | awk '{print $1}')"
  case "$HY2_CURL_SCENARIO" in
    success|http-effective|wrong-owner) printf '%s  build/hysteria-linux-amd64\n' "$hash" >"$output" ;;
    mismatch) printf '%064d  build/hysteria-linux-amd64\n' 0 >"$output" ;;
    malformed) printf '%s build/hysteria-linux-amd64\n' "$hash" >"$output" ;;
    duplicate) printf '%s  build/hysteria-linux-amd64\n%s  build/hysteria-linux-amd64\n' "$hash" "$hash" >"$output" ;;
    missing) printf '%s  build/hysteria-linux-arm64\n' "$hash" >"$output" ;;
    *) exit 3 ;;
  esac
  exit 0
fi
cat >"$output" <<'BIN'
#!/usr/bin/env bash
printf '%s mode=%s\n' "$*" "$(stat -c '%a' "$0")" >>"$HY2_BINARY_LOG"
[[ "${1:-}" == "version" ]]
BIN
HY2_DOWNLOADED_BINARY="$output"
export HY2_DOWNLOADED_BINARY
case "$HY2_CURL_SCENARIO" in
  http-effective) effective='http://download.hysteria.network/app/v2.10.0/hysteria-linux-amd64' ;;
  wrong-owner) effective='https://downloads.example.net/app/v2.10.0/hysteria-linux-amd64' ;;
  latest-effective) effective='https://download.hysteria.network/app/latest/hysteria-linux-amd64' ;;
  unversioned-effective) effective='https://download.hysteria.network/app/hysteria-linux-amd64' ;;
  *) effective='https://download.hysteria.network/app/v2.10.0/hysteria-linux-amd64' ;;
esac
[[ -z "$write_out" ]] || printf '%s\n' "$effective"
EOF
  chmod +x "$temp_dir/bin/curl"
  : >"$temp_dir/curl.log"
  : >"$temp_dir/binary.log"
  export HY2_CURL_LOG="$temp_dir/curl.log" HY2_BINARY_LOG="$temp_dir/binary.log"
  export HY2_DOWNLOADED_BINARY="$temp_dir/runtime/hysteria"
  PATH="$temp_dir/bin:$PATH"
  HY2_CURL_SCENARIO="success"
  export HY2_CURL_SCENARIO
  stage_hysteria_binary "$temp_dir/runtime/hysteria"
  assert_eq "755" "$(stat -c '%a' "$temp_dir/runtime/hysteria")" \
    "validated Hysteria2 staging binary mode"
  assert_eq "2" "$(grep -Fc -- '--proto =https' "$temp_dir/curl.log")" \
    "binary and checksum downloads require HTTPS"
  assert_eq "2" "$(grep -Fc -- '--proto-redir =https' "$temp_dir/curl.log")" \
    "binary and checksum redirects require HTTPS"
  assert_eq "2" "$(grep -Fc -- '--connect-timeout 10' "$temp_dir/curl.log")" \
    "binary and checksum curl connect timeouts"
  assert_eq "2" "$(grep -Fc -- '--max-time 120' "$temp_dir/curl.log")" \
    "binary and checksum curl total timeouts"
  grep -Fq -- "$HYSTERIA_DOWNLOAD_URL" "$temp_dir/curl.log" || fail "Hysteria2 curl URL is wrong"
  grep -Fq -- 'https://github.com/apernet/hysteria/releases/download/app/v2.10.0/hashes.txt' \
    "$temp_dir/curl.log" || fail "Hysteria2 hashes URL did not use the exact binary release"
  assert_eq "version mode=700" "$(cat "$temp_dir/binary.log")" \
    "Hysteria2 binary must execute privately only after checksum validation"
  [[ -z "$(find "$temp_dir/runtime" -maxdepth 1 -type f \
    \( -name '.hysteria-effective.*' -o -name '.hysteria-hashes.*' \) -print -quit)" ]] ||
    fail "successful Hysteria2 staging leaked checksum temporary files"

  printf 'preserve-final\n' >"$temp_dir/final-hysteria"
  HYSTERIA_BIN="$temp_dir/final-hysteria"
  for scenario in \
    http-effective wrong-owner latest-effective unversioned-effective \
    mismatch malformed duplicate missing; do
    : >"$temp_dir/binary.log"
    : >"$temp_dir/curl.log"
    HY2_CURL_SCENARIO="$scenario"
    export HY2_CURL_SCENARIO
    assert_fails "Hysteria2" stage_hysteria_binary "$temp_dir/runtime/fail-$scenario"
    [[ ! -s "$temp_dir/binary.log" ]] ||
      fail "Hysteria2 version executed before trust validation for $scenario"
    assert_eq "preserve-final" "$(cat "$HYSTERIA_BIN")" \
      "failed staging mutated the final binary for $scenario"
    if [[ -e "$temp_dir/runtime/fail-$scenario" ]]; then
      (( (8#$(stat -c '%a' "$temp_dir/runtime/fail-$scenario") & 0022) == 0 )) ||
        fail "failed Hysteria2 binary became group/world executable for $scenario"
    fi
    [[ -z "$(find "$temp_dir/runtime" -maxdepth 1 -type f \
      \( -name '.hysteria-effective.*' -o -name '.hysteria-hashes.*' \) -print -quit)" ]] ||
      fail "failed Hysteria2 staging leaked checksum temporary files for $scenario"
  done
  PATH="$old_path"
  unset HY2_CURL_LOG HY2_BINARY_LOG HY2_CURL_SCENARIO HY2_DOWNLOADED_BINARY

  reset_options
  MODE="direct"
  HY2_PORT_RANGE="20000-20100"
  HY2_AUTH="$HY2_TEST_AUTH"
  HY2_OBFS_PASSWORD="$HY2_TEST_OBFS"
  HY2_SNI="$HY2_TEST_SNI"
  HY2_CERT_PIN=""
  SS_PORT="8388"
  SS_METHOD="2022-blake3-aes-128-gcm"
  SS_KEY="$SS_TEST_KEY"
  SERVER_ADDRESS="192.0.2.10"

  real_openssl="$(command -v openssl)"
  install -d "$temp_dir/openssl-bin"
cat >"$temp_dir/openssl-bin/openssl" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >>"$OPENSSL_ARGV_LOG"
for name in HY2_AUTH HY2_OBFS_PASSWORD HY2_SNI HY2_CERT_PIN SS_KEY; do
  [[ -z ${!name+x} ]] || printf '%s\n' "$name" >>"$OPENSSL_ENV_LOG"
done
if [[ "${OPENSSL_FAIL_X509:-0}" == "1" && "${1:-}" == "x509" ]]; then
  exit 42
fi
exec "$REAL_OPENSSL" "$@"
EOF
  chmod +x "$temp_dir/openssl-bin/openssl"
  : >"$temp_dir/openssl-argv.log"
  : >"$temp_dir/openssl-env.log"
  export OPENSSL_ARGV_LOG="$temp_dir/openssl-argv.log"
  export OPENSSL_ENV_LOG="$temp_dir/openssl-env.log"
  export REAL_OPENSSL="$real_openssl"
  export HY2_AUTH HY2_OBFS_PASSWORD HY2_SNI HY2_CERT_PIN SS_KEY
  PATH="$temp_dir/openssl-bin:$PATH"
  generate_hysteria_certificate "$temp_dir/server.crt" "$temp_dir/server.key"
  OPENSSL_FAIL_X509="1"
  export OPENSSL_FAIL_X509
  assert_fails "Unable to generate the Hysteria2 certificate" generate_hysteria_certificate \
    "$temp_dir/failed-server.crt" "$temp_dir/failed-server.key"
  unset OPENSSL_FAIL_X509
  [[ ! -e "$temp_dir/failed-server.crt" && ! -e "$temp_dir/failed-server.key" ]] ||
    fail "failed Hysteria2 certificate generation left staged certificate material"
  [[ -z "$(find "$temp_dir" -maxdepth 1 -name '.openssl-hysteria.*' -print -quit)" ]] ||
    fail "failed Hysteria2 certificate generation leaked an OpenSSL config"
  PATH="$old_path"
  unset OPENSSL_ARGV_LOG OPENSSL_ENV_LOG REAL_OPENSSL
  assert_eq "400" "$(stat -c '%a' "$temp_dir/server.key")" "staged Hysteria2 key mode"
  (( (8#$(stat -c '%a' "$temp_dir/server.crt") & 0004) == 0 )) ||
    fail "staged Hysteria2 certificate is world-readable"
  "$real_openssl" ec -in "$temp_dir/server.key" -noout -text 2>/dev/null |
    grep -Fq 'ASN1 OID: prime256v1' || fail "Hysteria2 key is not ECDSA P-256"
  "$real_openssl" x509 -in "$temp_dir/server.crt" -noout -text |
    grep -Fq "DNS:$HY2_TEST_SNI" || fail "Hysteria2 certificate SAN is missing"
  "$real_openssl" x509 -in "$temp_dir/server.crt" -noout -checkend 300000000 >/dev/null ||
    fail "Hysteria2 certificate lifetime is shorter than ten years"
  valid_hy2_cert_pin "$HY2_CERT_PIN" || fail "generated certificate pin has wrong format"
  expected_pin="$(
    "$real_openssl" x509 -noout -fingerprint -sha256 -in "$temp_dir/server.crt" |
      cut -d= -f2 | tr -d '\r\n'
  )"
  assert_eq "$expected_pin" "$HY2_CERT_PIN" "Hysteria2 certificate pin content"
  [[ ! -s "$temp_dir/openssl-env.log" ]] ||
    fail "OpenSSL inherited sensitive values: $(paste -sd, "$temp_dir/openssl-env.log")"
  for secret in "$HY2_TEST_AUTH" "$HY2_TEST_OBFS" "$HY2_TEST_SNI"; do
    grep -aFq "$secret" "$temp_dir/openssl-argv.log" &&
      fail "sensitive Hysteria2 value was exposed in OpenSSL argv"
  done

  HYSTERIA_CONFIG="/etc/hysteria/config.yaml"
  HYSTERIA_ACL="/etc/hysteria/acl.txt"
  HYSTERIA_CERT="/etc/hysteria/server.crt"
  HYSTERIA_KEY="/etc/hysteria/server.key"
  real_python="$(command -v python3)"
  install -d "$temp_dir/render-python-bin"
  cat >"$temp_dir/render-python-bin/python3" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >>"$PYTHON_ARGV_LOG"
for name in HY2_AUTH HY2_OBFS_PASSWORD HY2_SNI HY2_CERT_PIN; do
  [[ -z ${!name+x} ]] || printf '%s\n' "$name" >>"$PYTHON_ENV_LOG"
done
exec "$REAL_PYTHON" "$@"
EOF
  chmod +x "$temp_dir/render-python-bin/python3"
  : >"$temp_dir/render-python-argv.log"
  : >"$temp_dir/render-python-env.log"
  export REAL_PYTHON="$real_python"
  export PYTHON_ARGV_LOG="$temp_dir/render-python-argv.log"
  export PYTHON_ENV_LOG="$temp_dir/render-python-env.log"
  export HY2_AUTH HY2_OBFS_PASSWORD HY2_SNI HY2_CERT_PIN
  PATH="$temp_dir/render-python-bin:$PATH"
  render_hysteria_config "$temp_dir/install.yaml" \
    "$HYSTERIA_CERT" "$HYSTERIA_KEY" "$HYSTERIA_ACL"
  render_hysteria_config "$temp_dir/staged.yaml" \
    "$temp_dir/server.crt" "$temp_dir/server.key" "$temp_dir/staged-acl.txt"
  PATH="$old_path"
  unset REAL_PYTHON PYTHON_ARGV_LOG PYTHON_ENV_LOG
  [[ ! -s "$temp_dir/render-python-env.log" ]] ||
    fail "Hysteria renderer inherited sensitive values: $(paste -sd, "$temp_dir/render-python-env.log")"
  for secret in "$HY2_TEST_AUTH" "$HY2_TEST_OBFS" "$HY2_TEST_SNI"; do
    grep -aFq "$secret" "$temp_dir/render-python-argv.log" &&
      fail "Hysteria renderer value was exposed in Python argv"
  done
  assert_eq "600" "$(stat -c '%a' "$temp_dir/install.yaml")" "Hysteria2 YAML mode"
  grep -Fqx 'listen: ":20000-20100"' "$temp_dir/install.yaml" ||
    fail "Hysteria2 YAML listen text is wrong"
  grep -Fqx '  sniGuard: "strict"' "$temp_dir/install.yaml" ||
    fail "Hysteria2 YAML sniGuard text is wrong"
  python3 - "$temp_dir/install.yaml" "$temp_dir/staged.yaml" \
    "$HY2_TEST_AUTH" "$HY2_TEST_OBFS" <<'PY'
import json
import sys


def parse_yaml_subset(path):
    result = {}
    stack = [(-1, result)]
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            if not raw.strip():
                continue
            if raw.lstrip().startswith("#"):
                continue
            indent = len(raw) - len(raw.lstrip(" "))
            key, value = raw.strip().split(":", 1)
            while stack[-1][0] >= indent:
                stack.pop()
            parent = stack[-1][1]
            if value.strip():
                parent[key] = json.loads(value.strip())
            else:
                parent[key] = {}
                stack.append((indent, parent[key]))
    return result


install, staged = map(parse_yaml_subset, sys.argv[1:3])
expected = {
    "listen": ":20000-20100",
    "tls": {
        "cert": "/etc/hysteria/server.crt",
        "key": "/etc/hysteria/server.key",
        "sniGuard": "strict",
    },
    "auth": {"type": "password", "password": sys.argv[3]},
    "obfs": {
        "type": "salamander",
        "salamander": {"password": sys.argv[4]},
    },
    "acl": {"file": "/etc/hysteria/acl.txt"},
}
assert install == expected
assert staged["tls"]["cert"].endswith("/server.crt")
assert staged["tls"]["key"].endswith("/server.key")
assert staged["acl"]["file"].endswith("/staged-acl.txt")
assert staged["auth"] == expected["auth"]
assert staged["obfs"] == expected["obfs"]
PY

  printf 'direct(all)\n' >"$temp_dir/source-acl.txt"
  ln -s "$temp_dir/server.crt" "$temp_dir/symlink-cert"
  printf 'preserve-symlink-render\n' >"$temp_dir/symlink-render.yaml"
  assert_fails "must not be a symlink" render_hysteria_config \
    "$temp_dir/symlink-render.yaml" "$temp_dir/symlink-cert" \
    "$temp_dir/server.key" "$temp_dir/source-acl.txt"
  assert_eq "preserve-symlink-render" "$(cat "$temp_dir/symlink-render.yaml")" \
    "symlink source rejection mutated the final config"
  [[ -z "$(find "$temp_dir" -maxdepth 1 -type f -name '.hysteria-config.*' -print -quit)" ]] ||
    fail "symlink source rejection leaked a private renderer temporary file"

  install -d "$temp_dir/failing-tools"
  cat >"$temp_dir/failing-tools/mv" <<'EOF'
#!/usr/bin/env bash
exit 73
EOF
  chmod +x "$temp_dir/failing-tools/mv"
  printf 'preserve-config\n' >"$temp_dir/preserved.yaml"
  printf 'preserve-acl\n' >"$temp_dir/preserved-acl.txt"
  printf 'preserve-unit\n' >"$temp_dir/preserved.service"
  PATH="$temp_dir/failing-tools:$PATH"
  if render_hysteria_config "$temp_dir/preserved.yaml" \
    "$HYSTERIA_CERT" "$HYSTERIA_KEY" "$HYSTERIA_ACL"; then
    fail "Hysteria2 config renderer accepted a failed atomic replace"
  fi
  if render_hysteria_acl "$temp_dir/preserved-acl.txt"; then
    fail "Hysteria2 ACL renderer accepted a failed atomic replace"
  fi
  if render_hysteria_unit "$temp_dir/preserved.service"; then
    fail "Hysteria2 unit renderer accepted a failed atomic replace"
  fi
  PATH="$old_path"
  assert_eq "preserve-config" "$(cat "$temp_dir/preserved.yaml")" \
    "failed config render mutated its final file"
  assert_eq "preserve-acl" "$(cat "$temp_dir/preserved-acl.txt")" \
    "failed ACL render mutated its final file"
  assert_eq "preserve-unit" "$(cat "$temp_dir/preserved.service")" \
    "failed unit render mutated its final file"
  [[ -z "$(find "$temp_dir" -maxdepth 1 -type f \
    \( -name '.hysteria-config.*' -o -name '.hysteria-acl.*' -o -name '.hysteria-unit.*' \) \
    -print -quit)" ]] || fail "failed Hysteria2 renderer leaked private temporary files"

  expected_acl=$'# Managed by v2ray-onekey: Hysteria2 ACL v1\nreject(0.0.0.0/8)\nreject(10.0.0.0/8)\nreject(100.64.0.0/10)\nreject(127.0.0.0/8)\nreject(169.254.0.0/16)\nreject(172.16.0.0/12)\nreject(192.168.0.0/16)\nreject(224.0.0.0/4)\nreject(::1/128)\nreject(fc00::/7)\nreject(fe80::/10)\nreject(all, tcp/25)\nreject(all, tcp/465)\nreject(all, tcp/587)\ndirect(all)'
  expected_acl_mail=$'# Managed by v2ray-onekey: Hysteria2 ACL v1\nreject(0.0.0.0/8)\nreject(10.0.0.0/8)\nreject(100.64.0.0/10)\nreject(127.0.0.0/8)\nreject(169.254.0.0/16)\nreject(172.16.0.0/12)\nreject(192.168.0.0/16)\nreject(224.0.0.0/4)\nreject(::1/128)\nreject(fc00::/7)\nreject(fe80::/10)\ndirect(all)'
  ALLOW_MAIL="0"
  render_hysteria_acl "$temp_dir/acl.txt"
  assert_eq "$expected_acl" "$(cat "$temp_dir/acl.txt")" "Hysteria2 ACL order"
  grep -Eiq 'torrent|bittorrent' "$temp_dir/acl.txt" && fail "invented Hysteria2 BitTorrent matcher"
  ALLOW_MAIL="1"
  render_hysteria_acl "$temp_dir/acl-mail.txt"
  assert_eq "$expected_acl_mail" "$(cat "$temp_dir/acl-mail.txt")" \
    "Hysteria2 allow-mail ACL"

  expected_unit=$'# Managed by v2ray-onekey: Hysteria2 unit v1\n[Unit]\nDescription=Hysteria2 Server\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nUser=hysteria\nGroup=hysteria\nExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml\nRestart=on-failure\nRestartSec=5s\nAmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE\nNoNewPrivileges=true\nLimitNOFILE=1048576\n\n[Install]\nWantedBy=multi-user.target'
  render_hysteria_unit "$temp_dir/hysteria-server.service"
  assert_eq "$expected_unit" "$(cat "$temp_dir/hysteria-server.service")" \
    "Ubuntu 18 compatible Hysteria2 unit"
  assert_eq "644" "$(stat -c '%a' "$temp_dir/hysteria-server.service")" \
    "Hysteria2 unit mode"

  cat >"$temp_dir/bin/install" <<'EOF'
#!/usr/bin/env bash
printf '<%s>\n' "$*" >>"$HY2_INSTALL_LOG"
EOF
  chmod +x "$temp_dir/bin/install"
  : >"$temp_dir/install.log"
  export HY2_INSTALL_LOG="$temp_dir/install.log"
  HYSTERIA_BIN="/usr/local/bin/hysteria"
  HYSTERIA_CONFIG="/etc/hysteria/config.yaml"
  HYSTERIA_ACL="/etc/hysteria/acl.txt"
  HYSTERIA_CERT="/etc/hysteria/server.crt"
  HYSTERIA_KEY="/etc/hysteria/server.key"
  HYSTERIA_UNIT="/etc/systemd/system/hysteria-server.service"
  PATH="$temp_dir/bin:$PATH"
  install_validated_hysteria_binary "$temp_dir/runtime/hysteria"
  grep -Fqx "<-o root -g root -m 0755 $temp_dir/runtime/hysteria /usr/local/bin/hysteria>" \
    "$temp_dir/install.log" || fail "validated Hysteria2 binary install mode/owner is wrong"
  : >"$temp_dir/install.log"
  ln -s "$temp_dir/server.key" "$temp_dir/symlink-key"
  assert_fails "Invalid Hysteria2 staging file" install_hysteria_runtime_files \
    "$temp_dir/install.yaml" "$temp_dir/acl.txt" "$temp_dir/server.crt" \
    "$temp_dir/symlink-key" "$temp_dir/hysteria-server.service"
  [[ ! -s "$temp_dir/install.log" ]] ||
    fail "failing Hysteria2 install helper attempted to mutate final files"
  install_hysteria_runtime_files "$temp_dir/install.yaml" "$temp_dir/acl.txt" \
    "$temp_dir/server.crt" "$temp_dir/server.key" "$temp_dir/hysteria-server.service"
  PATH="$old_path"
  unset HY2_INSTALL_LOG
  grep -Fqx "<-o root -g hysteria -m 0440 $temp_dir/install.yaml /etc/hysteria/config.yaml>" \
    "$temp_dir/install.log" || fail "Hysteria2 config final ownership/mode is wrong"
  grep -Fqx "<-o root -g hysteria -m 0440 $temp_dir/server.key /etc/hysteria/server.key>" \
    "$temp_dir/install.log" || fail "Hysteria2 key final ownership/mode is wrong"
  grep -Fqx "<-o root -g hysteria -m 0440 $temp_dir/server.crt /etc/hysteria/server.crt>" \
    "$temp_dir/install.log" || fail "Hysteria2 certificate final ownership/mode is wrong"
  grep -Fqx "<-o root -g root -m 0644 $temp_dir/hysteria-server.service /etc/systemd/system/hysteria-server.service>" \
    "$temp_dir/install.log" || fail "Hysteria2 unit final ownership/mode is wrong"

  install -d "$temp_dir/timeout-bin"
  cat >"$temp_dir/timeout-bin/timeout" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TIMEOUT_LOG"
case "$TIMEOUT_BEHAVIOR" in
  ready124) printf 'server up and running\n'; exit 124 ;;
  ready143) printf 'server up and running\n'; exit 143 ;;
  no-marker) printf 'starting\n'; exit 124 ;;
  *) printf 'configuration rejected\n'; exit 1 ;;
esac
EOF
  chmod +x "$temp_dir/timeout-bin/timeout"
  : >"$temp_dir/timeout.log"
  export TIMEOUT_LOG="$temp_dir/timeout.log"
  PATH="$temp_dir/timeout-bin:$PATH"
  TIMEOUT_BEHAVIOR="ready124" validate_hysteria_staged \
    "$temp_dir/runtime/hysteria" "$temp_dir/staged.yaml" "$temp_dir/smoke.log"
  TIMEOUT_BEHAVIOR="ready143" validate_hysteria_staged \
    "$temp_dir/runtime/hysteria" "$temp_dir/staged.yaml" "$temp_dir/smoke.log"
  assert_fails "Hysteria2 staged validation did not become ready" \
    env TIMEOUT_BEHAVIOR="no-marker" bash -c \
      'export V2RAY_ONEKEY_SOURCE_ONLY=1; source "$1"; PATH="$2:$PATH"; validate_hysteria_staged "$3" "$4" "$5"' \
      bash "$SCRIPT" "$temp_dir/timeout-bin" "$temp_dir/runtime/hysteria" \
      "$temp_dir/staged.yaml" "$temp_dir/smoke-fail.log"
  grep -Fq -- '--signal=TERM --kill-after=2s 4s' "$temp_dir/timeout.log" ||
    fail "Hysteria2 smoke timeout is not fully bounded"
  assert_eq "600" "$(stat -c '%a' "$temp_dir/smoke.log")" "Hysteria2 smoke log mode"
  PATH="$old_path"
  unset TIMEOUT_LOG

  HY2_CERT_PIN="$HY2_TEST_PIN"
  real_python="$(command -v python3)"
  install -d "$temp_dir/python-bin"
  cat >"$temp_dir/python-bin/python3" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >>"$PYTHON_ARGV_LOG"
for name in HY2_AUTH HY2_OBFS_PASSWORD HY2_SNI HY2_CERT_PIN; do
  [[ -z ${!name+x} ]] || printf '%s\n' "$name" >>"$PYTHON_ENV_LOG"
done
exec "$REAL_PYTHON" "$@"
EOF
  chmod +x "$temp_dir/python-bin/python3"
  : >"$temp_dir/python-argv.log"
  : >"$temp_dir/python-env.log"
  export REAL_PYTHON="$real_python"
  export PYTHON_ARGV_LOG="$temp_dir/python-argv.log"
  export PYTHON_ENV_LOG="$temp_dir/python-env.log"
  export HY2_AUTH HY2_OBFS_PASSWORD HY2_SNI HY2_CERT_PIN
  PATH="$temp_dir/python-bin:$PATH"
  SERVER_ADDRESS="192.0.2.10"
  ipv4_link="$(make_hysteria_link)"
  SERVER_ADDRESS="2001:db8::10"
  ipv6_link="$(make_hysteria_link)"
  SERVER_ADDRESS="vpn.example.net"
  hostname_link="$(make_hysteria_link)"
  SERVER_ADDRESS="VPN.Example.NET"
  uppercase_link="$(make_hysteria_link)"
  PATH="$old_path"
  unset REAL_PYTHON PYTHON_ARGV_LOG PYTHON_ENV_LOG
  [[ ! -s "$temp_dir/python-env.log" ]] ||
    fail "Hysteria URI validator inherited sensitive values: $(paste -sd, "$temp_dir/python-env.log")"
  for secret in "$HY2_TEST_AUTH" "$HY2_TEST_OBFS" "$HY2_TEST_SNI" "$HY2_TEST_PIN"; do
    grep -aFq "$secret" "$temp_dir/python-argv.log" &&
      fail "Hysteria URI value was exposed in Python argv"
  done
  printf '%s\0%s\0%s\0%s\0' "$ipv4_link" "$ipv6_link" "$hostname_link" "$uppercase_link" |
    python3 - "$HY2_TEST_AUTH" "$HY2_TEST_OBFS" "$HY2_TEST_SNI" \
      "$HY2_TEST_PIN" 3<&0 <<'PY'
import os
import sys
import urllib.parse


links = os.fdopen(3, "rb").read().decode("utf-8").split("\0")[:-1]
expected_hosts = ["192.0.2.10", "2001:db8::10", "vpn.example.net", "vpn.example.net"]
for link, host in zip(links, expected_hosts):
    parsed = urllib.parse.urlsplit(link)
    assert parsed.scheme == "hysteria2"
    assert urllib.parse.unquote(parsed.username) == sys.argv[1]
    assert parsed.hostname == host
    assert parsed.netloc.endswith(":20000-20100")
    query = urllib.parse.parse_qs(parsed.query, strict_parsing=True)
    assert query == {
        "obfs": ["salamander"],
        "obfs-password": [sys.argv[2]],
        "sni": [sys.argv[3]],
        "insecure": ["1"],
        "pinSHA256": [sys.argv[4]],
    }
    assert urllib.parse.unquote(parsed.fragment) == "Hysteria2-direct"
assert "@[2001:db8::10]:20000-20100" in links[1]
PY
  SERVER_ADDRESS="bad address"
  assert_fails "Invalid Hysteria2 link values" make_hysteria_link
  SERVER_ADDRESS="vpn.example.net"
  HY2_AUTH="short"
  assert_fails "Invalid Hysteria2 link values" make_hysteria_link

  for secret in "$HY2_TEST_AUTH" "$HY2_TEST_OBFS"; do
    [[ "$ipv4_link" == *"$secret"* ]] || fail "share link omitted required Hysteria2 credential"
  done
)

test_hysteria_validation_and_rendering

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
  HY2_AUTH="$HY2_TEST_AUTH"
  HY2_OBFS_PASSWORD="$HY2_TEST_OBFS"
  HY2_SNI="$HY2_TEST_SNI"
  HY2_CERT_PIN="$HY2_TEST_PIN"
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
  assert_eq "$HY2_TEST_AUTH" "$HY2_AUTH" "loaded Hysteria2 auth after export cleanup"
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
  HY2_AUTH="$HY2_TEST_AUTH"
  HY2_OBFS_PASSWORD="$HY2_TEST_OBFS"
  HY2_SNI="$HY2_TEST_SNI"
  HY2_CERT_PIN="$HY2_TEST_PIN"
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
  assert_eq "$HY2_TEST_AUTH" "$HY2_AUTH" "loaded Hysteria2 auth"
  assert_eq "$HY2_TEST_OBFS" "$HY2_OBFS_PASSWORD" "loaded Hysteria2 obfuscation password"
  assert_eq "$HY2_TEST_SNI" "$HY2_SNI" "loaded Hysteria2 SNI"
  assert_eq "$HY2_TEST_PIN" "$HY2_CERT_PIN" "loaded Hysteria2 certificate pin"
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
    "$HY2_TEST_AUTH" \
    "$HY2_TEST_OBFS" \
    "$HY2_TEST_SNI" \
    "$HY2_TEST_PIN" \
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
  cp "$STATE_FILE" "$temp_dir/prepare-state.env"
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
  reset_options
  assert_fails "Invalid Hysteria2 certificate pin in state" load_state

  STATE_FILE="$temp_dir/prepare-state.env"
  chmod 0600 "$STATE_FILE"
  HYSTERIA_CERT="$temp_dir/must-not-exist.crt"
  HYSTERIA_KEY="$temp_dir/must-not-exist.key"
  reset_options
  parse_args
  prepare_configuration
  assert_eq "full" "$MODE" "legacy dual prepare mode"
  assert_eq "vpn.example.com" "$DOMAIN" "legacy dual prepare Cloudflare domain"
  valid_hy2_secret "$HY2_AUTH" || fail "legacy dual prepare did not bootstrap Hysteria2 auth"
  valid_hy2_secret "$HY2_OBFS_PASSWORD" || fail "legacy dual prepare did not bootstrap Hysteria2 obfs"
  valid_hy2_sni "$HY2_SNI" || fail "legacy dual prepare did not bootstrap Hysteria2 SNI"
  assert_eq "" "$HY2_CERT_PIN" "legacy bootstrap pin remains deferred"
  [[ ! -e "$HYSTERIA_CERT" && ! -e "$HYSTERIA_KEY" ]] ||
    fail "legacy state read generated Hysteria2 certificate files"
  require_mode_ready

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
[[ "$1 $2 $3" == 'rand -hex 8' ]] && { printf '0123456789abcdef\n'; exit; }
[[ "$1 $2 $3" == 'rand -base64 16' ]] && { printf 'YWJjZGVmZ2hpamtsbW5vcA==\n'; exit; }
if [[ "$1 $2 $3" == 'rand -base64 32' ]]; then
  count="$(cat "$OPENSSL_32_COUNT_FILE" 2>/dev/null || printf '0')"
  count=$((count + 1))
  printf '%s\n' "$count" >"$OPENSSL_32_COUNT_FILE"
  if [[ "$count" -eq 1 ]]; then
    printf 'MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=\n'
  else
    printf 'ZmVkY2JhOTg3NjU0MzIxMGZlZGNiYTk4NzY1NDMyMTA=\n'
  fi
  exit
fi
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
  export OPENSSL_32_COUNT_FILE="$temp_dir/openssl-32-count"

  reset_options
  MODE="direct"
  generate_runtime_values
  assert_eq "" "$CLOUDFLARE_UUID" "direct mode does not generate Cloudflare UUID"
  assert_eq "" "$INTERNAL_WS_PORT" "direct mode does not generate internal port"
  assert_eq "" "$WS_PATH" "direct mode does not generate WS path"
  assert_eq "2022-blake3-aes-128-gcm" "$SS_METHOD" "generated Shadowsocks method"
  assert_eq "YWJjZGVmZ2hpamtsbW5vcA==" "$SS_KEY" "generated Shadowsocks key"
  assert_eq "$HY2_TEST_AUTH" "$HY2_AUTH" "generated Hysteria2 auth"
  assert_eq "$HY2_TEST_OBFS" "$HY2_OBFS_PASSWORD" "generated Hysteria2 obfs password"
  [[ "$HY2_AUTH" != "$HY2_OBFS_PASSWORD" ]] ||
    fail "Hysteria2 auth and obfuscation passwords were not generated separately"
  assert_eq "$HY2_TEST_SNI" "$HY2_SNI" "generated Hysteria2 SNI"
  assert_eq "" "$HY2_CERT_PIN" "runtime generation does not create a certificate pin"

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
  HY2_AUTH="$HY2_TEST_AUTH"
  HY2_OBFS_PASSWORD="$HY2_TEST_OBFS"
  HY2_SNI="$HY2_TEST_SNI"
  SS_KEY="$SS_TEST_KEY"
  generate_runtime_values
  assert_eq "existing-cloudflare" "$CLOUDFLARE_UUID" "existing Cloudflare UUID reused"
  assert_eq "32001" "$INTERNAL_WS_PORT" "existing internal port reused"
  assert_eq "/existing" "$WS_PATH" "existing path reused"
  assert_eq "$HY2_TEST_AUTH" "$HY2_AUTH" "existing Hysteria2 auth reused"
  assert_eq "$HY2_TEST_OBFS" "$HY2_OBFS_PASSWORD" "existing Hysteria2 obfs reused"
  assert_eq "$HY2_TEST_SNI" "$HY2_SNI" "existing Hysteria2 SNI reused"
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
  valid_hy2_secret "$HY2_AUTH" || fail "rotate did not regenerate Hysteria2 auth"
  valid_hy2_secret "$HY2_OBFS_PASSWORD" || fail "rotate did not regenerate Hysteria2 obfs"
  valid_hy2_sni "$HY2_SNI" || fail "rotate did not regenerate Hysteria2 SNI"
  unset OPENSSL_32_COUNT_FILE
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

test_task6_direct_bundle_gate_is_open() (
  reset_options
  MODE="direct"
  require_mode_ready
  MODE="full"
  require_mode_ready
  MODE="cloudflare"
  require_mode_ready
)

test_task6_direct_bundle_gate_is_open
printf 'PASS: Task 6 direct bundle gate tests\n'

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
  BACKUP_DIR="$temp_dir/nginx-backup"
  init_backup_metadata
  printf 'nginx\tactive\tenabled\n' >"$BACKUP_DIR/services"
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
  printf '%s\n' v2ray xray nginx >"$BACKUP_DIR/services-touched"
  chmod 0600 "$BACKUP_DIR/services-touched"
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
  printf 'nginx\tactive\tenabled\n' >"$BACKUP_DIR/services"
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
  HY2_AUTH="$HY2_TEST_AUTH"
  HY2_OBFS_PASSWORD="$HY2_TEST_OBFS"
  HY2_SNI="$HY2_TEST_SNI"
  HY2_CERT_PIN="$HY2_TEST_PIN"
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
  HY2_AUTH="$HY2_TEST_AUTH"
  HY2_OBFS_PASSWORD="$HY2_TEST_OBFS"
  HY2_SNI="$HY2_TEST_SNI"
  HY2_CERT_PIN="$HY2_TEST_PIN"
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
  resolve_direct_port_conflicts() { :; }
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

test_task5_direct_port_conflicts() (
  local temp_dir ss_log output
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  ss_log="$temp_dir/ss.log"

  reset_options
  MODE="direct"
  HY2_PORT_RANGE="20000-20100"
  SS_PORT="8388"
  parse_port_range "$HY2_PORT_RANGE"
  assert_eq "20000" "$HY2_PORT_START" "Hysteria2 range start"
  assert_eq "20100" "$HY2_PORT_END" "Hysteria2 range end"
  parse_port_range "1-1001"
  assert_fails "" parse_port_range "1-1002"
  assert_fails "" parse_port_range "20000"
  assert_fails "" parse_port_range "20100-20000"

  ss() {
    printf '%s\n' "$*" >>"$ss_log"
    if [[ "$*" == *'-H -lnup'* && "$*" == *':20005'* ]]; then
      printf 'UNCONN 0 0 0.0.0.0:20005 0.0.0.0:* users:(("other",pid=9,fd=3))\n'
    elif [[ "$*" == *'-H -lntup'* && "$*" == *':8388'* ]]; then
      printf 'LISTEN 0 128 0.0.0.0:8388 0.0.0.0:* users:(("other",pid=10,fd=4))\n'
    fi
  }
  stdin_is_tty() { return 1; }
  output="$(resolve_direct_port_conflicts 2>&1)" &&
    fail "non-interactive direct conflicts unexpectedly passed"
  [[ "$output" == *'--hy2-port-range START-END'* && "$output" == *'20005'* ]] ||
    fail "Hysteria2 conflict diagnostics are incomplete: $output"
  [[ "$output" == *'--ss-port PORT'* && "$output" == *'8388'* ]] ||
    fail "Shadowsocks conflict diagnostics are incomplete: $output"
  grep -Fq -- '-H -lnup sport = :20005' "$ss_log" ||
    fail "Hysteria2 did not inspect UDP 20005"
  grep -Fq -- '-H -lntup sport = :8388' "$ss_log" ||
    fail "Shadowsocks did not inspect TCP and UDP together"

  : >"$ss_log"
  HY2_PORT_RANGE="443-443"
  ss() {
    printf '%s\n' "$*" >>"$ss_log"
    if [[ "$*" == *'-H -lntp'* && "$*" == *':443'* ]]; then
      printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=11,fd=5))\n'
    fi
  }
  hysteria_range_conflicts && fail "TCP 443 was misclassified as a UDP 443 conflict"
  grep -Fq -- '-H -lnup sport = :443' "$ss_log" ||
    fail "Hysteria2 did not use UDP-only listener inspection"

)

test_task5_direct_port_conflicts

test_task5_interactive_direct_port_replacement() (
  MODE="direct"
  HY2_PORT_RANGE="20000-20100"
  SS_PORT="8388"
  stdin_is_tty() { return 0; }
  hysteria_range_conflicts() {
    HY2_PORT_START="${HY2_PORT_RANGE%-*}"
    HY2_PORT_END="${HY2_PORT_RANGE#*-}"
    HY2_CONFLICT_DETAILS="UDP 20005 occupied"
    [[ "$HY2_PORT_RANGE" == "20000-20100" ]]
  }
  shadowsocks_port_conflicts() {
    SS_CONFLICT_DETAILS="TCP 8388 occupied"
    [[ "$SS_PORT" == "8388" ]]
  }
  resolve_direct_port_conflicts <<'EOF'
21000-21100
8488
EOF
  assert_eq "21000-21100" "$HY2_PORT_RANGE" "interactive Hysteria2 replacement"
  assert_eq "8488" "$SS_PORT" "interactive Shadowsocks replacement"
)

test_task5_interactive_direct_port_replacement

test_task5_fifth_interactive_replacement_succeeds() (
  local hy2_checks=0 ss_checks=0
  MODE="direct"
  stdin_is_tty() { return 0; }

  HY2_PORT_RANGE="20000-20100"
  hysteria_range_conflicts() {
    hy2_checks=$((hy2_checks + 1))
    HY2_CONFLICT_DETAILS="occupied attempt $hy2_checks"
    ((hy2_checks <= 5))
  }
  resolve_hysteria_port_range <<'EOF'
21000-21000
21001-21001
21002-21002
21003-21003
21004-21004
EOF
  assert_eq "21004-21004" "$HY2_PORT_RANGE" "fifth Hysteria2 replacement"
  assert_eq "6" "$hy2_checks" "Hysteria2 replacement availability checks"

  SS_PORT="8388"
  shadowsocks_port_conflicts() {
    ss_checks=$((ss_checks + 1))
    SS_CONFLICT_DETAILS="occupied attempt $ss_checks"
    ((ss_checks <= 5))
  }
  resolve_shadowsocks_port <<'EOF'
8481
8482
8483
8484
8485
EOF
  assert_eq "8485" "$SS_PORT" "fifth Shadowsocks replacement"
  assert_eq "6" "$ss_checks" "Shadowsocks replacement availability checks"
)

test_task5_fifth_interactive_replacement_succeeds

test_task5_strict_project_listener_ownership() (
  local temp_dir path listener_mode="owned" runtime_mode="valid" xray_runtime_mode="valid" stop_log
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  HYSTERIA_BIN="$temp_dir/usr/local/bin/hysteria"
  HYSTERIA_CONFIG="$temp_dir/etc/hysteria/config.yaml"
  HYSTERIA_ACL="$temp_dir/etc/hysteria/acl.txt"
  HYSTERIA_CERT="$temp_dir/etc/hysteria/server.crt"
  HYSTERIA_KEY="$temp_dir/etc/hysteria/server.key"
  HYSTERIA_UNIT="$temp_dir/etc/systemd/system/hysteria-server.service"
  HYSTERIA_OWNERSHIP_MANIFEST="$temp_dir/etc/v2ray-onekey/hysteria.manifest"
  XRAY_BIN="$temp_dir/usr/local/bin/xray"
  XRAY_CONFIG="$temp_dir/usr/local/etc/xray/config.json"
  STATE_FILE="$temp_dir/etc/v2ray-onekey/state.env"
  SERVICE_PROC_ROOT="$temp_dir/proc"
  LOGIN_DEFS_FILE="$temp_dir/login.defs"
  stop_log="$temp_dir/stops.log"
  printf 'SYS_UID_MAX 999\nSYS_GID_MAX 999\n' >"$LOGIN_DEFS_FILE"
  getent() {
    case "$1 $2" in
      'passwd hysteria') printf 'hysteria:x:500:500::/nonexistent:/usr/sbin/nologin\n' ;;
      'group hysteria') printf 'hysteria:x:500:\n' ;;
      *) return 2 ;;
    esac
  }
  id() {
    case "$*" in
      '-u hysteria') printf '500\n' ;;
      '-g hysteria') printf '500\n' ;;
      '-gn hysteria') printf 'hysteria\n' ;;
      '-G hysteria') printf '500\n' ;;
      *) command id "$@" ;;
    esac
  }

  for path in "$HYSTERIA_BIN" "$HYSTERIA_CONFIG" "$HYSTERIA_ACL" "$HYSTERIA_CERT" \
    "$HYSTERIA_KEY" "$HYSTERIA_UNIT" "$XRAY_BIN"; do
    install -d "$(dirname "$path")"
    case "$path" in
      "$HYSTERIA_CONFIG") printf '%s\n' "$HYSTERIA_CONFIG_MARKER" >"$path" ;;
      "$HYSTERIA_ACL") printf '%s\n' "$HYSTERIA_ACL_MARKER" >"$path" ;;
      "$HYSTERIA_UNIT") printf '%s\n' "$HYSTERIA_UNIT_MARKER" >"$path" ;;
      *) printf 'project binary or credential\n' >"$path" ;;
    esac
  done
  write_hysteria_ownership_manifest

  reset_options
  MODE="direct"
  HY2_PORT_RANGE="20000-20000"
  HY2_AUTH="$HY2_TEST_AUTH"
  HY2_OBFS_PASSWORD="$HY2_TEST_OBFS"
  HY2_SNI="$HY2_TEST_SNI"
  HY2_CERT_PIN="$HY2_TEST_PIN"
  SS_PORT="8388"
  SS_METHOD="2022-blake3-aes-128-gcm"
  SS_KEY="$SS_TEST_KEY"
  SERVER_ADDRESS="192.0.2.10"
  ALLOW_BITTORRENT="0"
  ALLOW_MAIL="0"
  save_state
  render_xray_config "$XRAY_CONFIG"

  install -d "$SERVICE_PROC_ROOT/4242" "$SERVICE_PROC_ROOT/5151"
  ln -s "$HYSTERIA_BIN" "$SERVICE_PROC_ROOT/4242/exe"
  printf '%s\0%s\0%s\0%s\0' "$HYSTERIA_BIN" server -c "$HYSTERIA_CONFIG" \
    >"$SERVICE_PROC_ROOT/4242/cmdline"
  cat >"$SERVICE_PROC_ROOT/4242/status" <<'EOF'
Name:	hysteria
Uid:	500	500	500	500
Gid:	500	500	500	500
Groups:	500
CapEff:	0000000000001400
CapBnd:	0000000000001400
CapAmb:	0000000000001400
NoNewPrivs:	1
EOF
  ln -s "$XRAY_BIN" "$SERVICE_PROC_ROOT/5151/exe"
  printf '%s\0%s\0%s\0%s\0' "$XRAY_BIN" run -config "$XRAY_CONFIG" \
    >"$SERVICE_PROC_ROOT/5151/cmdline"

  systemctl() {
    case "$*" in
      'show -p FragmentPath --value hysteria-server') printf '%s\n' "$HYSTERIA_UNIT" ;;
      'show -p DropInPaths --value hysteria-server') printf '\n' ;;
      'show -p User --value hysteria-server')
        [[ "$runtime_mode" == "root" ]] && printf 'root\n' || printf 'hysteria\n'
        ;;
      'show -p Group --value hysteria-server')
        [[ "$runtime_mode" == "root" ]] && printf 'root\n' || printf 'hysteria\n'
        ;;
      'show -p MainPID --value hysteria-server') printf '4242\n' ;;
      'show -p MainPID --value xray') printf '5151\n' ;;
      'show -p User --value xray')
        printf 'xray\n'
        ;;
      'show -p Group --value xray')
        printf 'xray\n'
        ;;
      'stop hysteria-server') printf 'stop\n' >>"$stop_log" ;;
      *) return 1 ;;
    esac
  }
  stat() {
    local path="${*: -1}"
    if [[ "$*" == *"%U:%G"* && "$path" == "$SERVICE_PROC_ROOT/4242" ]]; then
      [[ "$runtime_mode" == "root" ]] && printf 'root:root\n' || printf 'hysteria:hysteria\n'
    elif [[ "$*" == *"%U:%G"* && "$path" == "$SERVICE_PROC_ROOT/5151" ]]; then
      [[ "$xray_runtime_mode" == "mismatch" ]] && printf 'root:root\n' || printf 'xray:xray\n'
    else
      command stat "$@"
    fi
  }
  ss() {
    case "$*:$listener_mode" in
      *'-H -lnup'*':20000:owned')
        printf 'UNCONN 0 0 0.0.0.0:20000 0.0.0.0:* users:(("hysteria",pid=4242,fd=7))\n'
        ;;
      *'-H -lntup'*':8388:owned')
        printf 'LISTEN 0 128 0.0.0.0:8388 0.0.0.0:* users:(("xray",pid=5151,fd=8))\n'
        ;;
      *'-H -lnup'*':20000:third-party')
        printf 'UNCONN 0 0 0.0.0.0:20000 0.0.0.0:* users:(("hysteria",pid=9999,fd=7))\n'
        ;;
      *'-H -lntup'*':8388:third-party')
        printf 'LISTEN 0 128 0.0.0.0:8388 0.0.0.0:* users:(("xray",pid=9998,fd=8))\n'
        ;;
    esac
  }

  hysteria_range_conflicts && fail "strictly owned Hysteria2 listener blocked a rerun"
  shadowsocks_port_conflicts && fail "strictly owned Xray listener blocked a rerun"

  MODE="full"
  ROTATE="1"
  DOMAIN="new.example.com"
  EMAIL="new@example.com"
  CLOUDFLARE_PORT="8443"
  INTERNAL_WS_PORT="32001"
  CLOUDFLARE_UUID="22222222-2222-4222-8222-222222222222"
  WS_PATH="/new-path"
  SS_KEY="QUJDREVGR0hJSktMTU5PUA=="
  shadowsocks_port_conflicts && fail "owned old Xray listener blocked rotate or mode change"
  assert_eq "full" "$MODE" "Xray disk ownership check polluted desired mode"
  assert_eq "QUJDREVGR0hJSktMTU5PUA==" "$SS_KEY" "Xray disk ownership check polluted desired key"

  xray_runtime_mode="mismatch"
  shadowsocks_port_conflicts || fail "Xray process with mismatched runtime identity was treated as project-owned"
  xray_runtime_mode="valid"

  listener_mode="third-party"
  hysteria_range_conflicts || fail "same-name third-party Hysteria2 listener was ignored"
  shadowsocks_port_conflicts || fail "same-name third-party Xray listener was ignored"
  [[ "$HY2_CONFLICT_DETAILS" == *'pid=9999'* ]] || fail "third-party Hysteria2 diagnostics were lost"
  [[ "$SS_CONFLICT_DETAILS" == *'pid=9998'* ]] || fail "third-party Xray diagnostics were lost"

  listener_mode="owned"
  BACKUP_DIR="$temp_dir/backup"
  init_backup_metadata
  printf 'hysteria-server\tactive\tenabled\n' >"$BACKUP_DIR/services"

  runtime_mode="root"
  hysteria_range_conflicts || fail "root Hysteria2 process was treated as project-owned"
  assert_fails "Refusing to stop" stop_project_hysteria_for_cutover
  [[ ! -e "$stop_log" ]] || fail "root Hysteria2 process was stopped"

  runtime_mode="valid"
  sed -i 's/CapEff:\t0000000000001400/CapEff:\t0000000000001c00/' \
    "$SERVICE_PROC_ROOT/4242/status"
  hysteria_range_conflicts || fail "extra Hysteria2 capability was treated as project-owned"
  assert_fails "Refusing to stop" stop_project_hysteria_for_cutover
  [[ ! -e "$stop_log" ]] || fail "Hysteria2 process with an extra capability was stopped"
  sed -i 's/CapEff:\t0000000000001c00/CapEff:\t0000000000001400/' \
    "$SERVICE_PROC_ROOT/4242/status"

  sed -i 's/NoNewPrivs:\t1/NoNewPrivs:\t0/' "$SERVICE_PROC_ROOT/4242/status"
  hysteria_range_conflicts || fail "Hysteria2 without NoNewPrivileges was treated as project-owned"
  assert_fails "Refusing to stop" stop_project_hysteria_for_cutover
  [[ ! -e "$stop_log" ]] || fail "Hysteria2 process without NoNewPrivileges was stopped"
  sed -i 's/NoNewPrivs:\t0/NoNewPrivs:\t1/' "$SERVICE_PROC_ROOT/4242/status"

  hysteria_range_conflicts && fail "fully valid old Hysteria2 process blocked a rerun"
  stop_project_hysteria_for_cutover
  grep -Fqx 'stop' "$stop_log" || fail "fully valid old Hysteria2 process was not stopped for cutover"

  rm -f "$HYSTERIA_OWNERSHIP_MANIFEST"
  hysteria_range_conflicts || fail "unproved Hysteria2 ownership was ignored"
  rm -f "$STATE_FILE"
  shadowsocks_port_conflicts || fail "unproved Xray ownership was ignored"
)

test_task5_strict_project_listener_ownership
printf 'PASS: Task 5 direct port conflict tests\n'

test_task5_untouched_identity_conflict_rollback() (
  local temp_dir service_log status
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  service_log="$temp_dir/systemctl.log"
  : >"$service_log"
  BACKUP_ROOT="$temp_dir/backups"
  XRAY_CONFIG="$temp_dir/xray/config.json"
  STATE_FILE="$temp_dir/state/state.env"
  NGINX_SITE="$temp_dir/nginx/site.conf"
  RENEWAL_HOOK="$temp_dir/hooks/hook.sh"
  LEGACY_V2RAY_CONFIG="$temp_dir/v2ray/config.json"
  HYSTERIA_BIN="$temp_dir/usr/local/bin/hysteria"
  HYSTERIA_CONFIG="$temp_dir/etc/hysteria/config.yaml"
  HYSTERIA_ACL="$temp_dir/etc/hysteria/acl.txt"
  HYSTERIA_CERT="$temp_dir/etc/hysteria/server.crt"
  HYSTERIA_KEY="$temp_dir/etc/hysteria/server.key"
  HYSTERIA_UNIT="$temp_dir/etc/systemd/system/hysteria-server.service"
  HYSTERIA_OWNERSHIP_MANIFEST="$temp_dir/etc/v2ray-onekey/hysteria.manifest"
  RUNTIME_DIR=""
  MODE="direct"
  HY2_PORT_RANGE="20000-20000"
  SS_PORT="8388"
  SS_METHOD="2022-blake3-aes-128-gcm"

  direct_bundle_ready() { return 0; }
  validate_managed_destination_ownership() { :; }
  install_required_packages() { :; }
  install_xray_core() { :; }
  generate_runtime_values() { :; }
  validate_loaded_runtime_values() { :; }
  check_internal_ws_port_listener() { :; }
  project_hysteria_listener_pid() { return 1; }
  stdin_is_tty() { return 1; }
  ss() {
    if [[ "$*" == *'-H -lnup'* && "$*" == *':20000'* ]]; then
      printf 'UNCONN 0 0 0.0.0.0:20000 0.0.0.0:* users:(("hysteria",pid=4242,fd=7))\n'
    fi
  }
  systemctl() {
    printf '%s\n' "$*" >>"$service_log"
    case "$*" in
      'show -p LoadState --value '*) printf 'loaded\n' ;;
      'show -p ActiveState --value hysteria-server') printf 'active\n' ;;
      'show -p ActiveState --value '*) printf 'inactive\n' ;;
      'show -p UnitFileState --value hysteria-server') printf 'enabled\n' ;;
      'show -p UnitFileState --value '*) printf 'disabled\n' ;;
      'is-active --quiet hysteria-server'|'is-enabled --quiet hysteria-server') return 0 ;;
      'is-active --quiet '*|'is-enabled --quiet '*) return 1 ;;
      *) return 0 ;;
    esac
  }

  set +e
  (
    set -Eeuo pipefail
    activate_transaction_traps
    deploy_services
  ) >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "identity-conflict deployment unexpectedly succeeded"
  if awk '$1 ~ /^(stop|start|restart|enable|disable)$/ {
      for (field = 2; field <= NF; field += 1) if ($field == "hysteria-server") found = 1
    } END { exit !found }' "$service_log"; then
    fail "untouched identity-conflict rollback mutated Hysteria2: $(tr '\n' ',' <"$service_log")"
  fi
  return 0
)

test_task5_untouched_identity_conflict_rollback

test_task5_staged_hysteria_failure_restores_service() (
  local temp_dir service_log stage_log status
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  service_log="$temp_dir/systemctl.log"
  stage_log="$temp_dir/stage.log"
  : >"$service_log"
  BACKUP_ROOT="$temp_dir/backups"
  XRAY_CONFIG="$temp_dir/xray/config.json"
  STATE_FILE="$temp_dir/state/state.env"
  NGINX_SITE="$temp_dir/nginx/site.conf"
  RENEWAL_HOOK="$temp_dir/hooks/hook.sh"
  LEGACY_V2RAY_CONFIG="$temp_dir/v2ray/config.json"
  HYSTERIA_BIN="$temp_dir/usr/local/bin/hysteria"
  HYSTERIA_CONFIG="$temp_dir/etc/hysteria/config.yaml"
  HYSTERIA_ACL="$temp_dir/etc/hysteria/acl.txt"
  HYSTERIA_CERT="$temp_dir/etc/hysteria/server.crt"
  HYSTERIA_KEY="$temp_dir/etc/hysteria/server.key"
  HYSTERIA_UNIT="$temp_dir/etc/systemd/system/hysteria-server.service"
  HYSTERIA_OWNERSHIP_MANIFEST="$temp_dir/etc/v2ray-onekey/hysteria.manifest"
  RUNTIME_DIR=""
  MODE="direct"
  HY2_PORT_RANGE="20000-20000"
  SS_PORT="8388"
  SS_METHOD="2022-blake3-aes-128-gcm"

  direct_bundle_ready() { return 0; }
  validate_managed_destination_ownership() { :; }
  install_required_packages() { :; }
  install_xray_core() { :; }
  generate_runtime_values() { :; }
  validate_loaded_runtime_values() { :; }
  check_internal_ws_port_listener() { :; }
  render_xray_config() { printf '{}\n' >"$1"; }
  xray() { :; }
  project_hysteria_listener_pid() { printf '4242\n'; }
  stage_hysteria_bundle() {
    grep -Eq '^(stop|restart|disable) hysteria-server$' "$service_log" &&
      fail "existing Hysteria2 was stopped before staged validation"
    printf 'entered stage\n' >"$stage_log"
    return 1
  }
  ss() {
    if [[ "$*" == *'-H -lnup'* && "$*" == *':20000'* ]]; then
      printf 'UNCONN 0 0 0.0.0.0:20000 0.0.0.0:* users:(("hysteria",pid=4242,fd=7))\n'
    fi
  }
  systemctl() {
    printf '%s\n' "$*" >>"$service_log"
    case "$*" in
      'show -p LoadState --value '*) printf 'loaded\n' ;;
      'show -p ActiveState --value hysteria-server') printf 'active\n' ;;
      'show -p ActiveState --value '*) printf 'inactive\n' ;;
      'show -p UnitFileState --value hysteria-server') printf 'enabled\n' ;;
      'show -p UnitFileState --value '*) printf 'disabled\n' ;;
      'is-active --quiet hysteria-server'|'is-enabled --quiet hysteria-server') return 0 ;;
      'is-active --quiet '*|'is-enabled --quiet '*) return 1 ;;
      *) return 0 ;;
    esac
  }

  set +e
  (
    set -Eeuo pipefail
    activate_transaction_traps
    deploy_services
  ) >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "staged Hysteria2 failure unexpectedly succeeded"
  [[ -s "$stage_log" ]] || fail "staged Hysteria2 failure test did not reach staging"
  [[ -z "$(awk '$1 ~ /^(stop|start|restart|enable|disable)$/ && $NF == "hysteria-server"' "$service_log")" ]] ||
    fail "staged Hysteria2 failure interrupted the existing service"
  [[ -z "$(awk '$1 ~ /^(stop|start|restart|enable|disable)$/ && $NF == "xray"' "$service_log")" ]] ||
    fail "unchanged Xray installer caused rollback service actions"
  if awk '$1 ~ /^(stop|start|restart|enable|disable)$/ &&
      $NF != "hysteria-server" && $NF != "xray" { found = 1 }
      END { exit !found }' "$service_log"; then
    fail "staged Hysteria2 rollback disturbed another service: $(tr '\n' ',' <"$service_log")"
  fi
  return 0
)

test_task5_staged_hysteria_failure_restores_service

test_task5_partial_service_touch_rollback() (
  local temp_dir service_log
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  BACKUP_DIR="$temp_dir/backup"
  service_log="$temp_dir/systemctl.log"
  RUNTIME_DIR=""
  init_backup_metadata
  cat >"$BACKUP_DIR/services" <<'EOF'
v2ray	active	enabled
xray	inactive	disabled
nginx	active	enabled
hysteria-server	active	enabled
EOF
  systemctl() {
    local service="${*: -1}"
    case "$1" in
      stop|start|restart|enable|disable|reload)
        grep -Fqx "$service" "$BACKUP_DIR/services-touched" ||
          fail "service action was not journaled before systemctl: $*"
        ;;
    esac
    printf '%s\n' "$*" >>"$service_log"
  }

  run_service_mutation xray restart
  run_service_mutation nginx reload
  run_service_mutation xray enable
  assert_eq "600" "$(stat -c '%a' "$BACKUP_DIR/services-touched")" "service touch journal mode"
  assert_eq $'xray\nnginx' "$(cat "$BACKUP_DIR/services-touched")" "deduplicated service touch journal"
  rollback_current_run

  grep -Fqx 'stop xray' "$service_log" || fail "touched Xray was not stopped during rollback"
  grep -Fqx 'stop nginx' "$service_log" || fail "touched Nginx was not stopped during rollback"
  grep -Fqx 'restart nginx' "$service_log" || fail "active Nginx was not restored"
  grep -Fqx 'disable xray' "$service_log" || fail "inactive Xray enablement was not restored"
  grep -Fqx 'enable nginx' "$service_log" || fail "Nginx enablement was not restored"
  grep -Eq '^(stop|start|restart|enable|disable|reload)( --now)? (v2ray|hysteria-server)$' "$service_log" &&
    fail "rollback disturbed an untouched service: $(tr '\n' ',' <"$service_log")"
  return 0
)

test_task5_partial_service_touch_rollback
printf 'PASS: Task 5 precise service mutation journal tests\n'

test_task5_precise_unit_states_and_external_guards() (
  local temp_dir service_log status
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  BACKUP_DIR="$temp_dir/backup"
  service_log="$temp_dir/systemctl.log"
  RUNTIME_DIR=""
  init_backup_metadata
  printf 'inactive\n' >"$temp_dir/v2ray-active"
  printf 'enabled-runtime\n' >"$temp_dir/v2ray-unit"
  printf 'active\n' >"$temp_dir/xray-active"
  printf 'masked\n' >"$temp_dir/xray-unit"
  printf 'inactive\n' >"$temp_dir/nginx-active"
  printf 'masked-runtime\n' >"$temp_dir/nginx-unit"
  printf 'active\n' >"$temp_dir/hysteria-server-active"
  printf 'disabled\n' >"$temp_dir/hysteria-server-unit"
  systemctl() {
    local action="$1" service="${*: -1}" state_file
    case "$*" in
      'show -p LoadState --value '*) printf 'loaded\n' ;;
      'show -p ActiveState --value '*) cat "$temp_dir/$service-active" ;;
      'show -p UnitFileState --value '*) cat "$temp_dir/$service-unit" ;;
      'is-active --quiet '*) [[ "$(cat "$temp_dir/$service-active")" == "active" ]] ;;
      'is-enabled --quiet '*)
        [[ "$(cat "$temp_dir/$service-unit")" == "enabled" ||
          "$(cat "$temp_dir/$service-unit")" == "enabled-runtime" ]]
        ;;
      stop\ *) printf 'inactive\n' >"$temp_dir/$service-active" ;;
      start\ *|restart\ *) printf 'active\n' >"$temp_dir/$service-active" ;;
      enable\ *)
        [[ "$*" == *' --runtime '* ]] && state_file="enabled-runtime" || state_file="enabled"
        printf '%s\n' "$state_file" >"$temp_dir/$service-unit"
        ;;
      disable\ *) printf 'disabled\n' >"$temp_dir/$service-unit" ;;
      unmask\ *) printf 'disabled\n' >"$temp_dir/$service-unit" ;;
      mask\ *)
        [[ "$*" == *' --runtime '* ]] && state_file="masked-runtime" || state_file="masked"
        printf '%s\n' "$state_file" >"$temp_dir/$service-unit"
        ;;
      *) return 1 ;;
    esac
    printf '%s\n' "$*" >>"$service_log"
  }

  record_service_states
  printf '%s\n' v2ray xray nginx hysteria-server >"$BACKUP_DIR/services-touched"
  printf 'active\n' >"$temp_dir/v2ray-active"
  printf 'enabled\n' >"$temp_dir/v2ray-unit"
  printf 'inactive\n' >"$temp_dir/xray-active"
  printf 'enabled\n' >"$temp_dir/xray-unit"
  printf 'active\n' >"$temp_dir/nginx-active"
  printf 'enabled\n' >"$temp_dir/nginx-unit"
  printf 'inactive\n' >"$temp_dir/hysteria-server-active"
  printf 'enabled\n' >"$temp_dir/hysteria-server-unit"
  rollback_current_run
  assert_eq "inactive" "$(cat "$temp_dir/v2ray-active")" "enabled-runtime service activity"
  assert_eq "enabled-runtime" "$(cat "$temp_dir/v2ray-unit")" "enabled-runtime restoration"
  assert_eq "active" "$(cat "$temp_dir/xray-active")" "masked active service restoration"
  assert_eq "masked" "$(cat "$temp_dir/xray-unit")" "masked restoration"
  assert_eq "inactive" "$(cat "$temp_dir/nginx-active")" "masked-runtime service activity"
  assert_eq "masked-runtime" "$(cat "$temp_dir/nginx-unit")" "masked-runtime restoration"
  assert_eq "active" "$(cat "$temp_dir/hysteria-server-active")" "disabled active service restoration"
  assert_eq "disabled" "$(cat "$temp_dir/hysteria-server-unit")" "disabled restoration"

  BACKUP_DIR="$temp_dir/guard-backup"
  init_backup_metadata
  : >"$service_log"
  printf 'active\n' >"$temp_dir/xray-active"
  printf 'enabled-runtime\n' >"$temp_dir/xray-unit"
  record_service_states
  unchanged_external_failure() { return 73; }
  set +e
  run_guarded_service_action xray unchanged_external_failure
  status=$?
  set -e
  assert_eq "73" "$status" "guarded external failure status"
  [[ ! -s "$BACKUP_DIR/services-touched" ]] || fail "unchanged failed external action touched Xray"
  grep -Eq '^(stop|start|restart) ' "$service_log" &&
    fail "unchanged failed external action caused a service interruption"

  unchanged_external_restart() {
    printf 'inactive\n' >"$temp_dir/xray-active"
    printf 'active\n' >"$temp_dir/xray-active"
  }
  run_guarded_service_action xray unchanged_external_restart
  [[ ! -s "$BACKUP_DIR/services-touched" ]] ||
    fail "external restart with an unchanged final state was journaled"

  changed_external_failure() {
    printf 'inactive\n' >"$temp_dir/xray-active"
    printf 'disabled\n' >"$temp_dir/xray-unit"
    return 74
  }
  set +e
  run_guarded_service_action xray changed_external_failure
  status=$?
  set -e
  assert_eq "74" "$status" "changed guarded external failure status"
  grep -Fqx xray "$BACKUP_DIR/services-touched" || fail "changed external action was not journaled"
  cat >"$BACKUP_DIR/services" <<'EOF'
xray	active	enabled-runtime
EOF
  rollback_current_run
  assert_eq "active" "$(cat "$temp_dir/xray-active")" "changed external activity rollback"
  assert_eq "enabled-runtime" "$(cat "$temp_dir/xray-unit")" "changed external unit state rollback"

  BACKUP_DIR="$temp_dir/unsupported-backup"
  init_backup_metadata
  cat >"$BACKUP_DIR/services" <<'EOF'
xray	inactive	static
EOF
  assert_fails "unsupported original service state" record_service_touch xray
  [[ ! -s "$BACKUP_DIR/services-touched" ]] || fail "unsupported unit state was touched"
)

test_task5_precise_unit_states_and_external_guards
printf 'PASS: Task 5 precise unit state and external guard tests\n'

test_task5_external_installer_service_mutations_are_transactional() (
  local temp_dir violation_log package_log status package_call_count=0
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  violation_log="$temp_dir/violations.log"
  package_log="$temp_dir/packages.log"
  BACKUP_ROOT="$temp_dir/backups"
  XRAY_CONFIG="$temp_dir/xray/config.json"
  STATE_FILE="$temp_dir/state/state.env"
  NGINX_SITE="$temp_dir/nginx/site.conf"
  RENEWAL_HOOK="$temp_dir/hooks/hook.sh"
  LEGACY_V2RAY_CONFIG="$temp_dir/v2ray/config.json"
  HYSTERIA_BIN="$temp_dir/usr/local/bin/hysteria"
  HYSTERIA_CONFIG="$temp_dir/etc/hysteria/config.yaml"
  HYSTERIA_ACL="$temp_dir/etc/hysteria/acl.txt"
  HYSTERIA_CERT="$temp_dir/etc/hysteria/server.crt"
  HYSTERIA_KEY="$temp_dir/etc/hysteria/server.key"
  HYSTERIA_UNIT="$temp_dir/etc/systemd/system/hysteria-server.service"
  HYSTERIA_OWNERSHIP_MANIFEST="$temp_dir/etc/v2ray-onekey/hysteria.manifest"
  RUNTIME_DIR=""
  MODE="cloudflare"
  PKG_MANAGER="apt"
  printf 'active\n' >"$temp_dir/xray-active"
  printf 'enabled\n' >"$temp_dir/xray-enabled"
  printf 'inactive\n' >"$temp_dir/nginx-active"
  printf 'disabled\n' >"$temp_dir/nginx-enabled"

  legacy_nginx_config_paths() { :; }
  apt-get() {
    printf '%s\n' "$*" >>"$package_log"
    if (( package_call_count == 0 )) && grep -Fqx nginx "$BACKUP_DIR/services-touched"; then
      printf 'nginx package action was touched before a state change\n' >>"$violation_log"
    fi
    package_call_count=$((package_call_count + 1))
    printf 'active\n' >"$temp_dir/nginx-active"
    printf 'enabled\n' >"$temp_dir/nginx-enabled"
  }
  install_xray_core() {
    if grep -Fqx xray "$BACKUP_DIR/services-touched"; then
      printf 'xray installer was touched before a state change\n' >>"$violation_log"
    fi
    printf 'inactive\n' >"$temp_dir/xray-active"
    printf 'disabled\n' >"$temp_dir/xray-enabled"
  }
  systemctl() {
    local action="$1" service="${*: -1}"
    case "$*" in
      'show -p LoadState --value '*) printf 'loaded\n' ;;
      'show -p ActiveState --value '*)
        case "$service" in
          xray|nginx) cat "$temp_dir/$service-active" ;;
          *) printf 'inactive\n' ;;
        esac
        ;;
      'show -p UnitFileState --value '*)
        case "$service" in
          xray|nginx) cat "$temp_dir/$service-enabled" ;;
          *) printf 'disabled\n' ;;
        esac
        ;;
      *) case "$action" in
      is-active)
        case "$service" in
          xray) [[ "$(cat "$temp_dir/xray-active")" == "active" ]] ;;
          nginx) [[ "$(cat "$temp_dir/nginx-active")" == "active" ]] ;;
          *) return 1 ;;
        esac
        ;;
      is-enabled)
        case "$service" in
          xray) [[ "$(cat "$temp_dir/xray-enabled")" == "enabled" ]] ;;
          nginx) [[ "$(cat "$temp_dir/nginx-enabled")" == "enabled" ]] ;;
          *) return 1 ;;
        esac
        ;;
      stop)
        [[ "$service" == "xray" || "$service" == "nginx" ]] &&
          printf 'inactive\n' >"$temp_dir/$service-active"
        ;;
      start|restart)
        [[ "$service" == "xray" || "$service" == "nginx" ]] &&
          printf 'active\n' >"$temp_dir/$service-active"
        ;;
      enable)
        [[ "$service" == "xray" || "$service" == "nginx" ]] &&
          printf 'enabled\n' >"$temp_dir/$service-enabled"
        ;;
      disable)
        [[ "$service" == "xray" || "$service" == "nginx" ]] &&
          printf 'disabled\n' >"$temp_dir/$service-enabled"
        ;;
      daemon-reload) : ;;
      *) return 1 ;;
      esac ;;
    esac
  }
  prepare_fresh_inputs() { :; }
  generate_runtime_values() { return 1; }

  set +e
  (
    set -Eeuo pipefail
    activate_transaction_traps
    deploy_services
  ) >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "external service mutation deployment unexpectedly succeeded"
  [[ ! -s "$violation_log" ]] || fail "$(tr '\n' ',' <"$violation_log")"
  assert_eq "active" "$(cat "$temp_dir/xray-active")" "Xray active state after installer rollback"
  assert_eq "enabled" "$(cat "$temp_dir/xray-enabled")" "Xray enabled state after installer rollback"
  assert_eq "inactive" "$(cat "$temp_dir/nginx-active")" "Nginx active state after package rollback"
  assert_eq "disabled" "$(cat "$temp_dir/nginx-enabled")" "Nginx enabled state after package rollback"
  grep -Fq 'install -y --no-install-recommends nginx certbot' "$package_log" ||
    fail "Cloudflare transaction did not exercise Nginx package installation"

  BACKUP_DIR="$temp_dir/direct-backup"
  init_backup_metadata
  : >"$package_log"
  MODE="direct"
  apt-get() {
    printf '%s\n' "$*" >>"$package_log"
    grep -Fqx nginx "$BACKUP_DIR/services-touched" &&
      fail "direct package installation marked Nginx as touched"
    return 0
  }
  install_required_packages
  grep -Eq '(^|[[:space:]])nginx([[:space:]]|$)' "$package_log" &&
    fail "direct package installation requested Nginx"
  grep -Fqx nginx "$BACKUP_DIR/services-touched" &&
    fail "direct package installation retained an Nginx touch"
  return 0
)

test_task5_external_installer_service_mutations_are_transactional
printf 'PASS: Task 5 external installer service transaction tests\n'

test_task5_xray_paths_and_installer_environment_are_fixed() (
  local inherited installer_environment managed path
  inherited="$(
    XRAY_CONFIG=/tmp/injected-config.json \
    XRAY_BIN=/tmp/injected-bin \
    XRAY_DATA_DIR=/tmp/injected-data \
    XRAY_LOG_DIR=/tmp/injected-log \
    XRAY_SYSTEMD_DIR=/tmp/injected-systemd \
    V2RAY_ONEKEY_SOURCE_ONLY=1 bash -c '
      source "$1"
      printf "%s|%s|%s|%s|%s\n" "$XRAY_CONFIG" "$XRAY_BIN" "$XRAY_DATA_DIR" "$XRAY_LOG_DIR" "$XRAY_SYSTEMD_DIR"
    ' _ "$SCRIPT"
  )"
  assert_eq '/usr/local/etc/xray/config.json|/usr/local/bin/xray|/usr/local/share/xray|/var/log/xray|/etc/systemd/system' \
    "$inherited" "fixed Xray installer paths"
  managed="$(xray_installer_managed_paths)"
  for path in /usr/local/bin/xray /usr/local/share/xray/geoip.dat \
    /usr/local/share/xray/geosite.dat /usr/local/etc/xray/config.json \
    /var/log/xray/access.log /var/log/xray/error.log \
    /etc/systemd/system/xray.service /etc/systemd/system/xray@.service; do
    grep -Fqx "$path" <<<"$managed" || fail "fixed Xray path is outside the transaction manifest: $path"
  done
  [[ "$managed" != *'/tmp/injected-'* ]] || fail "injected Xray path entered the transaction manifest"

  export DAT_PATH=/tmp/injected-dat
  export JSON_PATH=/tmp/injected-json
  export JSONS_PATH=/tmp/injected-jsons
  export BASH_ENV=/tmp/injected-bash-env
  export ENV=/tmp/injected-env
  export check_all_service_files=yes
  export XRAY_CUSTOMIZE=xray@foreign.service
  curl() { printf 'official-installer-body'; }
  bash() {
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
      "${DAT_PATH-unset}" "${JSON_PATH-unset}" "${JSONS_PATH-unset}" \
      "${BASH_ENV-unset}" "${ENV-unset}" "${check_all_service_files-unset}" \
      "${XRAY_CUSTOMIZE-unset}"
  }
  installer_environment="$(install_xray_core)"
  installer_environment="${installer_environment##*$'\n'}"
  assert_eq '/usr/local/share/xray|/usr/local/etc/xray|unset|unset|unset|unset|unset' \
    "$installer_environment" "isolated Xray installer environment"
)

test_task5_xray_paths_and_installer_environment_are_fixed
printf 'PASS: Task 5 fixed Xray installer environment tests\n'

test_task5_xray_first_install_not_found_rollback() (
  local temp_dir service_log status state path foreign_root foreign_dropin
  local enablement_link enablement_directory
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  BACKUP_DIR="$temp_dir/backup"
  RUNTIME_DIR=""
  XRAY_BIN="$temp_dir/usr/local/bin/xray"
  XRAY_CONFIG="$temp_dir/usr/local/etc/xray/config.json"
  XRAY_DATA_DIR="$temp_dir/usr/local/share/xray"
  XRAY_LOG_DIR="$temp_dir/var/log/xray"
  XRAY_SYSTEMD_DIR="$temp_dir/etc/systemd/system"
  enablement_link="$XRAY_SYSTEMD_DIR/multi-user.target.wants/xray.service"
  enablement_directory="$(dirname "$enablement_link")"
  service_log="$temp_dir/systemctl.log"
  install -d "$(dirname "$XRAY_BIN")" "$XRAY_DATA_DIR" "$XRAY_SYSTEMD_DIR"
  printf 'preexisting binary\n' >"$XRAY_BIN"
  printf 'preexisting geoip\n' >"$XRAY_DATA_DIR/geoip.dat"
  chmod 0711 "$XRAY_DATA_DIR"
  init_backup_metadata
  cat >"$BACKUP_DIR/services" <<'EOF'
xray	inactive	not-found
EOF
  systemctl() {
    local unit="$XRAY_SYSTEMD_DIR/xray.service"
    printf '%s\n' "$*" >>"$service_log"
    case "$*" in
      'show -p LoadState --value xray') [[ -f "$unit" ]] && printf 'loaded\n' || printf 'not-found\n' ;;
      'show -p ActiveState --value xray') printf 'inactive\n' ;;
      'show -p UnitFileState --value xray') [[ -f "$unit" ]] && printf 'disabled\n' ;;
      *) return 0 ;;
    esac
  }
  record_xray_installer_state
  fake_xray_first_installer() {
    local managed
    while IFS= read -r managed; do
      install -d "$(dirname "$managed")"
      printf 'installer-created %s\n' "$(basename "$managed")" >"$managed"
    done < <(xray_installer_managed_paths)
    install -d "$enablement_directory"
    ln -s ../xray.service "$enablement_link"
    return 73
  }
  set +e
  run_guarded_service_action xray fake_xray_first_installer
  status=$?
  set -e
  assert_eq "73" "$status" "first Xray installer failure status"
  grep -Fqx xray "$BACKUP_DIR/services-touched" || fail "first Xray install service change was not journaled"
  rollback_current_run
  assert_eq "preexisting binary" "$(cat "$XRAY_BIN")" "preexisting Xray binary restoration"
  assert_eq "preexisting geoip" "$(cat "$XRAY_DATA_DIR/geoip.dat")" "preexisting Xray geoip restoration"
  assert_eq "711" "$(stat -c '%a' "$XRAY_DATA_DIR")" "preexisting Xray data directory mode"
  for path in "$XRAY_CONFIG" "$XRAY_DATA_DIR/geosite.dat" \
    "$XRAY_LOG_DIR/access.log" "$XRAY_LOG_DIR/error.log" \
    "$XRAY_SYSTEMD_DIR/xray.service" "$XRAY_SYSTEMD_DIR/xray@.service" \
    "$XRAY_SYSTEMD_DIR/xray.service.d/10-donot_touch_single_conf.conf" \
    "$XRAY_SYSTEMD_DIR/xray.service.d/10-donot_touch_multi_conf.conf" \
    "$XRAY_SYSTEMD_DIR/xray@.service.d/10-donot_touch_single_conf.conf" \
    "$XRAY_SYSTEMD_DIR/xray@.service.d/10-donot_touch_multi_conf.conf"; do
    [[ ! -e "$path" ]] || fail "first Xray rollback retained installer file: $path"
  done
  [[ ! -e "$enablement_link" && ! -L "$enablement_link" ]] ||
    fail "first Xray rollback retained the enablement symlink"
  [[ ! -e "$(dirname "$XRAY_CONFIG")" && ! -e "$XRAY_LOG_DIR" &&
    ! -e "$XRAY_SYSTEMD_DIR/xray.service.d" && ! -e "$XRAY_SYSTEMD_DIR/xray@.service.d" &&
    ! -e "$enablement_directory" ]] ||
    fail "first Xray rollback retained installer-created directories"
  state="$(query_service_state xray)" || fail "unable to inspect rolled-back Xray state"
  assert_eq $'inactive\tnot-found' "$state" "first Xray exact service rollback"
  grep -Fq 'daemon-reload' "$service_log" || fail "first Xray rollback omitted daemon-reload"
  grep -Fq 'disable xray' "$service_log" && fail "not-found Xray rollback called disable"

  BACKUP_DIR="$temp_dir/inconsistent-enablement-backup"
  init_backup_metadata
  cat >"$BACKUP_DIR/services" <<'EOF'
xray	inactive	not-found
EOF
  install -d "$enablement_directory"
  ln -s ../xray.service "$enablement_link"
  assert_fails "inconsistent Xray enablement" record_xray_installer_state
  rm -f "$enablement_link"
  printf 'foreign regular file\n' >"$enablement_link"
  assert_fails "inconsistent Xray enablement" record_xray_installer_state
  rm -f "$enablement_link"
  rmdir "$enablement_directory"

  BACKUP_DIR="$temp_dir/enabled-project-backup"
  init_backup_metadata
  cat >"$BACKUP_DIR/services" <<'EOF'
xray	active	enabled
EOF
  printf '[Unit]\nDescription=project Xray\n' >"$XRAY_SYSTEMD_DIR/xray.service"
  install -d "$enablement_directory"
  ln -s ../xray.service "$enablement_link"
  record_xray_installer_state
  printf 'xray\n' >"$BACKUP_DIR/services-touched"
  rollback_current_run
  [[ -L "$enablement_link" ]] || fail "rollback removed a preexisting project Xray enablement link"
  assert_eq '../xray.service' "$(readlink "$enablement_link")" \
    "preexisting project Xray enablement target"
  rm -f "$enablement_link" "$XRAY_SYSTEMD_DIR/xray.service"
  rmdir "$enablement_directory"

  BACKUP_DIR="$temp_dir/foreign-backup"
  init_backup_metadata
  cat >"$BACKUP_DIR/services" <<'EOF'
xray	inactive	not-found
EOF
  foreign_root="$temp_dir/usr/lib/systemd/system"
  foreign_dropin="$foreign_root/xray.service.d/99-foreign.conf"
  install -d "$(dirname "$foreign_dropin")"
  printf '[Service]\nEnvironment=FOREIGN=1\n' >"$foreign_dropin"
  xray_standard_unit_directories() { printf '%s\n' "$foreign_root"; }
  assert_fails "unmanaged Xray systemd drop-in" record_xray_installer_state
  rm -f "$foreign_dropin"
  ln -s "$temp_dir/foreign-target" "$foreign_dropin"
  assert_fails "unmanaged Xray systemd drop-in" record_xray_installer_state
  return 0
)

test_task5_xray_first_install_not_found_rollback
printf 'PASS: Task 5 first Xray install rollback tests\n'

test_task5_firewall_transaction_records() (
  local temp_dir firewall_log
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  BACKUP_DIR="$temp_dir/backup"
  install -d -m 700 "$BACKUP_DIR"
  init_backup_metadata
  firewall_log="$temp_dir/firewall.log"
  ufw_state="active"
  firewalld_state="active"
  ufw_existing=""
  firewalld_runtime_existing=""
  firewalld_permanent_existing=""

  ufw() {
    if [[ "$1" == "status" ]]; then
      printf 'Status: %s\n%s\n' "$ufw_state" "$ufw_existing"
      return 0
    fi
    printf 'ufw %s\n' "$*" >>"$firewall_log"
  }
  systemctl() {
    [[ "$1 $2" == 'is-active firewalld' ]] || return 1
    if [[ "$firewalld_state" == "active" ]]; then printf 'active\n'; return 0; fi
    printf 'inactive\n'
    return 3
  }
  firewall-cmd() {
    case "$1" in
      --query-port=*) [[ "$firewalld_runtime_existing" == *"${1#--query-port=}"* ]] ;;
      --permanent)
        if [[ "$2" == --query-port=* ]]; then
          [[ "$firewalld_permanent_existing" == *"${2#--query-port=}"* ]]
        else
          printf 'firewall %s\n' "$*" >>"$firewall_log"
        fi
        ;;
      *) printf 'firewall %s\n' "$*" >>"$firewall_log" ;;
    esac
  }

  open_firewall_range 20000 20100 udp
  grep -Fq 'ufw allow 20000:20100/udp' "$firewall_log" || fail "UFW range rule missing"
  grep -Fq 'firewall --add-port=20000-20100/udp' "$firewall_log" ||
    fail "firewalld runtime range rule missing"
  grep -Fq 'firewall --permanent --add-port=20000-20100/udp' "$firewall_log" ||
    fail "firewalld permanent range rule missing"
  assert_eq "3" "$(wc -l <"$BACKUP_DIR/firewall-rules" | tr -d ' ')" \
    "recorded current-run firewall additions"

  rollback_firewall_rules
  grep -Fq 'ufw delete allow 20000:20100/udp' "$firewall_log" || fail "UFW range rollback missing"
  grep -Fq 'firewall --remove-port=20000-20100/udp' "$firewall_log" ||
    fail "firewalld runtime rollback missing"
  grep -Fq 'firewall --permanent --remove-port=20000-20100/udp' "$firewall_log" ||
    fail "firewalld permanent rollback missing"

  : >"$firewall_log"
  : >"$BACKUP_DIR/firewall-rules"
  ufw_existing="20000:20100/udp ALLOW Anywhere"
  firewalld_runtime_existing="20000-20100/udp"
  firewalld_permanent_existing="20000-20100/udp"
  open_firewall_range 20000 20100 udp
  [[ ! -s "$firewall_log" && ! -s "$BACKUP_DIR/firewall-rules" ]] ||
    fail "pre-existing firewall rules were changed or adopted"

  ufw_state="inactive"
  firewalld_state="inactive"
  open_firewall_range 21000 21100 udp
  [[ ! -s "$firewall_log" ]] || fail "inactive firewall was modified"
)

test_task5_firewall_transaction_records
printf 'PASS: Task 5 firewall transaction tests\n'

test_task5_active_firewall_failures_are_transactional() (
  local temp_dir firewall_log status_file mode="ufw-query-fail"
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  BACKUP_DIR="$temp_dir/backup"
  init_backup_metadata
  firewall_log="$temp_dir/firewall.log"
  status_file="$temp_dir/ufw-status-count"
  : >"$status_file"
  ufw() {
    case "$1" in
      status)
        printf 'call\n' >>"$status_file"
        [[ "$mode" == "ufw-query-fail" && "$(wc -l <"$status_file")" -gt 1 ]] && return 2
        printf 'Status: active\n'
        ;;
      allow) [[ "$mode" != "ufw-add-fail" ]] ;;
      *) printf 'ufw %s\n' "$*" >>"$firewall_log" ;;
    esac
  }
  systemctl() { return 3; }
  assert_fails "Unable to query active UFW" open_firewall_port 24444 udp

  mode="ufw-add-fail"
  : >"$status_file"
  assert_fails "UFW failed to allow required" open_firewall_port 24444 udp
  assert_eq $'ufw\t24444/udp' "$(cat "$BACKUP_DIR/firewall-rules")" \
    "failed UFW add rollback journal"

  mode="firewalld-runtime-query-fail"
  ufw() { printf 'Status: inactive\n'; }
  systemctl() {
    [[ "$*" == 'is-active firewalld' ]] || return 1
    printf 'active\n'
  }
  firewall-cmd() {
    [[ "$mode" == "firewalld-runtime-query-fail" && "$1" == --query-port=* ]] && return 2
    case "$*" in
      --query-port=*) return 1 ;;
      '--permanent --query-port='*) return 1 ;;
      '--permanent --add-port='*) return 2 ;;
      *) printf 'firewall %s\n' "$*" >>"$firewall_log" ;;
    esac
  }
  assert_fails "Unable to query active firewalld runtime" open_firewall_port 25555 udp

  mode="firewalld-permanent-add-fail"
  : >"$firewall_log"
  : >"$BACKUP_DIR/firewall-rules"
  assert_fails "required permanent rule" open_firewall_port 25555 udp
  assert_eq $'firewalld-runtime\t25555/udp\nfirewalld-permanent\t25555/udp' \
    "$(cat "$BACKUP_DIR/firewall-rules")" \
    "partial firewalld addition journal"
  rollback_firewall_rules
  grep -Fq 'firewall --remove-port=25555/udp' "$firewall_log" ||
    fail "partial firewalld runtime addition was not rolled back"
  grep -Fq -- '--permanent --remove-port=25555/udp' "$firewall_log" ||
    fail "pending permanent firewalld addition was not rolled back"
  return 0
)

test_task5_active_firewall_failures_are_transactional
printf 'PASS: Task 5 active firewall failure tests\n'

test_task5_firewall_status_and_journal_are_fail_closed() (
  local temp_dir firewall_log locale_log journal_seen=0
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  BACKUP_DIR="$temp_dir/backup"
  init_backup_metadata
  firewall_log="$temp_dir/firewall.log"
  locale_log="$temp_dir/locale.log"
  ufw() {
    case "$1" in
      status) return 2 ;;
      allow) printf 'add:%s\n' "$2" >>"$firewall_log" ;;
    esac
  }
  systemctl() { printf 'inactive\n'; return 3; }
  assert_fails "Unable to inspect UFW status" open_firewall_port 26661 udp
  [[ ! -e "$firewall_log" ]] || fail "UFW status failure still added a rule"

  ufw() {
    case "$1" in
      status)
        if [[ "${LC_ALL:-}" == "C" ]]; then
          printf 'C\n' >>"$locale_log"
          printf 'Status: active\n'
        else
          printf 'Estado: activo\n'
        fi
        ;;
      allow)
        grep -Fqx $'ufw\t26662/udp' "$BACKUP_DIR/firewall-rules" && journal_seen=1
        printf 'add:%s\n' "$2" >>"$firewall_log"
        ;;
      delete) : ;;
    esac
  }
  open_firewall_port 26662 udp
  grep -Fqx C "$locale_log" || fail "UFW status was not queried with LC_ALL=C"
  [[ "$journal_seen" == "1" ]] || fail "UFW add ran before its rollback journal was persisted"

  : >"$firewall_log"
  ufw() { printf 'Status: inactive\n'; }
  firewall-cmd() {
    [[ "$*" == *'--query-port='* ]] && return 1
    printf 'firewall:%s\n' "$*" >>"$firewall_log"
  }
  systemctl() { printf 'failed\n'; return 1; }
  assert_fails "Unable to inspect firewalld state" open_firewall_port 26663 udp
  [[ ! -s "$firewall_log" ]] || fail "firewalld query failure modified rules"
  systemctl() { printf 'unknown\n'; return 4; }
  open_firewall_port 26664 udp

  ufw() {
    case "$1" in
      status) printf 'Status: active\n' ;;
      allow) printf 'add:%s\n' "$2" >>"$firewall_log" ;;
    esac
  }
  systemctl() { printf 'inactive\n'; return 3; }
  rm -f "$BACKUP_DIR/firewall-rules"
  assert_fails "Firewall journal is unavailable" open_firewall_port 26665 udp
  [[ ! -s "$firewall_log" ]] || fail "missing firewall journal still allowed an add"

  ln -s "$temp_dir/journal-target" "$BACKUP_DIR/firewall-rules"
  assert_fails "Firewall journal is unavailable" open_firewall_port 26666 udp
  [[ ! -s "$firewall_log" ]] || fail "symlink firewall journal still allowed an add"

  rm -f "$BACKUP_DIR/firewall-rules"
  : >"$BACKUP_DIR/firewall-rules"
  chmod 0600 "$BACKUP_DIR/firewall-rules"
  append_firewall_record() { return 74; }
  assert_fails "Unable to persist firewall rollback rule" open_firewall_port 26667 udp
  [[ ! -s "$firewall_log" ]] || fail "failed firewall journal append still allowed an add"
  append_firewall_record() {
    printf '%s\t%s\n' "$1" "$2" >>"$BACKUP_DIR/firewall-rules"
  }

  (
    chmod() {
      [[ "$*" == "0600 $BACKUP_DIR/firewall-rules" ]] && return 75
      command chmod "$@"
    }
    assert_fails "Unable to secure firewall rollback journal" open_firewall_port 26668 udp
  )
  [[ ! -s "$firewall_log" ]] || fail "failed firewall journal chmod still allowed an add"
  return 0
)

test_task5_firewall_status_and_journal_are_fail_closed
printf 'PASS: Task 5 strict firewall status and journal tests\n'

test_task5_hysteria_ownership_accounts_and_rollback() (
  local temp_dir service_log account_log current_user current_group path account_user=0 account_group=0
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  HYSTERIA_BIN="$temp_dir/usr/local/bin/hysteria"
  HYSTERIA_CONFIG="$temp_dir/etc/hysteria/config.yaml"
  HYSTERIA_ACL="$temp_dir/etc/hysteria/acl.txt"
  HYSTERIA_CERT="$temp_dir/etc/hysteria/server.crt"
  HYSTERIA_KEY="$temp_dir/etc/hysteria/server.key"
  HYSTERIA_UNIT="$temp_dir/etc/systemd/system/hysteria-server.service"
  HYSTERIA_OWNERSHIP_MANIFEST="$temp_dir/etc/v2ray-onekey/hysteria.manifest"
  XRAY_CONFIG="$temp_dir/xray/config.json"
  STATE_FILE="$temp_dir/state/state.env"
  NGINX_SITE="$temp_dir/nginx/site.conf"
  RENEWAL_HOOK="$temp_dir/hooks/hook.sh"
  LEGACY_V2RAY_CONFIG="$temp_dir/v2ray/config.json"
  BACKUP_DIR="$temp_dir/backup"
  MODE="direct"
  install -d "$(dirname "$HYSTERIA_CONFIG")" "$(dirname "$HYSTERIA_UNIT")" \
    "$(dirname "$HYSTERIA_BIN")"
  printf 'third-party\n' >"$HYSTERIA_BIN"
  assert_fails "Refusing unmanaged Hysteria2" validate_managed_destination_ownership
  rm -f "$HYSTERIA_BIN"

  for path in "$HYSTERIA_BIN" "$HYSTERIA_CONFIG" "$HYSTERIA_ACL" "$HYSTERIA_CERT" \
    "$HYSTERIA_KEY" "$HYSTERIA_UNIT"; do
    install -d "$(dirname "$path")"
    case "$path" in
      "$HYSTERIA_CONFIG") printf '%s\n' "$HYSTERIA_CONFIG_MARKER" >"$path" ;;
      "$HYSTERIA_ACL") printf '%s\n' "$HYSTERIA_ACL_MARKER" >"$path" ;;
      "$HYSTERIA_UNIT") printf '%s\n' "$HYSTERIA_UNIT_MARKER" >"$path" ;;
      *) printf 'project-owned-%s\n' "$(basename "$path")" >"$path" ;;
    esac
  done
  systemctl() {
    case "$*" in
      'show -p FragmentPath --value hysteria-server') printf '%s\n' "$HYSTERIA_UNIT" ;;
      'show -p DropInPaths --value hysteria-server') printf '\n' ;;
      *) return 1 ;;
    esac
  }
  write_hysteria_ownership_manifest
  validate_managed_destination_ownership
  printf 'external\n' >"$(dirname "$HYSTERIA_CONFIG")/external.yaml"
  assert_fails "Refusing unmanaged Hysteria2" validate_managed_destination_ownership
  rm -f "$(dirname "$HYSTERIA_CONFIG")/external.yaml"
  printf 'tampered\n' >>"$HYSTERIA_BIN"
  assert_fails "Refusing unmanaged Hysteria2" validate_managed_destination_ownership
  printf 'project-owned-%s\n' "$(basename "$HYSTERIA_BIN")" >"$HYSTERIA_BIN"

  init_backup_metadata
  for path in "$HYSTERIA_BIN" "$HYSTERIA_CONFIG" "$HYSTERIA_ACL" "$HYSTERIA_CERT" \
    "$HYSTERIA_KEY" "$HYSTERIA_UNIT" "$HYSTERIA_OWNERSHIP_MANIFEST"; do
    backup_file "$path"
  done
  grep -Fqx $'present\t'"$HYSTERIA_BIN" "$BACKUP_DIR/manifest" ||
    fail "Hysteria2 binary missing from transaction manifest"

  current_user="$(id -un)"
  current_group="$(id -gn)"
  account_log="$temp_dir/accounts.log"
  LOGIN_DEFS_FILE="$temp_dir/login.defs"
  printf 'SYS_UID_MAX 999\nSYS_GID_MAX 999\n' >"$LOGIN_DEFS_FILE"
  getent() {
    case "$1 $2" in
      'group hysteria') [[ "$account_group" == "1" ]] && printf 'hysteria:x:500:\n' ;;
      'passwd hysteria') [[ "$account_user" == "1" ]] && printf 'hysteria:x:500:500::/nonexistent:/usr/sbin/nologin\n' ;;
      *) return 2 ;;
    esac
  }
  id() {
    case "$*" in
      hysteria) [[ "$account_user" == "1" ]] ;;
      '-u hysteria') [[ "$account_user" == "1" ]] && printf '500\n' ;;
      '-g hysteria') [[ "$account_user" == "1" ]] && printf '500\n' ;;
      '-gn hysteria') [[ "$account_user" == "1" ]] && printf 'hysteria\n' ;;
      '-G hysteria') [[ "$account_user" == "1" ]] && printf '500\n' ;;
      -u) command id -u ;;
      -un) printf '%s\n' "$current_user" ;;
      -gn) printf '%s\n' "$current_group" ;;
      *) command id "$@" ;;
    esac
  }
  groupadd() { account_group=1; printf 'groupadd %s\n' "$*" >>"$account_log"; }
  useradd() { account_user=1; printf 'useradd %s\n' "$*" >>"$account_log"; }
  ensure_hysteria_account
  grep -Fq 'groupadd --system hysteria' "$account_log" || fail "minimal Hysteria group was not created"
  grep -Fq 'useradd --system --gid hysteria --home-dir /nonexistent --shell /usr/sbin/nologin hysteria' \
    "$account_log" || fail "minimal Hysteria user was not created"
  grep -Fqx $'hysteria\tcreated\tcreated' "$BACKUP_DIR/accounts" ||
    fail "created Hysteria account was not recorded"

  service_log="$temp_dir/services.log"
  cat >"$BACKUP_DIR/services" <<'EOF'
hysteria-server	inactive	disabled
EOF
  printf 'hysteria-server\n' >"$BACKUP_DIR/services-touched"
  chmod 0600 "$BACKUP_DIR/services-touched"
  systemctl() { printf '%s\n' "$*" >>"$service_log"; }
  userdel() { printf 'userdel %s\n' "$*" >>"$account_log"; }
  groupdel() { printf 'groupdel %s\n' "$*" >>"$account_log"; }
  printf 'new-binary\n' >"$HYSTERIA_BIN"
  rollback_current_run
  assert_eq "project-owned-hysteria" "$(cat "$HYSTERIA_BIN")" "Hysteria2 binary rollback"
  grep -Fqx 'stop hysteria-server' "$service_log" || fail "Hysteria2 was not stopped for rollback"
  grep -Fqx 'disable hysteria-server' "$service_log" || fail "Hysteria2 enablement was not restored"
  grep -Fq 'userdel hysteria' "$account_log" || fail "created Hysteria user was not rolled back"
  grep -Fq 'groupdel hysteria' "$account_log" || fail "created Hysteria group was not rolled back"
)

test_task5_hysteria_ownership_accounts_and_rollback
printf 'PASS: Task 5 Hysteria ownership and account tests\n'

test_task5_hysteria_account_is_minimal_system_identity() (
  local temp_dir account_uid=500 account_gid=500 account_groups=500 group_members=""
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  LOGIN_DEFS_FILE="$temp_dir/login.defs"
  printf 'SYS_UID_MAX 999\nSYS_GID_MAX 999\n' >"$LOGIN_DEFS_FILE"
  getent() {
    case "$1" in
      passwd) printf 'hysteria:x:%s:%s::/nonexistent:/usr/sbin/nologin\n' "$account_uid" "$account_gid" ;;
      group) printf 'hysteria:x:%s:%s\n' "$account_gid" "$group_members" ;;
    esac
  }
  id() {
    case "$1" in
      -u) printf '%s\n' "$account_uid" ;;
      -g) printf '%s\n' "$account_gid" ;;
      -gn) printf 'hysteria\n' ;;
      -G) printf '%s\n' "$account_groups" ;;
      hysteria) return 0 ;;
    esac
  }
  hysteria_account_identity_is_safe >/dev/null || fail "valid system Hysteria account was rejected"
  account_uid=0
  assert_fails "non-root system identity" ensure_hysteria_account
  account_uid=1000
  assert_fails "non-root system identity" ensure_hysteria_account
  account_uid=500
  account_gid=0
  account_groups=0
  assert_fails "non-root system identity" ensure_hysteria_account
  account_gid=1000
  account_groups=1000
  assert_fails "non-root system identity" ensure_hysteria_account
  account_gid=500
  account_groups='500 998'
  assert_fails "without supplementary groups" ensure_hysteria_account
  account_groups=500
  group_members=alice
  assert_fails "without supplementary groups" ensure_hysteria_account
)

test_task5_hysteria_account_is_minimal_system_identity
printf 'PASS: Task 5 minimal Hysteria account tests\n'

test_task5_created_hysteria_user_is_recorded_before_validation() (
  local temp_dir account_log group_marker user_marker
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  BACKUP_DIR="$temp_dir/backup"
  RUNTIME_DIR=""
  LOGIN_DEFS_FILE="$temp_dir/login.defs"
  account_log="$temp_dir/accounts.log"
  group_marker="$temp_dir/group-created"
  user_marker="$temp_dir/user-created"
  printf 'SYS_UID_MAX 999\nSYS_GID_MAX 999\n' >"$LOGIN_DEFS_FILE"
  init_backup_metadata
  getent() {
    case "$1 $2" in
      'group hysteria')
        [[ -f "$group_marker" ]] || return 2
        if [[ -f "$user_marker" ]]; then
          printf 'hysteria:x:500:alice\n'
        else
          printf 'hysteria:x:500:\n'
        fi
        ;;
      'passwd hysteria')
        [[ -f "$user_marker" ]] || return 2
        printf 'hysteria:x:500:500::/nonexistent:/usr/sbin/nologin\n'
        ;;
      *) return 2 ;;
    esac
  }
  id() {
    case "$*" in
      hysteria) [[ -f "$user_marker" ]] ;;
      '-u hysteria'|'-g hysteria') [[ -f "$user_marker" ]] && printf '500\n' ;;
      '-gn hysteria') [[ -f "$user_marker" ]] && printf 'hysteria\n' ;;
      '-G hysteria') [[ -f "$user_marker" ]] && printf '500\n' ;;
      *) command id "$@" ;;
    esac
  }
  groupadd() { : >"$group_marker"; }
  useradd() { : >"$user_marker"; }
  assert_fails "without supplementary groups" ensure_hysteria_account
  assert_eq $'hysteria\tcreated\tcreated' "$(cat "$BACKUP_DIR/accounts")" \
    "created account journal before validation"
  systemctl() { :; }
  userdel() { printf 'userdel %s\n' "$*" >>"$account_log"; rm -f "$user_marker"; }
  groupdel() { printf 'groupdel %s\n' "$*" >>"$account_log"; rm -f "$group_marker"; }
  rollback_current_run
  assert_eq $'userdel hysteria\ngroupdel hysteria' "$(cat "$account_log")" \
    "created account rollback order"
  [[ ! -e "$user_marker" && ! -e "$group_marker" ]] || fail "created Hysteria account remained after rollback"
)

test_task5_created_hysteria_user_is_recorded_before_validation
printf 'PASS: Task 5 created Hysteria account validation rollback tests\n'

test_task5_hysteria_account_journal_is_strict() (
  local temp_dir account_log group_marker user_marker target
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  BACKUP_DIR="$temp_dir/backup"
  LOGIN_DEFS_FILE="$temp_dir/login.defs"
  account_log="$temp_dir/accounts.log"
  group_marker="$temp_dir/group-created"
  user_marker="$temp_dir/user-created"
  target="$temp_dir/accounts-target"
  printf 'SYS_UID_MAX 999\nSYS_GID_MAX 999\n' >"$LOGIN_DEFS_FILE"
  init_backup_metadata

  rm -f "$BACKUP_DIR/accounts"
  record_hysteria_account_state preexisting preexisting >/dev/null 2>&1 &&
    fail "missing Hysteria account journal was accepted"
  install -d "$BACKUP_DIR/accounts"
  record_hysteria_account_state preexisting preexisting >/dev/null 2>&1 &&
    fail "non-regular Hysteria account journal was accepted"
  rmdir "$BACKUP_DIR/accounts"
  ln -s "$target" "$BACKUP_DIR/accounts"
  record_hysteria_account_state preexisting preexisting >/dev/null 2>&1 &&
    fail "symlink Hysteria account journal was accepted"
  rm -f "$BACKUP_DIR/accounts"
  : >"$BACKUP_DIR/accounts"
  chmod 0644 "$BACKUP_DIR/accounts"
  record_hysteria_account_state preexisting preexisting >/dev/null 2>&1 &&
    fail "insecure Hysteria account journal mode was accepted"
  chmod 0600 "$BACKUP_DIR/accounts"
  (
    stat() {
      [[ "$1 $2" == '-c %u' ]] && { printf '1\n'; return 0; }
      command stat "$@"
    }
    record_hysteria_account_state preexisting preexisting >/dev/null 2>&1
  ) && fail "non-root Hysteria account journal owner was accepted"

  getent() {
    case "$1 $2" in
      'group hysteria') [[ -f "$group_marker" ]] && printf 'hysteria:x:500:\n' ;;
      'passwd hysteria') [[ -f "$user_marker" ]] && printf 'hysteria:x:500:500::/nonexistent:/usr/sbin/nologin\n' ;;
      *) return 2 ;;
    esac
  }
  id() {
    case "$*" in
      hysteria) [[ -f "$user_marker" ]] ;;
      '-u hysteria'|'-g hysteria') [[ -f "$user_marker" ]] && printf '500\n' ;;
      '-gn hysteria') [[ -f "$user_marker" ]] && printf 'hysteria\n' ;;
      '-G hysteria') [[ -f "$user_marker" ]] && printf '500\n' ;;
      *) command id "$@" ;;
    esac
  }
  groupadd() { : >"$group_marker"; printf 'groupadd\n' >>"$account_log"; }
  useradd() {
    : >"$user_marker"
    rm -f "$BACKUP_DIR/accounts"
    printf 'useradd\n' >>"$account_log"
  }
  userdel() { rm -f "$user_marker"; printf 'userdel\n' >>"$account_log"; }
  groupdel() { rm -f "$group_marker"; printf 'groupdel\n' >>"$account_log"; }
  : >"$BACKUP_DIR/accounts"
  chmod 0600 "$BACKUP_DIR/accounts"
  assert_fails "account journal" ensure_hysteria_account
  [[ ! -e "$user_marker" && ! -e "$group_marker" ]] ||
    fail "journal removal after useradd left a Hysteria account"
  assert_eq $'groupadd\nuseradd\nuserdel\ngroupdel' "$(cat "$account_log")" \
    "journal failure account cleanup order"

  : >"$account_log"
  : >"$BACKUP_DIR/accounts"
  chmod 0600 "$BACKUP_DIR/accounts"
  useradd() {
    : >"$user_marker"
    rm -f "$BACKUP_DIR/accounts"
    ln -s "$target" "$BACKUP_DIR/accounts"
    printf 'useradd\n' >>"$account_log"
  }
  assert_fails "account journal" ensure_hysteria_account
  [[ ! -e "$user_marker" && ! -e "$group_marker" ]] ||
    fail "journal symlink replacement after useradd left a Hysteria account"
  rm -f "$BACKUP_DIR/accounts"

  : >"$account_log"
  : >"$BACKUP_DIR/accounts"
  chmod 0600 "$BACKUP_DIR/accounts"
  write_hysteria_account_record() { return 74; }
  assert_fails "account journal" ensure_hysteria_account
  [[ ! -e "$user_marker" && ! -e "$group_marker" ]] ||
    fail "journal write failure left a Hysteria account"

  : >"$account_log"
  : >"$BACKUP_DIR/accounts"
  chmod 0600 "$BACKUP_DIR/accounts"
  write_hysteria_account_record() { printf '%s\n' "$2" >"$1"; }
  (
    chmod() {
      [[ "$1" == "0600" && "$2" == "$BACKUP_DIR"/.accounts.* ]] && return 75
      command chmod "$@"
    }
    assert_fails "account journal" ensure_hysteria_account
  )
  [[ ! -e "$user_marker" && ! -e "$group_marker" ]] ||
    fail "journal chmod failure left a Hysteria account"

  : >"$account_log"
  : >"$group_marker"
  : >"$user_marker"
  rm -f "$BACKUP_DIR/accounts"
  assert_fails "account journal" ensure_hysteria_account
  [[ -e "$user_marker" && -e "$group_marker" ]] ||
    fail "journal failure removed a preexisting Hysteria account"
  [[ ! -s "$account_log" ]] || fail "preexisting Hysteria account was mutated after journal failure"
)

test_task5_hysteria_account_journal_is_strict
printf 'PASS: Task 5 strict Hysteria account journal tests\n'

test_task5_refuses_every_unproved_hysteria_deployment_before_mutation() (
  local temp_dir vendor_unit mutation_log drop_in_dir path
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  HYSTERIA_BIN="$temp_dir/usr/local/bin/hysteria"
  HYSTERIA_CONFIG="$temp_dir/etc/hysteria/config.yaml"
  HYSTERIA_ACL="$temp_dir/etc/hysteria/acl.txt"
  HYSTERIA_CERT="$temp_dir/etc/hysteria/server.crt"
  HYSTERIA_KEY="$temp_dir/etc/hysteria/server.key"
  HYSTERIA_UNIT="$temp_dir/etc/systemd/system/hysteria-server.service"
  HYSTERIA_OWNERSHIP_MANIFEST="$temp_dir/etc/v2ray-onekey/hysteria.manifest"
  vendor_unit="$temp_dir/usr/lib/systemd/system/hysteria-server.service"
  mutation_log="$temp_dir/mutations.log"
  MODE="direct"
  direct_bundle_ready() { return 0; }
  install_required_packages() { printf 'packages\n' >>"$mutation_log"; }
  install_xray_core() { printf 'xray-installer\n' >>"$mutation_log"; }
  record_service_touch() { printf 'touch:%s\n' "$1" >>"$mutation_log"; }
  begin_transaction() { printf 'transaction\n' >>"$mutation_log"; }

  systemctl() {
    if [[ "$*" == 'show -p FragmentPath --value hysteria-server' ]]; then
      printf '%s\n' "$vendor_unit"
    fi
  }
  assert_fails "Refusing unmanaged Hysteria2" deploy_services
  [[ ! -e "$mutation_log" ]] || fail "loaded third-party Hysteria2 was rejected after mutation"

  systemctl() { return 1; }
  hysteria_vendor_unit_paths() { printf '%s\n' "$vendor_unit"; }
  install -d "$(dirname "$vendor_unit")"
  printf '[Service]\nExecStart=/opt/vendor/hysteria server\n' >"$vendor_unit"
  assert_fails "Refusing unmanaged Hysteria2" validate_managed_destination_ownership

  rm -f "$vendor_unit"
  install -d "$(dirname "$HYSTERIA_CONFIG")"
  printf 'third-party\n' >"$(dirname "$HYSTERIA_CONFIG")/unmanaged.yaml"
  assert_fails "Refusing unmanaged Hysteria2" validate_managed_destination_ownership
  rm -f "$(dirname "$HYSTERIA_CONFIG")/unmanaged.yaml"

  for path in "$HYSTERIA_BIN" "$HYSTERIA_CONFIG" "$HYSTERIA_ACL" "$HYSTERIA_CERT" \
    "$HYSTERIA_KEY" "$HYSTERIA_UNIT"; do
    install -d "$(dirname "$path")"
    case "$path" in
      "$HYSTERIA_CONFIG") printf '%s\n' "$HYSTERIA_CONFIG_MARKER" >"$path" ;;
      "$HYSTERIA_ACL") printf '%s\n' "$HYSTERIA_ACL_MARKER" >"$path" ;;
      "$HYSTERIA_UNIT") printf '%s\n' "$HYSTERIA_UNIT_MARKER" >"$path" ;;
      *) printf 'project-owned-%s\n' "$(basename "$path")" >"$path" ;;
    esac
  done
  write_hysteria_ownership_manifest
  drop_in_dir="$temp_dir/etc/systemd/system/hysteria-server.service.d"
  hysteria_drop_in_directories() { printf '%s\n' "$drop_in_dir"; }
  install -d "$drop_in_dir"
  printf '[Service]\nUser=root\n' >"$drop_in_dir/override.conf"
  systemctl() {
    case "$*" in
      'show -p FragmentPath --value hysteria-server') printf '%s\n' "$HYSTERIA_UNIT" ;;
      'show -p DropInPaths --value hysteria-server') printf '\n' ;;
      *) return 1 ;;
    esac
  }
  assert_fails "Refusing unmanaged Hysteria2" deploy_services
  [[ ! -e "$mutation_log" ]] || fail "filesystem Hysteria2 drop-in was rejected after mutation"

  rm -f "$drop_in_dir/override.conf"
  systemctl() {
    case "$*" in
      'show -p FragmentPath --value hysteria-server') printf '%s\n' "$HYSTERIA_UNIT" ;;
      'show -p DropInPaths --value hysteria-server')
        printf '%s\n' "$drop_in_dir/third-party.conf"
        ;;
      *) return 1 ;;
    esac
  }
  assert_fails "Refusing unmanaged Hysteria2" deploy_services
  [[ ! -e "$mutation_log" ]] || fail "loaded Hysteria2 DropInPaths was rejected after mutation"
)

test_task5_refuses_every_unproved_hysteria_deployment_before_mutation
printf 'PASS: Task 5 third-party Hysteria preflight tests\n'

test_task5_hysteria_directory_transaction_rollback() (
  local temp_dir config_dir path account_log
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  HYSTERIA_BIN="$temp_dir/usr/local/bin/hysteria"
  HYSTERIA_CONFIG="$temp_dir/etc/hysteria/config.yaml"
  HYSTERIA_ACL="$temp_dir/etc/hysteria/acl.txt"
  HYSTERIA_CERT="$temp_dir/etc/hysteria/server.crt"
  HYSTERIA_KEY="$temp_dir/etc/hysteria/server.key"
  HYSTERIA_UNIT="$temp_dir/etc/systemd/system/hysteria-server.service"
  HYSTERIA_OWNERSHIP_MANIFEST="$temp_dir/etc/v2ray-onekey/hysteria.manifest"
  XRAY_CONFIG="$temp_dir/xray/config.json"
  STATE_FILE="$temp_dir/state/state.env"
  NGINX_SITE="$temp_dir/nginx/site.conf"
  RENEWAL_HOOK="$temp_dir/hooks/hook.sh"
  LEGACY_V2RAY_CONFIG="$temp_dir/v2ray/config.json"
  config_dir="$(dirname "$HYSTERIA_CONFIG")"
  account_log="$temp_dir/accounts.log"
  MODE="direct"
  RUNTIME_DIR=""
  systemctl() { :; }
  userdel() { printf 'userdel %s\n' "$*" >>"$account_log"; }
  groupdel() {
    [[ ! -d "$config_dir" || "$(stat -c '%g' "$config_dir")" == "0" ]] ||
      fail "Hysteria directory still referenced the deleted group"
    printf 'groupdel %s\n' "$*" >>"$account_log"
  }

  BACKUP_DIR="$temp_dir/fresh-empty-backup"
  init_backup_metadata
  record_hysteria_directory_state
  while IFS= read -r path; do backup_file "$path"; done < <(hysteria_managed_paths)
  backup_file "$HYSTERIA_OWNERSHIP_MANIFEST"
  printf 'hysteria\tcreated\tcreated\n' >"$BACKUP_DIR/accounts"
  install -d -m 0750 "$config_dir"
  printf 'new managed file\n' >"$HYSTERIA_CONFIG"
  rollback_current_run
  [[ ! -e "$config_dir" ]] || fail "fresh failed install left an empty Hysteria directory"
  grep -Fq 'groupdel hysteria' "$account_log" || fail "fresh failed install did not remove its group"

  : >"$account_log"
  BACKUP_DIR="$temp_dir/fresh-external-backup"
  init_backup_metadata
  record_hysteria_directory_state
  while IFS= read -r path; do backup_file "$path"; done < <(hysteria_managed_paths)
  backup_file "$HYSTERIA_OWNERSHIP_MANIFEST"
  printf 'hysteria\tcreated\tcreated\n' >"$BACKUP_DIR/accounts"
  install -d -m 0750 "$config_dir"
  printf 'new managed file\n' >"$HYSTERIA_CONFIG"
  printf 'external content\n' >"$config_dir/external.keep"
  rollback_current_run
  [[ -f "$config_dir/external.keep" ]] || fail "rollback recursively deleted external Hysteria content"
  [[ ! -e "$HYSTERIA_CONFIG" ]] || fail "rollback retained a current-run Hysteria config"
  assert_eq "0" "$(stat -c '%g' "$config_dir")" "retained Hysteria directory group"
  grep -Fq 'groupdel hysteria' "$account_log" || fail "external content prevented account rollback"

  BACKUP_DIR="$temp_dir/preexisting-backup"
  chmod 0711 "$config_dir"
  chown 12345:12346 "$config_dir"
  init_backup_metadata
  record_hysteria_directory_state
  while IFS= read -r path; do backup_file "$path"; done < <(hysteria_managed_paths)
  backup_file "$HYSTERIA_OWNERSHIP_MANIFEST"
  chmod 0750 "$config_dir"
  chown root:root "$config_dir"
  printf 'new managed file\n' >"$HYSTERIA_CONFIG"
  rollback_current_run
  assert_eq "711" "$(stat -c '%a' "$config_dir")" "preexisting Hysteria directory mode"
  assert_eq "12345" "$(stat -c '%u' "$config_dir")" "preexisting Hysteria directory owner"
  assert_eq "12346" "$(stat -c '%g' "$config_dir")" "preexisting Hysteria directory group"
  [[ -f "$config_dir/external.keep" ]] || fail "preexisting directory content was not preserved"
)

test_task5_hysteria_directory_transaction_rollback
printf 'PASS: Task 5 Hysteria directory rollback tests\n'

test_task5_loaded_hysteria_service_identity() (
  local temp_dir unit_mode="valid"
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  HYSTERIA_CONFIG="/etc/hysteria/config.yaml"
  HYSTERIA_ACL="/etc/hysteria/acl.txt"
  HYSTERIA_CERT="/etc/hysteria/server.crt"
  HYSTERIA_KEY="/etc/hysteria/server.key"
  HYSTERIA_BIN="/usr/local/bin/hysteria"
  HYSTERIA_UNIT="/etc/systemd/system/hysteria-server.service"
  LOGIN_DEFS_FILE="$temp_dir/login.defs"
  printf 'SYS_UID_MAX 999\nSYS_GID_MAX 999\n' >"$LOGIN_DEFS_FILE"
  getent() {
    [[ "$1" == passwd ]] && printf 'hysteria:x:500:500::/nonexistent:/usr/sbin/nologin\n' ||
      printf 'hysteria:x:500:\n'
  }
  id() {
    case "$1" in
      -u|-g) printf '500\n' ;;
      -gn) printf 'hysteria\n' ;;
      -G) printf '500\n' ;;
      *) return 0 ;;
    esac
  }
  systemctl() {
    case "$*" in
      'show -p User --value hysteria-server') printf 'hysteria\n' ;;
      'show -p Group --value hysteria-server') printf 'hysteria\n' ;;
      'show -p MainPID --value hysteria-server') printf '4242\n' ;;
      'cat hysteria-server')
        printf '%s\n' \
          '[Service]' \
          'User=hysteria' \
          'Group=hysteria' \
          'ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml' \
          'AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE'
        [[ "$unit_mode" == "valid" ]] &&
          printf '%s\n' 'CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE'
        printf '%s\n' 'NoNewPrivileges=true'
        ;;
      *) return 1 ;;
    esac
  }
  stat() {
    local path="${@: -1}"
    case "$path" in
      /etc/hysteria/config.yaml|/etc/hysteria/acl.txt|/etc/hysteria/server.crt|/etc/hysteria/server.key)
        printf 'root:hysteria:440\n' ;;
      /etc/hysteria) printf 'root:hysteria:750\n' ;;
      /usr/local/bin/hysteria) printf 'root:root:755\n' ;;
      /etc/systemd/system/hysteria-server.service) printf 'root:root:644\n' ;;
      "$temp_dir/proc/4242") printf 'hysteria:hysteria\n' ;;
      *) return 1 ;;
    esac
  }
  verify_hysteria_service_definition
  unit_mode="missing-capability"
  assert_fails "CapabilityBoundingSet" verify_hysteria_service_definition

  unit_mode="valid"
  HYSTERIA_PROC_ROOT="$temp_dir/proc"
  install -d "$HYSTERIA_PROC_ROOT/4242"
  ln -s "$HYSTERIA_BIN" "$HYSTERIA_PROC_ROOT/4242/exe"
  printf '%s\0%s\0%s\0%s\0' "$HYSTERIA_BIN" server -c "$HYSTERIA_CONFIG" \
    >"$HYSTERIA_PROC_ROOT/4242/cmdline"
  cat >"$HYSTERIA_PROC_ROOT/4242/status" <<'EOF'
Name:	hysteria
Uid:	500	500	500	500
Gid:	500	500	500	500
Groups:	500
CapEff:	0000000000001400
CapBnd:	0000000000001400
CapAmb:	0000000000001400
NoNewPrivs:	1
EOF
  verify_hysteria_runtime_identity
  sed -i 's/Groups:\t500/Groups:\t500 998/' "$HYSTERIA_PROC_ROOT/4242/status"
  assert_fails "supplementary groups" verify_hysteria_runtime_identity
  sed -i 's/Groups:\t500 998/Groups:\t500/' "$HYSTERIA_PROC_ROOT/4242/status"
  sed -i 's/Uid:\t500\t500\t500\t500/Uid:\t1000\t1000\t1000\t1000/' \
    "$HYSTERIA_PROC_ROOT/4242/status"
  assert_fails "runtime UID" verify_hysteria_runtime_identity
  sed -i 's/Uid:\t1000\t1000\t1000\t1000/Uid:\t500\t500\t500\t500/' \
    "$HYSTERIA_PROC_ROOT/4242/status"
  sed -i 's/CapEff:\t0000000000001400/CapEff:\t0000000000001c00/' \
    "$HYSTERIA_PROC_ROOT/4242/status"
  assert_fails "CapEff grants unexpected" verify_hysteria_runtime_identity
)

test_task5_loaded_hysteria_service_identity
printf 'PASS: Task 5 loaded Hysteria service identity tests\n'

test_task5_multi_protocol_readiness_and_cleanup() (
  local temp_dir diagnostics_log calls_log
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  MODE="direct"
  SS_PORT="8388"
  HY2_PORT_RANGE="20000-20100"
  parse_port_range "$HY2_PORT_RANGE"
  LISTENER_WAIT_ATTEMPTS=2
  LISTENER_WAIT_INTERVAL=0
  calls_log="$temp_dir/listener-calls.log"
  systemctl() {
    case "$*" in
      'is-active --quiet xray'|'is-active --quiet hysteria-server') return 0 ;;
      *) return 0 ;;
    esac
  }
  ss() {
    printf '%s\n' "$*" >>"$calls_log"
    case "$*" in
      *'-H -lntp'*':8388'*) printf 'LISTEN 0 128 0.0.0.0:8388 users:(("xray",pid=2,fd=3))\n' ;;
      *'-H -lnup'*':8388'*) printf 'UNCONN 0 0 0.0.0.0:8388 users:(("xray",pid=2,fd=4))\n' ;;
      *'-H -lnup'*':20000'*) printf 'UNCONN 0 0 0.0.0.0:20000 users:(("hysteria",pid=3,fd=5))\n' ;;
    esac
  }
  sleep() { :; }
  verify_started_services
  [[ "$(wc -l <"$calls_log" | tr -d ' ')" -ge 3 ]] ||
    fail "multi-protocol readiness did not inspect every expected listener"

  diagnostics_log="$temp_dir/diagnostics.log"
  systemctl() {
    if [[ "$*" == 'is-active --quiet hysteria-server' ]]; then return 3; fi
    printf 'status %s\n' "$*" >>"$diagnostics_log"
    return 0
  }
  journalctl() { printf 'journal %s\n' "$*" >>"$diagnostics_log"; }
  ss() { printf 'listeners %s\n' "$*" >>"$diagnostics_log"; }
  assert_fails "Multi-protocol readiness timed out" verify_started_services
  grep -Fq 'status status hysteria-server --no-pager --full' "$diagnostics_log" ||
    fail "Hysteria2 status diagnostics missing"
  grep -Fq 'journal -u hysteria-server' "$diagnostics_log" ||
    fail "Hysteria2 journal diagnostics missing"
  grep -Fq 'listeners -H -lntup' "$diagnostics_log" || fail "listener diagnostics missing"

  RUNTIME_DIR="$temp_dir/runtime"
  install -d -m 700 "$RUNTIME_DIR"
  RUN_TIMESTAMP="task5-test"
  printf '%s\n' "$RUN_TIMESTAMP" >"$RUNTIME_DIR/.v2ray-onekey-runtime"
  printf 'staged\n' >"$RUNTIME_DIR/file"
  cleanup_runtime_directory
  [[ ! -e "$RUNTIME_DIR" ]] || fail "successful cleanup left the runtime staging directory"

  BACKUP_DIR="$temp_dir/failure-backup"
  install -d -m 700 "$BACKUP_DIR"
  : >"$BACKUP_DIR/manifest"
  : >"$BACKUP_DIR/services"
  : >"$BACKUP_DIR/firewall-rules"
  : >"$BACKUP_DIR/accounts"
  RUNTIME_DIR="$temp_dir/failure-runtime"
  RUN_TIMESTAMP="task5-failure"
  install -d -m 700 "$RUNTIME_DIR"
  printf '%s\n' "$RUN_TIMESTAMP" >"$RUNTIME_DIR/.v2ray-onekey-runtime"
  printf 'staged\n' >"$RUNTIME_DIR/file"
  systemctl() { :; }
  rollback_current_run
  [[ ! -e "$RUNTIME_DIR" ]] || fail "failed transaction left the runtime staging directory"
)

test_task5_multi_protocol_readiness_and_cleanup
printf 'PASS: Task 5 readiness and cleanup tests\n'

test_task5_hysteria_smoke_uses_independent_udp_port() (
  local temp_dir ss_log smoke_port
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  HY2_PORT_RANGE="49154-49160"
  parse_port_range "$HY2_PORT_RANGE"
  HY2_AUTH="$HY2_TEST_AUTH"
  HY2_OBFS_PASSWORD="$HY2_TEST_OBFS"
  ss_log="$temp_dir/ss.log"
  ss() {
    printf '%s\n' "$*" >>"$ss_log"
    if [[ "$*" == *':49152'* ]]; then
      printf 'UNCONN 0 0 0.0.0.0:49152 users:(("other",pid=9,fd=3))\n'
    fi
  }
  smoke_port="$(select_hysteria_smoke_port)"
  assert_eq "49153" "$smoke_port" "free Hysteria2 smoke port selection"
  grep -Fq 'sport = :49152' "$ss_log" || fail "occupied smoke candidate was not inspected"
  grep -Fq 'sport = :49153' "$ss_log" || fail "free smoke candidate was not inspected"

  render_hysteria_config "$temp_dir/smoke.yaml" "$temp_dir/cert" "$temp_dir/key" \
    "$temp_dir/acl" "$smoke_port"
  grep -Fq 'listen: ":49153"' "$temp_dir/smoke.yaml" ||
    fail "smoke config did not use its single probe port"
  grep -Fq '49154-49160' "$temp_dir/smoke.yaml" &&
    fail "smoke config reused the production port-hopping range"
  return 0
)

test_task5_hysteria_smoke_uses_independent_udp_port
printf 'PASS: Task 5 independent Hysteria smoke port tests\n'

test_task5_cutover_stop_rolls_back_active_enabled_hysteria() (
  local temp_dir service_log
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  BACKUP_DIR="$temp_dir/backup"
  service_log="$temp_dir/services.log"
  RUNTIME_DIR=""
  MODE="direct"
  init_backup_metadata
  printf 'hysteria-server\tactive\tenabled\n' >"$BACKUP_DIR/services"
  project_hysteria_listener_pid() { printf '4242\n'; }
  systemctl() { printf '%s\n' "$*" >>"$service_log"; }

  stop_project_hysteria_for_cutover
  grep -Fqx 'hysteria-server' "$BACKUP_DIR/services-touched" ||
    fail "staging stop did not journal the touched Hysteria2 service"
  rollback_current_run

  [[ "$(grep -n '^stop hysteria-server$' "$service_log" | head -n 1 | cut -d: -f1)" -lt \
    "$(grep -n '^restart hysteria-server$' "$service_log" | cut -d: -f1)" ]] ||
    fail "rollback did not restart the previously active Hysteria2 service"
  grep -Fqx 'enable hysteria-server' "$service_log" ||
    fail "rollback did not restore Hysteria2 enablement"
)

test_task5_cutover_stop_rolls_back_active_enabled_hysteria
printf 'PASS: Task 5 Hysteria cutover-stop rollback tests\n'

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
  BACKUP_DIR="$temp_dir/cloudflare-packages-backup"
  init_backup_metadata
  MODE="cloudflare"
  PKG_MANAGER="apt"
  systemctl() {
    case "$*" in
      'show -p LoadState --value nginx') printf 'loaded\n' ;;
      'show -p ActiveState --value nginx') printf 'inactive\n' ;;
      'show -p UnitFileState --value nginx') printf 'disabled\n' ;;
      *) return 1 ;;
    esac
  }
  install_required_packages
  [[ ! -s "$BACKUP_DIR/services-touched" ]] ||
    fail "unchanged package doubles marked Nginx as touched"
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
  firewall-cmd() {
    [[ "$*" == *'--query-port='* ]] && return 1
    printf 'firewall %s\n' "$*" >>"$firewall_log"
  }
  systemctl() {
    [[ "$1 $2" == 'is-active firewalld' ]] || return 1
    if [[ "$firewalld_state" == "active" ]]; then printf 'active\n'; return 0; fi
    printf 'inactive\n'
    return 3
  }
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
  assert_fails "required runtime rule 2053/tcp" open_firewall_port 2053 tcp
  grep -Eq '(apt-get|dnf|yum).*(remove|erase)' "$SCRIPT" &&
    fail "installer contains package-removal behavior"

  installer_log="$temp_dir/installer.log"
  BACKUP_DIR="$temp_dir/xray-installer-backup"
  init_backup_metadata
  curl() {
    [[ "$*" == *'-LfsS'* && "$*" == *'--connect-timeout 10'* && "$*" == *'--max-time 120'* ]] ||
      fail "Xray installer download lacks finite timeout flags"
    printf 'official-installer-body'
  }
  bash() {
    printf '%s\n' "$*" >"$installer_log"
  }
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

test_task6_real_preflight_order_and_zero_mutation() (
  local temp_dir event_log mutation_log status
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  event_log="$temp_dir/events.log"
  mutation_log="$temp_dir/mutations.log"
  event() { printf '%s\n' "$1" >>"$event_log"; }
  reset_options
  MODE="cloudflare"
  INTERNAL_WS_PORT="31001"
  require_mode_ready() { event ready; }
  validate_managed_destination_ownership() { event ownership; }
  validate_cloudflare_preflight() { event cf-domain; }
  check_public_port_listeners() { event public-ports; }
  check_internal_ws_port_listener() { event internal-port; }
  begin_transaction() { event backup; }
  install_mode_dependencies() { event packages; }
  generate_mode_credentials() { event values; }
  stage_mode_configurations() { event stage; }
  validate_staged_configurations() { event validate; }
  stop_mode_services() { event stop; }
  install_staged_configurations() { event install; }
  start_mode_services() { event start; }
  verify_mode_services() { event readiness; }
  save_state() { event state; }
  configure_firewall() { event firewall; }
  verify_cloudflare_when_enabled() { event edge; }
  print_deployment_summary() { event summary; }
  complete_transaction() { event commit; }

  deploy_services
  assert_eq \
    "ready ownership cf-domain public-ports internal-port backup packages values stage validate stop install start readiness state firewall edge summary commit" \
    "$(paste -sd' ' "$event_log")" "real preflight order"

  : >"$event_log"
  validate_cloudflare_preflight() { event cf-domain-failed; return 71; }
  begin_transaction() { printf 'backup\n' >>"$mutation_log"; }
  install_mode_dependencies() { printf 'packages\n' >>"$mutation_log"; }
  stop_mode_services() { printf 'service\n' >>"$mutation_log"; }
  set +e
  ( set -Eeuo pipefail; deploy_services ) >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "failed preflight unexpectedly reached deployment"
  [[ ! -e "$mutation_log" ]] || fail "failed preflight caused mutations: $(cat "$mutation_log")"
  assert_eq "ready ownership cf-domain-failed" "$(paste -sd' ' "$event_log")" \
    "failed preflight event boundary"
)

test_task6_real_preflight_order_and_zero_mutation
printf 'PASS: Task 6 real preflight boundary tests\n'

test_task6_cloudflare_preflight_temp_cleanup() (
  local temp_dir status
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  TMPDIR="$temp_dir"
  MODE="cloudflare"
  DOMAIN="vpn.example.com"
  download_cloudflare_ranges() {
    install -d -m 700 "$(dirname "$CLOUDFLARE_IPV4_FILE")"
    printf '104.16.0.0/13\n' >"$CLOUDFLARE_IPV4_FILE"
    printf '2606:4700::/32\n' >"$CLOUDFLARE_IPV6_FILE"
  }
  validate_cloudflare_domain() { return 73; }

  set +e
  validate_cloudflare_preflight >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "invalid Cloudflare preflight unexpectedly passed"
  [[ -z "$(find "$temp_dir" -mindepth 1 -print -quit)" ]] ||
    fail "Cloudflare preflight left temporary range data"
)

test_task6_cloudflare_preflight_temp_cleanup
printf 'PASS: Task 6 Cloudflare preflight cleanup tests\n'

test_task6_deployment_stage_order() (
  local temp_dir order_log expected mode
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  order_log="$temp_dir/order.log"
  event() { printf '%s\n' "$1" >>"$order_log"; }
  prepare_fresh_inputs() { event preflight; }
  begin_transaction() { event backup; }
  install_mode_dependencies() { event packages; }
  generate_mode_credentials() { event values; }
  stage_mode_configurations() { event stage; }
  validate_staged_configurations() { event validate; }
  stop_mode_services() { event stop; }
  install_staged_configurations() { event install; }
  start_mode_services() { event start; }
  verify_mode_services() { event readiness; }
  save_state() { event state; }
  configure_firewall() { event firewall; }
  verify_cloudflare_when_enabled() { event edge; }
  print_deployment_summary() { event summary; }
  complete_transaction() { event commit; }
  expected="preflight backup packages values stage validate stop install start readiness state firewall edge summary commit"

  for mode in direct cloudflare full; do
    : >"$order_log"
    MODE="$mode"
    deploy_services
    assert_eq "$expected" "$(paste -sd' ' "$order_log")" "$mode deployment stage order"
  done
)

test_task6_deployment_stage_order
printf 'PASS: Task 6 deployment stage ordering tests\n'

test_task6_stage_mode_isolation() (
  local temp_dir event_log mode
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  event_log="$temp_dir/events.log"
  event() { printf '%s\n' "$1" >>"$event_log"; }
  reset_options
  RUNTIME_DIR="$temp_dir/run"
  install -d "$RUNTIME_DIR"
  ACME_WEBROOT="$temp_dir/acme"
  RENEWAL_HOOK="$temp_dir/renewal-hook"
  HY2_PORT_RANGE="20000-20100"
  SS_PORT="8388"

  download_cloudflare_ranges() { event cf-ranges; }
  validate_cloudflare_domain() { event cf-domain; }
  check_public_port_listeners() { event public-ports; }
  check_internal_ws_port_listener() {
    if mode_has_cloudflare; then
      event cf-internal-port
    fi
  }
  render_xray_config() { event xray-render; }
  stage_hysteria_bundle() { event hy2-stage; }
  xray() { event xray-validate; }
  validate_staged_nginx_config() { event "cf-staged-validate:$2"; }
  validate_loaded_runtime_values() { event values-validate; }
  release_legacy_nginx_listeners() { event listener-release; }
  render_nginx_site() { event "cf-render:$2"; }
  install_nginx_config_atomically() { event cf-install; }
  activate_nginx_config() { event cf-activate; }
  request_certificate() { event cf-certificate; }
  nginx() { event cf-nginx-test; }
  create_renewal_hook() { event cf-renewal; }
  install_validated_xray_config() { event xray-install; }
  ensure_hysteria_account() { event hy2-account; }
  install_validated_hysteria_binary() { event hy2-binary; }
  install_hysteria_runtime_files() { event hy2-files; }
  write_hysteria_ownership_manifest() { event hy2-manifest; }
  verify_hysteria_service_definition() { event hy2-unit-verify; }
  run_service_mutation() { event "service:$1:$2"; }
  systemctl() { event "systemctl:$*"; }
  check_cloudflare_edge() { event cf-edge; }

  for mode in direct cloudflare full; do
    : >"$event_log"
    MODE="$mode"
    event stage-boundary
    stage_mode_configurations
    event validate-boundary
    validate_staged_configurations
    event stop-boundary
    event install-boundary
    install_staged_configurations
    start_mode_services
    verify_cloudflare_when_enabled
    case "$mode" in
      direct)
        ! grep -q '^cf-' "$event_log" || fail "direct stages touched Cloudflare: $(tr '\n' ',' <"$event_log")"
        grep -Fqx 'hy2-stage' "$event_log" || fail "direct stages omitted Hysteria2"
        grep -Fqx 'service:hysteria-server:restart' "$event_log" || fail "direct stages did not start Hysteria2"
        ;;
      cloudflare)
        ! grep -q '^hy2-' "$event_log" || fail "Cloudflare stages touched Hysteria2: $(tr '\n' ',' <"$event_log")"
        ! grep -q 'service:hysteria-server' "$event_log" || fail "Cloudflare stages started Hysteria2"
        grep -Fqx 'cf-certificate' "$event_log" || fail "Cloudflare stages omitted certificate flow"
        grep -Fqx 'cf-edge' "$event_log" || fail "Cloudflare stages omitted edge verification"
        assert_eq "2" "$(grep -c '^cf-render:' "$event_log")" "Cloudflare staged Nginx render count"
        assert_eq "2" "$(grep -c '^cf-staged-validate:' "$event_log")" "Cloudflare staged Nginx validation count"
        [[ "$(grep -n '^cf-render:' "$event_log" | tail -n 1 | cut -d: -f1)" -lt \
          "$(grep -n '^validate-boundary$' "$event_log" | cut -d: -f1)" ]] ||
          fail "Cloudflare Nginx rendering occurred after the stage boundary"
        [[ "$(grep -n '^cf-staged-validate:' "$event_log" | tail -n 1 | cut -d: -f1)" -lt \
          "$(grep -n '^stop-boundary$' "$event_log" | cut -d: -f1)" ]] ||
          fail "Cloudflare Nginx validation occurred after the stop boundary"
        ;;
      full)
        grep -Fqx 'hy2-stage' "$event_log" || fail "full stages omitted Hysteria2"
        grep -Fqx 'cf-certificate' "$event_log" || fail "full stages omitted Cloudflare certificate flow"
        grep -Fqx 'service:hysteria-server:restart' "$event_log" || fail "full stages did not start Hysteria2"
        grep -Fqx 'cf-edge' "$event_log" || fail "full stages omitted edge verification"
        [[ "$(grep -n '^cf-render:' "$event_log" | tail -n 1 | cut -d: -f1)" -lt \
          "$(grep -n '^stop-boundary$' "$event_log" | cut -d: -f1)" ]] ||
          fail "full mode first rendered Nginx after stopping services"
        ;;
    esac
  done
)

test_task6_stage_mode_isolation
printf 'PASS: Task 6 stage mode isolation tests\n'

test_task6_staged_nginx_validation_is_isolated() (
  local temp_dir nginx_log initial final original_final candidate config prefix status
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  RUNTIME_DIR="$temp_dir/runtime"
  install -d -m 700 "$RUNTIME_DIR"
  DOMAIN="vpn.example.com"
  CLOUDFLARE_PORT="8443"
  INTERNAL_WS_PORT="31001"
  WS_PATH="/staged-validation"
  ACME_WEBROOT="$temp_dir/acme"
  initial="$RUNTIME_DIR/nginx-initial.conf"
  final="$RUNTIME_DIR/nginx-final.conf"
  nginx_log="$temp_dir/nginx.log"
  render_nginx_site "$initial" initial
  render_nginx_site "$final" final
  original_final="$(cat "$final")"

  nginx() {
    [[ "$1" == "-t" && "$2" == "-p" && "$4" == "-c" ]] ||
      fail "staged Nginx validation did not use isolated -t/-p/-c: $*"
    prefix="${3%/}"
    config="$5"
    [[ "$prefix" == "$RUNTIME_DIR"/nginx-validate.* ]] || fail "Nginx validation prefix escaped runtime"
    [[ "$config" == "$prefix/nginx.conf" ]] || fail "Nginx validation used an unexpected config"
    candidate="$(awk '$1 == "include" { value=$2; gsub(/[";]/, "", value); print value }' "$config")"
    [[ -f "$candidate" ]] || fail "isolated Nginx candidate is missing"
    grep -Fq 'this_directive_is_invalid' "$candidate" && return 1
    if grep -Fq 'listen 8443 ssl;' "$candidate"; then
      grep -Fq '/etc/letsencrypt/' "$candidate" &&
        fail "staged final validation referenced production certificates"
    fi
    printf '%s\n' "$*" >>"$nginx_log"
  }

  validate_staged_nginx_config "$initial" initial
  validate_staged_nginx_config "$final" final
  assert_eq "2" "$(wc -l <"$nginx_log" | tr -d ' ')" "isolated Nginx syntax test count"
  assert_eq "$original_final" "$(cat "$final")" "staged final config mutation"
  [[ -z "$(find "$RUNTIME_DIR" -maxdepth 1 -type d -name 'nginx-validate.*' -print -quit)" ]] ||
    fail "Nginx validation left an isolated prefix"

  printf '\nthis_directive_is_invalid;\n' >>"$initial"
  set +e
  validate_staged_nginx_config "$initial" initial >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "invalid staged Nginx syntax unexpectedly passed"
)

test_task6_staged_nginx_validation_is_isolated
printf 'PASS: Task 6 isolated Nginx validation tests\n'

test_task6_direct_without_project_nginx_has_zero_nginx_calls() (
  local temp_dir command_log
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  MODE="direct"
  NGINX_SITE="$temp_dir/nginx/v2ray-onekey.conf"
  RENEWAL_HOOK="$temp_dir/hooks/v2ray-onekey-nginx.sh"
  BACKUP_DIR="$temp_dir/backup"
  command_log="$temp_dir/commands.log"
  init_backup_metadata
  legacy_nginx_config_paths() { :; }
  command() { printf 'command %s\n' "$*" >>"$command_log"; return 127; }
  nginx() { printf 'nginx %s\n' "$*" >>"$command_log"; return 1; }
  systemctl() { printf 'systemctl %s\n' "$*" >>"$command_log"; return 1; }

  release_legacy_nginx_listeners
  [[ ! -e "$command_log" ]] || fail "unrelated Nginx was touched during direct cleanup: $(cat "$command_log")"

  query_service_state() {
    printf '%s\n' "$1" >>"$command_log"
    printf 'inactive\tdisabled\n'
  }
  record_service_states
  grep -Fqx nginx "$command_log" && fail "direct transaction inspected unrelated Nginx service state"
  return 0
)

test_task6_direct_without_project_nginx_has_zero_nginx_calls
printf 'PASS: Task 6 unrelated Nginx isolation tests\n'

test_task6_cloudflare_transition_retires_project_hysteria() (
  local temp_dir service_log
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  service_log="$temp_dir/services.log"
  reset_options
  MODE="cloudflare"
  service_was_active() { [[ "$1" == "hysteria-server" ]]; }
  project_hysteria_listener_pid() { printf '4242\n'; }
  run_service_mutation() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >>"$service_log"; }
  stop_mode_services
  grep -Fqx 'hysteria-server stop ' "$service_log" ||
    fail "Cloudflare transition did not stop the project Hysteria2 service"

  : >"$service_log"
  hysteria_deployment_is_strictly_project_owned() { return 0; }
  verify_started_services() { :; }
  disable_legacy_v2ray_after_success() { :; }
  verify_mode_services
  grep -Fqx 'hysteria-server disable --now' "$service_log" ||
    fail "Cloudflare transition did not disable the project Hysteria2 service"
)

test_task6_cloudflare_transition_retires_project_hysteria
printf 'PASS: Task 6 Cloudflare transition tests\n'

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

test_task6_mode_specific_output() (
  reset_options
  MODE="full"
  DOMAIN="vpn.example.com"
  CLOUDFLARE_PORT="2053"
  CLOUDFLARE_UUID="22222222-2222-4222-8222-222222222222"
  WS_PATH="/saved-path"
  SERVER_ADDRESS="2001:db8::10"
  HY2_PORT_RANGE="20000-20100"
  HY2_AUTH="$HY2_TEST_AUTH"
  HY2_OBFS_PASSWORD="$HY2_TEST_OBFS"
  HY2_SNI="0123456789abcdef.invalid"
  HY2_CERT_PIN="AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA"
  SS_PORT="8388"
  SS_METHOD="2022-blake3-aes-128-gcm"
  SS_KEY="$SS_TEST_KEY"
  STATE_FILE="/etc/v2ray-onekey/state.env"
  BACKUP_DIR="/var/backups/v2ray-onekey/test"
  local output cloudflare_line hysteria_line shadowsocks_line
  output="$(print_deployment_summary)"
  [[ "$output" == *'Cloudflare entry: VLESS + WebSocket + TLS'* ]] || fail "full output lacks Cloudflare label"
  [[ "$output" == *'@vpn.example.com:2053'* ]] || fail "full output omits the Cloudflare link"
  [[ "$output" == *'Hysteria2 entry: Salamander + pinned certificate'* ]] || fail "full output lacks Hysteria2 label"
  [[ "$output" == *'hysteria2://'*'@[2001:db8::10]:20000-20100/'* ]] || fail "full output omits IPv6 Hysteria2 link"
  [[ "$output" == *'Shadowsocks entry: 2022-blake3-aes-128-gcm'* ]] || fail "full output lacks Shadowsocks label"
  [[ "$output" == *'ss://'*'@[2001:db8::10]:8388#'* ]] || fail "full output omits IPv6 Shadowsocks link"
  [[ "$output" != *'REALITY'* ]] || fail "full output exposes retired protocol behavior"
  cloudflare_line="$(grep -n '^vless://' <<<"$output" | cut -d: -f1)"
  hysteria_line="$(grep -n '^hysteria2://' <<<"$output" | cut -d: -f1)"
  shadowsocks_line="$(grep -n '^ss://' <<<"$output" | cut -d: -f1)"
  (( cloudflare_line < hysteria_line && hysteria_line < shadowsocks_line )) ||
    fail "full output link order is not Cloudflare, Hysteria2, Shadowsocks"
  [[ "$output" == *'Diagnostics: systemctl status xray hysteria-server; journalctl -u xray -u hysteria-server -e; nginx -t'* ]] ||
    fail "full diagnostics omit an active service"
  [[ "$output" == *'Cloud security group: TCP 80,2053,8388 and UDP 8388,20000-20100'* ]] ||
    fail "full cloud security group guidance is incomplete"
  assert_eq $'TCP 80\nTCP 2053\nTCP 8388\nUDP 8388\nUDP 20000-20100' \
    "$(required_public_ports)" "full required public ports"
  [[ "$output" == *'only the Cloudflare path avoids direct client connections to the server IP'* ]] ||
    fail "full output lacks direct-IP warning"

  MODE="direct"
  output="$(print_deployment_summary)"
  [[ "$output" != *'vless://'* ]] || fail "direct output contains a Cloudflare link"
  [[ "$output" == *'hysteria2://'* && "$output" == *'ss://'* ]] || fail "direct output omits direct links"
  [[ "$output" == *'Diagnostics: systemctl status xray hysteria-server; journalctl -u xray -u hysteria-server -e'* ]] ||
    fail "direct diagnostics are incomplete"
  [[ "$output" != *'nginx -t'* ]] || fail "direct diagnostics contain Nginx"
  [[ "$output" == *'Cloud security group: TCP 8388 and UDP 8388,20000-20100'* ]] ||
    fail "direct cloud security group guidance is incomplete"
  assert_eq $'TCP 8388\nUDP 8388\nUDP 20000-20100' \
    "$(required_public_ports)" "direct required public ports"

  MODE="cloudflare"
  output="$(print_deployment_summary)"
  [[ "$output" == *'Cloudflare entry:'* && "$output" == *'@vpn.example.com:2053'* ]] || fail "Cloudflare output labels are wrong"
  ! grep -qE '^(hysteria2|ss)://' <<<"$output" || fail "Cloudflare-only output contains direct links"
  [[ "$output" == *'Diagnostics: systemctl status xray; journalctl -u xray -e; nginx -t'* ]] ||
    fail "Cloudflare diagnostics are wrong"
  [[ "$output" == *'Cloud security group: TCP 80,2053'* ]] || fail "Cloudflare ports are wrong"
  [[ "$output" != *'UDP '* && "$output" != *'8388'* ]] || fail "Cloudflare-only output contains direct ports"
  assert_eq $'TCP 80\nTCP 2053' "$(required_public_ports)" "Cloudflare required public ports"
)

test_task6_mode_specific_output
printf 'PASS: Task 6 mode-specific output tests\n'

printf 'PASS: mode and validation tests\n'
