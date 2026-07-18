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
