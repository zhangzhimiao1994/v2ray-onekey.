#!/usr/bin/env bash

APP_NAME="v2ray-onekey"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
STATE_FILE="${STATE_FILE:-/etc/v2ray-onekey/state.env}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/v2ray-onekey}"
NGINX_SITE="${NGINX_SITE:-/etc/nginx/conf.d/v2ray-onekey.conf}"
RENEWAL_HOOK="${RENEWAL_HOOK:-/etc/letsencrypt/renewal-hooks/deploy/v2ray-onekey-nginx.sh}"
LEGACY_V2RAY_CONFIG="${LEGACY_V2RAY_CONFIG:-/usr/local/etc/v2ray/config.json}"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
DEFAULT_REALITY_TARGET="www.microsoft.com:443"
CLOUDFLARE_CONNECT_TIMEOUT="${CLOUDFLARE_CONNECT_TIMEOUT:-10}"
CLOUDFLARE_MAX_TIME="${CLOUDFLARE_MAX_TIME:-30}"
TRANSACTION_ACTIVE="0"

log() { printf '\033[1;32m[%s]\033[0m %s\n' "$APP_NAME" "$*"; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$APP_NAME" "$*"; }
die() { printf '\033[1;31m[%s]\033[0m %s\n' "$APP_NAME" "$*" >&2; exit 1; }

reset_options() {
  MODE=""
  DOMAIN=""
  EMAIL=""
  REALITY_PORT=""
  CLOUDFLARE_PORT=""
  INTERNAL_WS_PORT=""
  REALITY_UUID=""
  CLOUDFLARE_UUID=""
  REALITY_PRIVATE_KEY=""
  REALITY_PUBLIC_KEY=""
  REALITY_SHORT_ID=""
  REALITY_TARGET="$DEFAULT_REALITY_TARGET"
  WS_PATH=""
  ROTATE="0"
  ALLOW_BITTORRENT="0"
  CLI_MODE_SET="0"
  CLI_DOMAIN_SET="0"
  CLI_EMAIL_SET="0"
  CLI_REALITY_PORT_SET="0"
  CLI_CLOUDFLARE_PORT_SET="0"
  CLI_REALITY_TARGET_SET="0"
  CLI_REALITY_UUID_SET="0"
  CLI_CLOUDFLARE_UUID_SET="0"
  CLI_WS_PATH_SET="0"
  CLI_ALLOW_BITTORRENT_SET="0"
}

valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

normalize_port() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  while [[ "$port" == 0* ]]; do
    port="${port#0}"
  done
  printf '%s\n' "${port:-0}"
}

valid_port() {
  local port=""
  port="$(normalize_port "${1:-}")" || return 1
  [[ ${#port} -le 5 ]] || return 1
  (( 10#$port >= 1 && 10#$port <= 65535 ))
}

valid_cloudflare_port() {
  local port=""
  port="$(normalize_port "${1:-}")" || return 1
  case "$port" in
    443|2053|2083|2087|2096|8443) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_domain() {
  printf '%s\n' "${1,,}"
}

valid_ipv4() {
  local address="${1:-}"
  local octet=""
  local -a octets=()
  [[ "$address" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  octets=("${BASH_REMATCH[@]:1}")
  for octet in "${octets[@]}"; do
    octet="$(normalize_port "$octet")" || return 1
    [[ ${#octet} -le 3 ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
}

valid_reality_target() {
  local target="${1:-}"
  local hostname=""
  local port=""
  [[ "$target" == *:* ]] || return 1
  hostname="${target%:*}"
  port="${target##*:}"
  valid_domain "$hostname" || valid_ipv4 "$hostname" || return 1
  valid_port "$port"
}

mode_needs_domain() {
  [[ "$MODE" == "cloudflare" || "$MODE" == "dual" ]]
}

mode_has_reality() {
  [[ "$MODE" == "reality" || "$MODE" == "dual" ]]
}

mode_has_cloudflare() {
  [[ "$MODE" == "cloudflare" || "$MODE" == "dual" ]]
}

resolve_default_ports() {
  case "$MODE" in
    reality)
      REALITY_PORT="${REALITY_PORT:-443}"
      CLOUDFLARE_PORT=""
      ;;
    cloudflare)
      REALITY_PORT=""
      CLOUDFLARE_PORT="${CLOUDFLARE_PORT:-443}"
      ;;
    dual)
      REALITY_PORT="${REALITY_PORT:-443}"
      CLOUDFLARE_PORT="${CLOUDFLARE_PORT:-8443}"
      ;;
    *) die "Mode must be reality, cloudflare, or dual" ;;
  esac
}

choose_mode() {
  local choice=""
  printf '%s\n' "1) Direct only: VLESS + REALITY + XTLS Vision"
  printf '%s\n' "2) Cloudflare only: VLESS + WebSocket + TLS"
  printf '%s\n' "3) Dual entry (recommended)"
  read -r -p "Select mode [3]: " choice
  case "${choice:-3}" in
    1) MODE="reality" ;;
    2) MODE="cloudflare" ;;
    3) MODE="dual" ;;
    *) die "Invalid menu choice: $choice" ;;
  esac
}

usage() {
  cat <<'USAGE'
Usage:
  sudo bash v2ray-onekey.sh [options]

Options:
  --mode reality|cloudflare|dual
  --domain DOMAIN
  --email EMAIL
  --reality-port PORT
  --cloudflare-port PORT
  --reality-target HOST:PORT
  --reality-uuid UUID
  --cloudflare-uuid UUID
  --ws-path /PATH
  --rotate
  --allow-bittorrent
  -h, --help
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        [[ $# -ge 2 && -n "$2" ]] || die "--mode requires a value"
        MODE="$2"
        CLI_MODE_SET="1"
        [[ "$MODE" == "reality" || "$MODE" == "cloudflare" || "$MODE" == "dual" ]] ||
          die "--mode must be reality, cloudflare, or dual"
        shift 2
        ;;
      --domain)
        [[ $# -ge 2 && -n "$2" ]] || die "--domain requires a value"
        DOMAIN="$2"
        CLI_DOMAIN_SET="1"
        shift 2
        ;;
      --email)
        [[ $# -ge 2 && -n "$2" ]] || die "--email requires a value"
        EMAIL="$2"
        CLI_EMAIL_SET="1"
        shift 2
        ;;
      --reality-port)
        [[ $# -ge 2 && -n "$2" ]] || die "--reality-port requires a value"
        REALITY_PORT="$2"
        CLI_REALITY_PORT_SET="1"
        shift 2
        ;;
      --cloudflare-port)
        [[ $# -ge 2 && -n "$2" ]] || die "--cloudflare-port requires a value"
        CLOUDFLARE_PORT="$2"
        CLI_CLOUDFLARE_PORT_SET="1"
        shift 2
        ;;
      --reality-target)
        [[ $# -ge 2 && -n "$2" ]] || die "--reality-target requires a value"
        REALITY_TARGET="$2"
        CLI_REALITY_TARGET_SET="1"
        shift 2
        ;;
      --reality-uuid)
        [[ $# -ge 2 && -n "$2" ]] || die "--reality-uuid requires a value"
        REALITY_UUID="$2"
        CLI_REALITY_UUID_SET="1"
        shift 2
        ;;
      --cloudflare-uuid)
        [[ $# -ge 2 && -n "$2" ]] || die "--cloudflare-uuid requires a value"
        CLOUDFLARE_UUID="$2"
        CLI_CLOUDFLARE_UUID_SET="1"
        shift 2
        ;;
      --ws-path)
        [[ $# -ge 2 && -n "$2" ]] || die "--ws-path requires a value"
        WS_PATH="$2"
        CLI_WS_PATH_SET="1"
        shift 2
        ;;
      --rotate)
        ROTATE="1"
        shift
        ;;
      --allow-bittorrent)
        ALLOW_BITTORRENT="1"
        CLI_ALLOW_BITTORRENT_SET="1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

select_mode() {
  [[ -n "$MODE" ]] && return 0

  if [[ -t 0 ]]; then
    choose_mode
  else
    die "--mode is required for non-interactive use. Example: sudo bash v2ray-onekey.sh --mode dual --domain vpn.example.com --email admin@example.com"
  fi
}

valid_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

validate_options() {
  resolve_default_ports

  if mode_needs_domain; then
    [[ -n "$DOMAIN" ]] || die "--domain is required for $MODE mode"
    [[ -n "$EMAIL" ]] || die "--email is required for $MODE mode"
  fi

  [[ -z "$DOMAIN" ]] || valid_domain "$DOMAIN" || die "Invalid domain: $DOMAIN"
  [[ -z "$DOMAIN" ]] || DOMAIN="$(normalize_domain "$DOMAIN")"

  if mode_has_reality; then
    valid_port "$REALITY_PORT" || die "Invalid REALITY port: $REALITY_PORT"
    REALITY_PORT="$(normalize_port "$REALITY_PORT")"
    valid_reality_target "$REALITY_TARGET" || die "Invalid REALITY target: $REALITY_TARGET (expected HOST:PORT)"
  fi
  if mode_has_cloudflare; then
    valid_cloudflare_port "$CLOUDFLARE_PORT" || die "Unsupported Cloudflare port: $CLOUDFLARE_PORT"
    CLOUDFLARE_PORT="$(normalize_port "$CLOUDFLARE_PORT")"
  fi
  if [[ "$MODE" == "dual" && "$REALITY_PORT" == "$CLOUDFLARE_PORT" ]]; then
    die "REALITY and Cloudflare public ports must be different in dual mode"
  fi

  [[ -z "$REALITY_UUID" ]] || valid_uuid "$REALITY_UUID" || die "Invalid REALITY UUID: $REALITY_UUID"
  [[ -z "$CLOUDFLARE_UUID" ]] || valid_uuid "$CLOUDFLARE_UUID" || die "Invalid Cloudflare UUID: $CLOUDFLARE_UUID"
  [[ -z "$WS_PATH" ]] || valid_ws_path "$WS_PATH" ||
    die "WebSocket path must use / followed by A-Z, a-z, 0-9, ., _, ~, or -"
}

STATE_KEYS=(
  MODE DOMAIN EMAIL REALITY_PORT CLOUDFLARE_PORT INTERNAL_WS_PORT
  REALITY_UUID CLOUDFLARE_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY
  REALITY_SHORT_ID REALITY_TARGET WS_PATH ALLOW_BITTORRENT
)

state_key_allowed() {
  local key="$1"
  local allowed=""
  for allowed in "${STATE_KEYS[@]}"; do
    [[ "$key" == "$allowed" ]] && return 0
  done
  return 1
}

state_value_is_shell_escaped() {
  python3 - "$1" <<'PY'
import sys

value = sys.argv[1]
safe = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
index = 0
while index < len(value):
    character = value[index]
    if character in safe:
        index += 1
    elif character == "\\":
        index += 2
    elif value.startswith("''", index):
        index += 2
    elif value.startswith("$'", index):
        index += 2
        while index < len(value):
            if value[index] == "\\":
                index += 2
            elif value[index] == "'":
                index += 1
                break
            else:
                index += 1
        else:
            raise SystemExit(1)
    else:
        raise SystemExit(1)
    if index > len(value):
        raise SystemExit(1)
PY
}

validate_loaded_runtime_values() {
  if mode_has_reality; then
    valid_uuid "$REALITY_UUID" || die "Invalid REALITY UUID in state"
    valid_x25519_key "$REALITY_PRIVATE_KEY" || die "Invalid REALITY private key in state"
    valid_x25519_key "$REALITY_PUBLIC_KEY" || die "Invalid REALITY public key in state"
    valid_reality_short_id "$REALITY_SHORT_ID" || die "Invalid REALITY short ID in state"
  else
    [[ -z "$REALITY_UUID" && -z "$REALITY_PRIVATE_KEY" && -z "$REALITY_PUBLIC_KEY" && -z "$REALITY_SHORT_ID" ]] ||
      die "Inactive REALITY state must not contain credentials"
  fi

  if mode_has_cloudflare; then
    valid_uuid "$CLOUDFLARE_UUID" || die "Invalid Cloudflare UUID in state"
    valid_port "$INTERNAL_WS_PORT" || die "Invalid internal WebSocket port: $INTERNAL_WS_PORT"
    [[ "$INTERNAL_WS_PORT" != "$REALITY_PORT" && "$INTERNAL_WS_PORT" != "$CLOUDFLARE_PORT" ]] ||
      die "Internal WebSocket port must not match a public port"
    valid_ws_path "$WS_PATH" || die "WebSocket path must start with / and contain no whitespace"
  else
    [[ -z "$CLOUDFLARE_UUID" && -z "$INTERNAL_WS_PORT" && -z "$WS_PATH" ]] ||
      die "Inactive Cloudflare state must not contain credentials"
  fi
}

valid_x25519_key() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{43}$ ]]
}

valid_reality_short_id() {
  [[ "$1" =~ ^[A-Fa-f0-9]{2,16}$ ]] && (( ${#1} % 2 == 0 ))
}

valid_ws_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._~\-]+$ ]]
}

save_state() (
  local state_dir state_name temp_state key
  state_dir="$(dirname "$STATE_FILE")"
  state_name="$(basename "$STATE_FILE")"
  install -d -m 700 "$state_dir"
  chmod 700 "$state_dir"
  temp_state="$(mktemp "$state_dir/.${state_name}.XXXXXX")"
  trap 'rm -f -- "$temp_state"' EXIT
  for key in "${STATE_KEYS[@]}"; do
    printf '%s=%q\n' "$key" "${!key}" >>"$temp_state"
  done
  chmod 600 "$temp_state"
  mv -f -- "$temp_state" "$STATE_FILE"
)

load_state() {
  local owner mode line key value
  local -A seen=()
  [[ -f "$STATE_FILE" ]] || die "State file does not exist: $STATE_FILE"
  owner="$(stat -c '%u' "$STATE_FILE")" || die "Unable to inspect state file: $STATE_FILE"
  mode="$(stat -c '%a' "$STATE_FILE")" || die "Unable to inspect state file: $STATE_FILE"
  (( (8#$mode & 0077) == 0 )) || die "State file must not be group or world writable"
  if [[ "$owner" != "0" ]]; then
    [[ "${V2RAY_ONEKEY_SOURCE_ONLY:-0}" == "1" && "$owner" == "$(id -u)" ]] ||
      die "State file must be owned by root"
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || die "Malformed state assignment"
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    state_key_allowed "$key" || die "State contains unexpected assignment: $key"
    [[ -z "${seen[$key]:-}" ]] || die "State contains duplicate assignment: $key"
    state_value_is_shell_escaped "$value" || die "Malformed state value for $key"
    seen["$key"]=1
  done <"$STATE_FILE"
  for key in "${STATE_KEYS[@]}"; do
    [[ "${seen[$key]:-}" == "1" ]] || die "State is missing assignment: $key"
  done

  # The allowlist and shell-escape parser above make these assignments inert data.
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  ROTATE="0"
  validate_options
  validate_loaded_runtime_values
}

read_x25519_keypair() {
  local output private_key public_key
  output="$(xray x25519)" || die "Unable to generate REALITY x25519 key pair"
  private_key="$(awk -F: '/^Private key:/{sub(/^[[:space:]]*/, "", $2); print $2; exit}' <<<"$output")"
  public_key="$(awk -F: '/^Password:/{sub(/^[[:space:]]*/, "", $2); print $2; exit}' <<<"$output")"
  [[ -n "$public_key" ]] ||
    public_key="$(awk -F: '/^Public key:/{sub(/^[[:space:]]*/, "", $2); print $2; exit}' <<<"$output")"
  [[ -n "$private_key" && -n "$public_key" ]] || die "Unable to parse xray x25519 output"
  REALITY_PRIVATE_KEY="$private_key"
  REALITY_PUBLIC_KEY="$public_key"
}

random_internal_ws_port() {
  local candidate attempts=0
  while (( attempts < 32 )); do
    candidate="$(shuf -i 20000-50000 -n 1)" || die "Unable to select an internal WebSocket port"
    if [[ "$candidate" != "$REALITY_PORT" && "$candidate" != "$CLOUDFLARE_PORT" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    ((attempts += 1))
  done
  die "Unable to select an internal WebSocket port without a public-port collision"
}

generate_runtime_values() {
  if mode_has_reality; then
    [[ -n "$REALITY_UUID" ]] || REALITY_UUID="$(xray uuid)"
    if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
      read_x25519_keypair
    fi
    [[ -n "$REALITY_SHORT_ID" ]] || REALITY_SHORT_ID="$(openssl rand -hex 8)"
  fi
  if mode_has_cloudflare; then
    [[ -n "$CLOUDFLARE_UUID" ]] || CLOUDFLARE_UUID="$(xray uuid)"
    [[ -n "$INTERNAL_WS_PORT" ]] || INTERNAL_WS_PORT="$(random_internal_ws_port)"
    [[ -n "$WS_PATH" ]] || WS_PATH="/$(openssl rand -hex 12)"
  fi
}

rotate_runtime_values() {
  REALITY_UUID=""
  CLOUDFLARE_UUID=""
  REALITY_PRIVATE_KEY=""
  REALITY_PUBLIC_KEY=""
  REALITY_SHORT_ID=""
  INTERNAL_WS_PORT=""
  WS_PATH=""
}

prepare_configuration() {
  local cli_mode="$MODE" cli_domain="$DOMAIN" cli_email="$EMAIL"
  local cli_reality_port="$REALITY_PORT" cli_cloudflare_port="$CLOUDFLARE_PORT"
  local cli_reality_target="$REALITY_TARGET" cli_reality_uuid="$REALITY_UUID"
  local cli_cloudflare_uuid="$CLOUDFLARE_UUID" cli_ws_path="$WS_PATH"
  local cli_rotate="$ROTATE" cli_allow_bittorrent="$ALLOW_BITTORRENT"
  local saved_mode=""

  if [[ -f "$STATE_FILE" ]]; then
    load_state
    saved_mode="$MODE"
    if [[ "$CLI_MODE_SET" == "1" ]]; then MODE="$cli_mode"; fi
    if [[ "$CLI_DOMAIN_SET" == "1" ]]; then DOMAIN="$cli_domain"; fi
    if [[ "$CLI_EMAIL_SET" == "1" ]]; then EMAIL="$cli_email"; fi
    if [[ "$CLI_REALITY_PORT_SET" == "1" ]]; then REALITY_PORT="$cli_reality_port"; fi
    if [[ "$CLI_CLOUDFLARE_PORT_SET" == "1" ]]; then CLOUDFLARE_PORT="$cli_cloudflare_port"; fi
    if [[ "$CLI_REALITY_TARGET_SET" == "1" ]]; then REALITY_TARGET="$cli_reality_target"; fi
    if [[ "$CLI_REALITY_UUID_SET" == "1" ]]; then REALITY_UUID="$cli_reality_uuid"; fi
    if [[ "$CLI_CLOUDFLARE_UUID_SET" == "1" ]]; then CLOUDFLARE_UUID="$cli_cloudflare_uuid"; fi
    if [[ "$CLI_WS_PATH_SET" == "1" ]]; then WS_PATH="$cli_ws_path"; fi
    if [[ "$CLI_ALLOW_BITTORRENT_SET" == "1" ]]; then ALLOW_BITTORRENT="$cli_allow_bittorrent"; fi
    ROTATE="$cli_rotate"
    if [[ "$MODE" != "$saved_mode" && "$ROTATE" != "1" ]]; then
      die "Changing an existing deployment mode requires --rotate"
    fi
  else
    select_mode
  fi

  validate_options
  if [[ "$ROTATE" == "1" ]]; then
    rotate_runtime_values
  elif [[ -f "$STATE_FILE" ]]; then
    validate_loaded_runtime_values
  fi
}

cloudflare_ipv4_file() { printf '%s\n' "${CLOUDFLARE_IPV4_FILE:-${RUNTIME_DIR:-/run/v2ray-onekey}/ips-v4}"; }
cloudflare_ipv6_file() { printf '%s\n' "${CLOUDFLARE_IPV6_FILE:-${RUNTIME_DIR:-/run/v2ray-onekey}/ips-v6}"; }

address_in_cloudflare_ranges() {
  local address="$1"
  python3 - "$address" "$(cloudflare_ipv4_file)" "$(cloudflare_ipv6_file)" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

for path in sys.argv[2:]:
    try:
        with open(path, encoding="utf-8") as handle:
            for raw_line in handle:
                line = raw_line.strip()
                if line and address in ipaddress.ip_network(line, strict=True):
                    raise SystemExit(0)
    except (OSError, ValueError):
        raise SystemExit(1)
raise SystemExit(1)
PY
}

resolve_host_addresses() {
  local hostname="$1" ipv4_output="" ipv6_output="" fallback_output="" addresses=""
  ipv4_output="$(getent ahostsv4 "$hostname" 2>/dev/null || true)"
  ipv6_output="$(getent ahostsv6 "$hostname" 2>/dev/null || true)"
  fallback_output="$(getent ahosts "$hostname" 2>/dev/null || true)"
  addresses="$(printf '%s\n%s\n%s\n' "$ipv4_output" "$ipv6_output" "$fallback_output" | python3 -c '
import ipaddress
import sys

seen = set()
for line in sys.stdin:
    fields = line.split()
    if not fields:
        continue
    try:
        address = ipaddress.ip_address(fields[0]).compressed
    except ValueError:
        continue
    if address not in seen:
        seen.add(address)
        print(address)
')"
  [[ -n "$addresses" ]] || return 1
  printf '%s\n' "$addresses"
}

host_resolves_to_cloudflare() {
  local hostname="$1" address
  while IFS= read -r address; do
    address_in_cloudflare_ranges "$address" && return 0
  done < <(resolve_host_addresses "$hostname")
  return 1
}

validate_cloudflare_domain() {
  local domain="${1:-$DOMAIN}"
  valid_domain "$domain" || die "Invalid domain: $domain"
  host_resolves_to_cloudflare "$domain" || die "Cloudflare domain does not resolve to Cloudflare: $domain"
}

validate_cloudflare_range_file() {
  local path="$1" family="$2"
  python3 - "$path" "$family" <<'PY'
import ipaddress
import sys

try:
    found_range = False
    with open(sys.argv[1], encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            found_range = True
            if ipaddress.ip_network(line, strict=True).version != int(sys.argv[2]):
                raise ValueError(line)
    if not found_range:
        raise ValueError("no ranges")
except (OSError, ValueError):
    raise SystemExit(1)
PY
}

download_cloudflare_ranges() (
  local run_dir v4 v6 temp_v4 temp_v6
  valid_cloudflare_timeout "$CLOUDFLARE_CONNECT_TIMEOUT" ||
    die "Invalid Cloudflare connect timeout: $CLOUDFLARE_CONNECT_TIMEOUT"
  valid_cloudflare_timeout "$CLOUDFLARE_MAX_TIME" ||
    die "Invalid Cloudflare max timeout: $CLOUDFLARE_MAX_TIME"
  run_dir="${RUNTIME_DIR:-/run/v2ray-onekey}"
  v4="${CLOUDFLARE_IPV4_FILE:-$run_dir/ips-v4}"
  v6="${CLOUDFLARE_IPV6_FILE:-$run_dir/ips-v6}"
  install -d -m 700 "$run_dir"
  temp_v4="$(mktemp "$run_dir/.ips-v4.XXXXXX")"
  temp_v6="$(mktemp "$run_dir/.ips-v6.XXXXXX")"
  trap 'rm -f -- "$temp_v4" "$temp_v6"' EXIT
  curl -fsS --connect-timeout "$CLOUDFLARE_CONNECT_TIMEOUT" --max-time "$CLOUDFLARE_MAX_TIME" \
    https://www.cloudflare.com/ips-v4 -o "$temp_v4"
  curl -fsS --connect-timeout "$CLOUDFLARE_CONNECT_TIMEOUT" --max-time "$CLOUDFLARE_MAX_TIME" \
    https://www.cloudflare.com/ips-v6 -o "$temp_v6"
  validate_cloudflare_range_file "$temp_v4" 4 || die "Invalid Cloudflare IPv4 range data"
  validate_cloudflare_range_file "$temp_v6" 6 || die "Invalid Cloudflare IPv6 range data"
  mv -f -- "$temp_v4" "$v4"
  mv -f -- "$temp_v6" "$v6"
)

write_builtin_cloudflare_ranges() (
  local run_dir v4 v6
  run_dir="${RUNTIME_DIR:-/run/v2ray-onekey}"
  v4="${CLOUDFLARE_IPV4_FILE:-$run_dir/ips-v4}"
  v6="${CLOUDFLARE_IPV6_FILE:-$run_dir/ips-v6}"
  install -d -m 700 "$run_dir"
  cat >"$v4" <<'EOF'
173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22
EOF
  cat >"$v6" <<'EOF'
2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32
EOF
  chmod 0600 "$v4" "$v6"
  validate_cloudflare_range_file "$v4" 4 || die "Invalid built-in Cloudflare IPv4 range data"
  validate_cloudflare_range_file "$v6" 6 || die "Invalid built-in Cloudflare IPv6 range data"
)

valid_cloudflare_timeout() {
  [[ "$1" =~ ^[0-9]{1,3}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 300 ))
}

validate_reality_target() {
  local target="$1" hostname
  valid_reality_target "$target" || die "Invalid REALITY target: $target (expected HOST:PORT)"
  hostname="${target%:*}"
  host_resolves_to_cloudflare "$hostname" && die "REALITY target resolves to Cloudflare: $hostname"
  timeout 15 xray tls ping "$target" >/dev/null || die "REALITY target TLS ping failed: $target"
}

validate_unique_public_ports() {
  local -a ports=()
  mode_has_reality && ports+=("$REALITY_PORT")
  mode_has_cloudflare && ports+=("$CLOUDFLARE_PORT")
  [[ ${#ports[@]} -lt 2 || "${ports[0]}" != "${ports[1]}" ]] ||
    die "REALITY and Cloudflare public ports must be different in dual mode"
}

legacy_nginx_config_path() {
  [[ "$1" != "$NGINX_SITE" && "$1" =~ ^/etc/nginx/conf\.d/v2ray-[A-Za-z0-9.-]+\.conf$ ]]
}

legacy_nginx_config_is_project_owned() {
  local path="$1"
  legacy_nginx_config_path "$path" || return 1
  [[ -f "$path" && ! -L "$path" ]] || return 1
  grep -Fq 'proxy_set_header Upgrade' "$path" &&
    grep -Fq 'proxy_pass http://127.0.0.1:' "$path" &&
    grep -Fq 'return 200 "ok' "$path"
}

current_nginx_config_is_project_owned() {
  local path="$1"
  [[ "$path" == "$NGINX_SITE" && -f "$path" && ! -L "$path" ]] || return 1
  # The literal Nginx runtime variable is an ownership signature.
  # shellcheck disable=SC2016
  grep -Fq '# Managed by v2ray-onekey' "$path" &&
    grep -Fq 'proxy_set_header Upgrade $http_upgrade;' "$path" &&
    grep -Fq 'proxy_pass http://127.0.0.1:' "$path" &&
    grep -Fq 'return 200 "ok' "$path"
}

validate_managed_destination_ownership() {
  if mode_has_cloudflare && [[ -e "$NGINX_SITE" ]] &&
    ! current_nginx_config_is_project_owned "$NGINX_SITE"; then
    die "Refusing to overwrite Nginx site without v2ray-onekey ownership signatures: $NGINX_SITE"
  fi
}

current_renewal_hook_is_project_owned() {
  local path="$1"
  [[ "$path" == "$RENEWAL_HOOK" && -f "$path" && ! -L "$path" ]] || return 1
  python3 - "$path" <<'PY'
import pathlib
import sys

expected = """#!/usr/bin/env bash
set -e
nginx -t
systemctl reload nginx
"""
try:
    actual = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
except (OSError, UnicodeError):
    raise SystemExit(1)
raise SystemExit(0 if actual == expected else 1)
PY
}

legacy_project_nginx_exists() {
  local path
  for path in /etc/nginx/conf.d/v2ray-*.conf; do
    [[ -e "$path" ]] || continue
    legacy_nginx_config_is_project_owned "$path" && return 0
  done
  return 1
}

managed_path_allowed() {
  local path="$1"
  [[ "$path" == "$LEGACY_V2RAY_CONFIG" ||
    "$path" == "$XRAY_CONFIG" ||
    "$path" == "$STATE_FILE" ||
    "$path" == "$NGINX_SITE" ||
    "$path" == "$RENEWAL_HOOK" ]] && return 0
  current_nginx_config_is_project_owned "$path" && return 0
  legacy_nginx_config_is_project_owned "$path" && return 0
  [[ -n "${BACKUP_DIR:-}" && -f "$BACKUP_DIR/legacy-files" ]] &&
    grep -Fqx -- "$path" "$BACKUP_DIR/legacy-files"
}

init_backup_metadata() {
  [[ -n "${BACKUP_DIR:-}" && "$BACKUP_DIR" == /* ]] || die "Invalid backup directory"
  install -d -m 700 "$BACKUP_DIR"
  : >"$BACKUP_DIR/manifest"
  : >"$BACKUP_DIR/services"
  : >"$BACKUP_DIR/legacy-renames"
  chmod 0600 "$BACKUP_DIR/manifest" "$BACKUP_DIR/services" "$BACKUP_DIR/legacy-renames"
}

manifest_has_path() {
  local path="$1"
  awk -F '\t' -v wanted="$path" '$2 == wanted { found = 1 } END { exit !found }' \
    "$BACKUP_DIR/manifest"
}

backup_file() {
  local path="$1" destination
  [[ "$path" == /* && "$path" != *$'\n'* ]] || die "Backup path must be an absolute path"
  managed_path_allowed "$path" || die "Refusing to back up unmanaged path: $path"
  manifest_has_path "$path" && return 0
  [[ ! -L "$path" ]] || die "Refusing to back up symlink: $path"
  if [[ -e "$path" ]]; then
    [[ -f "$path" ]] || die "Managed backup path is not a regular file: $path"
    destination="$BACKUP_DIR$path"
    install -d -m 700 "$(dirname "$destination")"
    cp -a -- "$path" "$destination"
    printf 'present\t%s\n' "$path" >>"$BACKUP_DIR/manifest"
  else
    printf 'absent\t%s\n' "$path" >>"$BACKUP_DIR/manifest"
  fi
}

service_active_state() {
  if systemctl is-active --quiet "$1" 2>/dev/null; then
    printf 'active\n'
  else
    printf 'inactive\n'
  fi
}

record_service_states() {
  local service active enabled
  : >"$BACKUP_DIR/services"
  for service in v2ray xray nginx; do
    active="$(service_active_state "$service")"
    if systemctl is-enabled --quiet "$service" 2>/dev/null; then
      enabled="enabled"
    else
      enabled="disabled"
    fi
    printf '%s\t%s\t%s\n' "$service" "$active" "$enabled" >>"$BACKUP_DIR/services"
  done
  chmod 0600 "$BACKUP_DIR/services"
}

collect_owned_legacy_nginx_files() {
  local path
  : >"$BACKUP_DIR/legacy-files"
  chmod 0600 "$BACKUP_DIR/legacy-files"
  for path in /etc/nginx/conf.d/v2ray-*.conf; do
    [[ -e "$path" ]] || continue
    if legacy_nginx_config_is_project_owned "$path"; then
      backup_file "$path"
      printf '%s\n' "$path" >>"$BACKUP_DIR/legacy-files"
    fi
  done
}

begin_transaction() {
  local managed_path
  RUN_TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  BACKUP_DIR="$BACKUP_ROOT/$RUN_TIMESTAMP"
  [[ ! -e "$BACKUP_DIR" ]] || BACKUP_DIR="${BACKUP_DIR}-$$"
  init_backup_metadata
  record_service_states
  for managed_path in \
    "$LEGACY_V2RAY_CONFIG" "$XRAY_CONFIG" "$STATE_FILE" "$NGINX_SITE" "$RENEWAL_HOOK"; do
    backup_file "$managed_path"
  done
  collect_owned_legacy_nginx_files
}

disable_owned_legacy_nginx_files() {
  local path disabled
  [[ -f "$BACKUP_DIR/legacy-files" ]] || return 0
  while IFS= read -r path; do
    [[ -n "$path" && -f "$path" && ! -L "$path" ]] || continue
    legacy_nginx_config_is_project_owned "$path" || die "Legacy Nginx ownership changed during deployment: $path"
    disabled="${path}.v2ray-onekey-disabled-${RUN_TIMESTAMP}"
    [[ ! -e "$disabled" ]] || die "Legacy Nginx disabled path already exists: $disabled"
    mv -- "$path" "$disabled"
    printf '%s\t%s\n' "$path" "$disabled" >>"$BACKUP_DIR/legacy-renames"
  done <"$BACKUP_DIR/legacy-files"
}

restore_service_states() {
  local service state enabled
  [[ -f "$BACKUP_DIR/services" ]] || return 0

  while IFS=$'\t' read -r service state enabled; do
    [[ -n "$service" ]] || continue
    if [[ "$state" == "inactive" ]]; then
      systemctl stop "$service" >/dev/null 2>&1 || true
    fi
  done <"$BACKUP_DIR/services"

  while IFS=$'\t' read -r service state enabled; do
    [[ -n "$service" ]] || continue
    if [[ "$state" == "active" ]]; then
      systemctl start "$service" >/dev/null 2>&1 || warn "Could not restart $service during rollback"
    fi
  done <"$BACKUP_DIR/services"

  while IFS=$'\t' read -r service state enabled; do
    [[ -n "$service" ]] || continue
    if [[ "$enabled" == "enabled" ]]; then
      systemctl enable "$service" >/dev/null 2>&1 || warn "Could not re-enable $service during rollback"
    else
      systemctl disable "$service" >/dev/null 2>&1 || true
    fi
  done <"$BACKUP_DIR/services"
}

rollback_current_run() {
  local kind path backup_path original disabled
  [[ -n "${BACKUP_DIR:-}" && -f "$BACKUP_DIR/manifest" ]] || return 0
  while IFS=$'\t' read -r kind path; do
    [[ -n "$path" ]] || continue
    managed_path_allowed "$path" || {
      warn "Skipping unmanaged rollback path: $path"
      continue
    }
    if [[ "$kind" == "present" ]]; then
      backup_path="$BACKUP_DIR$path"
      [[ -f "$backup_path" && ! -L "$backup_path" ]] || {
        warn "Missing backup payload: $path"
        continue
      }
      mkdir -p "$(dirname "$path")"
      rm -f -- "$path"
      cp -a -- "$backup_path" "$path"
    elif [[ "$kind" == "absent" ]]; then
      rm -f -- "$path"
    fi
  done <"$BACKUP_DIR/manifest"

  if [[ -f "$BACKUP_DIR/legacy-renames" ]]; then
    while IFS=$'\t' read -r original disabled; do
      [[ -n "$original" && -f "$disabled" && ! -L "$disabled" ]] || continue
      rm -f -- "$original"
      mv -- "$disabled" "$original"
    done <"$BACKUP_DIR/legacy-renames"
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  restore_service_states
}

legacy_nginx_config_for_port_is_project_owned() {
  local port="$1" nginx_output
  nginx_output="$(nginx -T 2>&1)" || return 1
  printf '%s\n' "$nginx_output" | python3 -c '
import re
import sys

port = re.escape(sys.argv[1])
path_pattern = re.compile(r"/etc/nginx/conf\.d/v2ray-[A-Za-z0-9.-]+\.conf")
current_path = sys.argv[2]
listen_pattern = re.compile(
    rf"^\s*listen\s+(?:(?:\[[0-9A-Fa-f:]+\]|[0-9.]+):)?{port}(?=\s|;)",
    re.MULTILINE,
)
header_pattern = re.compile(r"^# configuration file (.+):$")
required_signatures = (
    "proxy_set_header Upgrade",
    "proxy_pass http://127.0.0.1:",
    "return 200 \"ok",
)
current_signatures = required_signatures + ("# Managed by v2ray-onekey",)


def classify_section(path, content):
    listens_on_port = listen_pattern.search(content) is not None
    project_owned = (
        (
            path != current_path
            and path_pattern.fullmatch(path) is not None
            and all(signature in content for signature in required_signatures)
        )
        or (
            path == current_path
            and all(signature in content for signature in current_signatures)
        )
    )
    return listens_on_port, project_owned


path = None
content = []
found_listener = False
found_unowned_listener = False
for line in sys.stdin:
    header = header_pattern.match(line.rstrip("\n"))
    if header:
        if path is not None:
            listens_on_port, project_owned = classify_section(path, "".join(content))
            found_listener = found_listener or listens_on_port
            found_unowned_listener = found_unowned_listener or (
                listens_on_port and not project_owned
            )
        path = header.group(1)
        content = []
    elif path is not None:
        content.append(line)
if path is not None:
    listens_on_port, project_owned = classify_section(path, "".join(content))
    found_listener = found_listener or listens_on_port
    found_unowned_listener = found_unowned_listener or (
        listens_on_port and not project_owned
    )
if found_listener and not found_unowned_listener:
    raise SystemExit(0)
raise SystemExit(1)
' "$port" "$NGINX_SITE"
}

nginx_has_unmanaged_domain_conflict() {
  local port="$1" domain="$2" nginx_output
  nginx_output="$(nginx -T 2>&1)" || return 0
  printf '%s\n' "$nginx_output" | python3 -c '
import re
import sys

port = re.escape(sys.argv[1])
domain = sys.argv[2].lower()
current_path = sys.argv[3]
legacy_path = re.compile(r"/etc/nginx/conf\.d/v2ray-[A-Za-z0-9.-]+\.conf")
listen = re.compile(
    rf"^\s*listen\s+(?:(?:\[[0-9A-Fa-f:]+\]|[0-9.]+):)?{port}(?=\s|;)",
    re.MULTILINE,
)
server_name = re.compile(r"^\s*server_name\s+([^;]+);", re.MULTILINE)
header = re.compile(r"^# configuration file (.+):$")
legacy_signatures = (
    "proxy_set_header Upgrade",
    "proxy_pass http://127.0.0.1:",
    "return 200 \"ok",
)
current_signatures = legacy_signatures + ("# Managed by v2ray-onekey",)


def conflicts(path, content):
    if not listen.search(content):
        return False
    names = {
        name.lower()
        for match in server_name.finditer(content)
        for name in match.group(1).split()
    }
    if domain not in names:
        return False
    managed = (
        path == current_path
        and all(signature in content for signature in current_signatures)
    ) or (
        path != current_path
        and legacy_path.fullmatch(path) is not None
        and all(signature in content for signature in legacy_signatures)
    )
    return not managed


path = None
content = []
for line in sys.stdin:
    match = header.match(line.rstrip("\n"))
    if match:
        if path is not None and conflicts(path, "".join(content)):
            raise SystemExit(0)
        path = match.group(1)
        content = []
    elif path is not None:
        content.append(line)
if path is not None and conflicts(path, "".join(content)):
    raise SystemExit(0)
raise SystemExit(1)
' "$port" "$domain" "$NGINX_SITE"
}

port_listener_conflicts() {
  local role="$1" port="$2" listener
  PORT_CONFLICT_DETAILS="$(ss -H -lntp "sport = :$port" 2>&1)" ||
    die "Unable to inspect TCP port $port: $PORT_CONFLICT_DETAILS"
  if [[ -z "$PORT_CONFLICT_DETAILS" ]]; then
    if [[ "$role" == "cloudflare" || "$role" == "acme" ]] &&
      nginx_has_unmanaged_domain_conflict "$port" "$DOMAIN"; then
      PORT_CONFLICT_DETAILS="Nginx already defines server_name $DOMAIN on TCP $port"
      return 0
    fi
    return 1
  fi
  while IFS= read -r listener; do
    [[ -n "$listener" ]] || continue
    if [[ "$listener" == *xray* || "$listener" == *v2ray* ]]; then
      continue
    fi
    if [[ "$listener" == *nginx* ]]; then
      if [[ "$role" == "reality" ]] &&
        ! legacy_nginx_config_for_port_is_project_owned "$port"; then
        return 0
      fi
      continue
    fi
    return 0
  done <<<"$PORT_CONFLICT_DETAILS"
  if [[ "$role" == "cloudflare" || "$role" == "acme" ]] &&
    nginx_has_unmanaged_domain_conflict "$port" "$DOMAIN"; then
    PORT_CONFLICT_DETAILS="Nginx already defines server_name $DOMAIN on TCP $port"
    return 0
  fi
  return 1
}

stdin_is_tty() { [[ -t 0 ]]; }

complete_listener_diagnostics() {
  local output=""
  output="$(ss -lntp 2>&1)" || output="ss -lntp failed: $output"
  printf '%s\n' "$output"
}

resolve_one_public_port() {
  local role="$1" option_name="$2" attempt replacement current_port full_listeners
  for attempt in 1 2 3 4 5; do
    if [[ "$role" == "reality" ]]; then current_port="$REALITY_PORT"; else current_port="$CLOUDFLARE_PORT"; fi
    port_listener_conflicts "$role" "$current_port" || return 0
    if ! stdin_is_tty; then
      full_listeners="$(complete_listener_diagnostics)"
      die "TCP port $current_port is occupied. Rerun using $option_name PORT. Conflict: $PORT_CONFLICT_DETAILS
ss -lntp output:
$full_listeners"
    fi
    warn "TCP port $current_port is unavailable: $PORT_CONFLICT_DETAILS"
    read -r -p "Enter a replacement port for $role (or q to cancel): " replacement ||
      die "Port selection cancelled"
    [[ "$replacement" != "q" && "$replacement" != "Q" ]] || die "Port selection cancelled"
    if [[ "$role" == "cloudflare" ]]; then
      valid_cloudflare_port "$replacement" || {
        warn "Cloudflare HTTPS ports: 443, 2053, 2083, 2087, 2096, 8443"
        continue
      }
    else
      valid_port "$replacement" || {
        warn "Enter a valid TCP port from 1 to 65535"
        continue
      }
    fi
    replacement="$(normalize_port "$replacement")"
    if [[ "$MODE" == "dual" &&
      ( ( "$role" == "reality" && "$replacement" == "$CLOUDFLARE_PORT" ) ||
        ( "$role" == "cloudflare" && "$replacement" == "$REALITY_PORT" ) ) ]]; then
      warn "REALITY and Cloudflare public ports must be different"
      continue
    fi
    if [[ "$role" == "reality" ]]; then REALITY_PORT="$replacement"; else CLOUDFLARE_PORT="$replacement"; fi
    port_listener_conflicts "$role" "$replacement" || return 0
  done
  die "Unable to select an available $role port after 5 attempts"
}

resolve_public_port_conflicts() {
  local full_listeners=""
  mode_has_reality && resolve_one_public_port reality "--reality-port"
  mode_has_cloudflare && resolve_one_public_port cloudflare "--cloudflare-port"
  validate_unique_public_ports
  if mode_has_cloudflare && port_listener_conflicts acme 80; then
    full_listeners="$(complete_listener_diagnostics)"
    die "TCP port 80 is unavailable for the ACME HTTP-01 challenge. Conflict: $PORT_CONFLICT_DETAILS
ss -lntp output:
$full_listeners"
  fi
}

check_public_port_listeners() {
  resolve_public_port_conflicts
}

ensure_internal_ws_port_available() {
  local attempt listeners listener full_listeners unrelated
  mode_has_cloudflare || return 0
  for ((attempt = 0; attempt <= 32; attempt += 1)); do
    listeners="$(ss -H -lntp "sport = :$INTERNAL_WS_PORT" 2>&1)" ||
      die "Unable to inspect internal WebSocket port $INTERNAL_WS_PORT: $listeners"
    [[ -n "$listeners" ]] || return 0
    unrelated="0"
    while IFS= read -r listener; do
      [[ -z "$listener" || "$listener" == *xray* || "$listener" == *v2ray* ]] || unrelated="1"
    done <<<"$listeners"
    if [[ "$unrelated" == "0" ]]; then
      return 0
    fi
    (( attempt < 32 )) || break
    warn "Internal WebSocket port $INTERNAL_WS_PORT is occupied; selecting another localhost port."
    INTERNAL_WS_PORT="$(random_internal_ws_port)"
  done
  full_listeners="$(ss -lntp 2>&1)" || full_listeners="ss -lntp failed: $full_listeners"
  die "Unable to find an available internal WebSocket port after 32 attempts.
ss -lntp output:
$full_listeners"
}

check_internal_ws_port_listener() {
  ensure_internal_ws_port_available
}

preflight_environment() {
  [[ "$(uname -s)" == "Linux" ]] || die "This script requires Linux"
  [[ "$(id -u)" -eq 0 ]] || die "Please run as root"
  command -v systemctl >/dev/null 2>&1 || die "systemd is required"
  detect_pkg_manager
  validate_unique_public_ports
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  else
    die "Unsupported Linux distribution. This script supports apt, dnf, or yum based systems."
  fi
}

install_packages() {
  local packages=("$@")
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y --no-install-recommends "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
  esac
}

install_required_packages() {
  local -a base_packages=(curl ca-certificates openssl python3 coreutils iproute2)
  install_packages "${base_packages[@]}"
  if mode_has_cloudflare; then
    install_packages nginx certbot
    if ! install_packages python3-certbot-nginx; then
      warn "The optional certbot Nginx plugin is unavailable; webroot issuance will still be used."
    fi
  fi
}

install_xray_core() {
  local installer
  log "Installing or updating Xray from the official XTLS installer..."
  installer="$(curl -LfsS --connect-timeout 10 --max-time 120 "$XRAY_INSTALL_URL")"
  [[ -n "$installer" ]] || die "The official Xray installer download was empty"
  bash -c "$installer" @ install
}

xray_service_identity() {
  local user group
  user="$(systemctl show -p User --value xray 2>/dev/null || true)"
  user="${user:-root}"
  id "$user" >/dev/null 2>&1 || die "Xray service user does not exist: $user"
  group="$(id -gn "$user")" || die "Unable to determine group for Xray service user: $user"
  printf '%s:%s\n' "$user" "$group"
}

install_validated_xray_config() {
  local staged="$1" identity user group config_dir temp
  [[ -f "$staged" && ! -L "$staged" ]] || die "Validated Xray staging file is missing"
  identity="$(xray_service_identity)"
  user="${identity%%:*}"
  group="${identity#*:}"
  config_dir="$(dirname "$XRAY_CONFIG")"
  install -d -o root -g root -m 0755 "$config_dir"
  temp="$(mktemp "$config_dir/.config.json.XXXXXX")"
  if ! install -o "$user" -g "$group" -m 0400 "$staged" "$temp"; then
    rm -f -- "$temp"
    return 1
  fi
  mv -f -- "$temp" "$XRAY_CONFIG"
}

install_nginx_config_atomically() {
  local staged="$1" site_dir temp
  [[ -f "$staged" && ! -L "$staged" ]] || die "Nginx staging file is missing"
  site_dir="$(dirname "$NGINX_SITE")"
  install -d -m 0755 "$site_dir"
  temp="$(mktemp "$site_dir/.v2ray-onekey.conf.XXXXXX")"
  if ! install -o root -g root -m 0644 "$staged" "$temp"; then
    rm -f -- "$temp"
    return 1
  fi
  mv -f -- "$temp" "$NGINX_SITE"
}

public_ip() {
  local ip=""
  ip="$(curl -4fsS --connect-timeout 3 --max-time 6 https://api.ipify.org || true)"
  valid_public_ip "$ip" || ip="$(curl -4fsS --connect-timeout 3 --max-time 6 https://ifconfig.me || true)"
  valid_public_ip "$ip" || return 1
  printf '%s' "$ip"
}

valid_public_ip() {
  python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
if not address.is_global:
    raise SystemExit(1)
PY
}

render_xray_config() {
  local output_path="$1"
  local output_dir=""
  local render_status="0"
  local temp_path=""
  output_dir="$(dirname "$output_path")"
  install -d -m 755 "$output_dir"
  temp_path="$(mktemp "$output_dir/.xray-config.XXXXXX")"
  python3 - \
    "$temp_path" \
    "$MODE" \
    "$REALITY_PORT" \
    "$INTERNAL_WS_PORT" \
    "$REALITY_UUID" \
    "$CLOUDFLARE_UUID" \
    "$REALITY_PRIVATE_KEY" \
    "$REALITY_SHORT_ID" \
    "$REALITY_TARGET" \
    "$WS_PATH" \
    "$ALLOW_BITTORRENT" <<'PY' || render_status=$?
import json
import sys


(
    output_path,
    mode,
    reality_port,
    internal_ws_port,
    reality_uuid,
    cloudflare_uuid,
    reality_private_key,
    reality_short_id,
    reality_target,
    ws_path,
    allow_bittorrent,
) = sys.argv[1:]

sniffing = {
    "enabled": True,
    "destOverride": ["http", "tls", "quic"],
    "routeOnly": True,
}
inbounds = []

if mode in ("reality", "dual"):
    inbounds.append(
        {
            "tag": "reality-in",
            "listen": "0.0.0.0",
            "port": int(reality_port),
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": reality_uuid,
                        "flow": "xtls-rprx-vision",
                        "email": "reality",
                    }
                ],
                "decryption": "none",
            },
            "streamSettings": {
                "network": "raw",
                "security": "reality",
                "realitySettings": {
                    "show": False,
                    "target": reality_target,
                    "serverNames": [reality_target.rsplit(":", 1)[0]],
                    "privateKey": reality_private_key,
                    "shortIds": [reality_short_id],
                },
            },
            "sniffing": sniffing,
        }
    )

if mode in ("cloudflare", "dual"):
    inbounds.append(
        {
            "tag": "cloudflare-ws-in",
            "listen": "127.0.0.1",
            "port": int(internal_ws_port),
            "protocol": "vless",
            "settings": {
                "clients": [{"id": cloudflare_uuid, "email": "cloudflare"}],
                "decryption": "none",
            },
            "streamSettings": {
                "network": "ws",
                "security": "none",
                "wsSettings": {"path": ws_path},
            },
            "sniffing": sniffing,
        }
    )

routing_rules = [
    {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"}
]
if allow_bittorrent != "1":
    routing_rules.append(
        {
            "type": "field",
            "protocol": ["bittorrent"],
            "outboundTag": "block",
        }
    )

config = {
    "log": {"loglevel": "warning"},
    "inbounds": inbounds,
    "outbounds": [
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"},
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": routing_rules,
    },
}

with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")
PY
  if (( render_status != 0 )); then
    rm -f -- "$temp_path" || true
    return "$render_status"
  fi
  if ! chmod 0600 "$temp_path"; then
    rm -f -- "$temp_path" || true
    return 1
  fi
  if ! mv -f -- "$temp_path" "$output_path"; then
    rm -f -- "$temp_path" || true
    return 1
  fi
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

format_uri_host() {
  python3 - "$1" <<'PY'
import ipaddress
import sys


try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

if address.version == 6:
    print(f"[{address.compressed}]")
else:
    print(address.compressed)
PY
}

open_firewall_port() {
  local port="$1"
  local proto="${2:-tcp}"

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${port}/${proto}" >/dev/null || true
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null || true
    firewall-cmd --reload >/dev/null || true
  fi
}

valid_nginx_webroot() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]]
}

render_nginx_site() (
  local output_path="$1" phase="$2" output_dir output_name temp_path
  local acme_webroot="${ACME_WEBROOT:-/var/www/v2ray-onekey}"

  [[ "$phase" == "initial" || "$phase" == "final" ]] ||
    die "Invalid Nginx render mode: $phase"
  valid_domain "$DOMAIN" || die "Invalid domain: $DOMAIN"
  DOMAIN="$(normalize_domain "$DOMAIN")"
  valid_nginx_webroot "$acme_webroot" || die "Invalid ACME webroot: $acme_webroot"
  [[ -n "$output_path" && "$output_path" != *$'\n'* ]] || die "Invalid Nginx output path"
  if [[ "$phase" == "final" ]]; then
    valid_cloudflare_port "$CLOUDFLARE_PORT" || die "Unsupported Cloudflare port: $CLOUDFLARE_PORT"
    CLOUDFLARE_PORT="$(normalize_port "$CLOUDFLARE_PORT")"
    valid_port "$INTERNAL_WS_PORT" || die "Invalid internal WebSocket port: $INTERNAL_WS_PORT"
    valid_ws_path "$WS_PATH" || die "WebSocket path must start with / and contain no whitespace"
  fi

  output_dir="$(dirname "$output_path")"
  output_name="$(basename "$output_path")"
  [[ -d "$output_dir" ]] || die "Nginx output directory does not exist: $output_dir"
  temp_path="$(mktemp "$output_dir/.${output_name}.XXXXXX")"
  trap 'rm -f -- "$temp_path"' EXIT

  cat >"$temp_path" <<EOF
# Managed by v2ray-onekey
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root $acme_webroot;
    }

    location / {
        default_type text/plain;
        return 200 "ok\n";
    }
}
EOF

  if [[ "$phase" == "final" ]]; then
    cat >>"$temp_path" <<EOF

server {
    listen $CLOUDFLARE_PORT ssl;
    listen [::]:$CLOUDFLARE_PORT ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location = $WS_PATH {
        proxy_pass http://127.0.0.1:$INTERNAL_WS_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }

    location / {
        default_type text/plain;
        return 200 "ok\n";
    }
}
EOF
  fi

  chmod 0644 "$temp_path"
  mv -f -- "$temp_path" "$output_path"
)

request_certificate() {
  local acme_webroot="${ACME_WEBROOT:-/var/www/v2ray-onekey}"
  valid_domain "$DOMAIN" || die "Invalid domain: $DOMAIN"
  DOMAIN="$(normalize_domain "$DOMAIN")"
  [[ -n "$EMAIL" ]] || die "Email is required for certificate issuance"
  valid_nginx_webroot "$acme_webroot" || die "Invalid ACME webroot: $acme_webroot"
  certbot certonly --webroot -w "$acme_webroot" --non-interactive --agree-tos \
    --email "$EMAIL" --keep-until-expiring -d "$DOMAIN"
}

create_renewal_hook() (
  local hook_path="${1:-/etc/letsencrypt/renewal-hooks/deploy/v2ray-onekey-nginx.sh}"
  local hook_dir hook_name temp_path
  [[ -n "$hook_path" && "$hook_path" == /* && "$hook_path" != *$'\n'* ]] ||
    die "Invalid renewal hook path"
  hook_dir="$(dirname "$hook_path")"
  hook_name="$(basename "$hook_path")"
  install -d -m 755 "$hook_dir"
  temp_path="$(mktemp "$hook_dir/.${hook_name}.XXXXXX")"
  trap 'rm -f -- "$temp_path"' EXIT
  cat >"$temp_path" <<'EOF'
#!/usr/bin/env bash
set -e
nginx -t
systemctl reload nginx
EOF
  chmod 0755 "$temp_path"
  mv -f -- "$temp_path" "$hook_path"
)

probe_cloudflare_edge() {
  local url output remote_address=""
  valid_domain "$DOMAIN" || return 1
  valid_cloudflare_port "$CLOUDFLARE_PORT" || return 1
  valid_cloudflare_timeout "$CLOUDFLARE_CONNECT_TIMEOUT" || return 1
  valid_cloudflare_timeout "$CLOUDFLARE_MAX_TIME" || return 1
  DOMAIN="$(normalize_domain "$DOMAIN")"
  CLOUDFLARE_PORT="$(normalize_port "$CLOUDFLARE_PORT")"
  url="https://${DOMAIN}:${CLOUDFLARE_PORT}/"
  if ! output="$(curl -fsS -D - -o /dev/null --write-out $'\n%{remote_ip}\n' \
    --connect-timeout "$CLOUDFLARE_CONNECT_TIMEOUT" --max-time "$CLOUDFLARE_MAX_TIME" "$url" 2>&1)"; then
    return 1
  fi
  if grep -Eiq '^cf-ray:' <<<"$output"; then
    return 0
  fi
  remote_address="$(tail -n 1 <<<"$output" | tr -d '\r')"
  if [[ -n "$remote_address" ]] && address_in_cloudflare_ranges "$remote_address"; then
    return 0
  fi
  return 1
}

check_cloudflare_edge() {
  if probe_cloudflare_edge; then
    return 0
  fi
  warn "Cloudflare edge check could not be confirmed; the origin configuration remains active."
  return 0
}

service_was_active() {
  local service="$1"
  awk -F '\t' -v wanted="$service" '$1 == wanted && $2 == "active" { found = 1 } END { exit !found }' \
    "$BACKUP_DIR/services"
}

service_unit_exists() {
  systemctl cat "$1" >/dev/null 2>&1
}

stop_legacy_service_for_cutover() {
  if service_was_active xray; then
    log "Temporarily stopping the existing Xray service for cutover..."
    systemctl stop xray
  fi
  if service_was_active v2ray; then
    log "Temporarily stopping V2Ray for the validated cutover..."
    systemctl stop v2ray
  fi
}

activate_nginx_config() {
  nginx -t
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl enable --now nginx
  fi
}

release_legacy_nginx_listeners() {
  disable_owned_legacy_nginx_files
  if ! mode_has_cloudflare && current_nginx_config_is_project_owned "$NGINX_SITE"; then
    rm -f -- "$NGINX_SITE"
  fi
  if ! mode_has_cloudflare && [[ -e "$RENEWAL_HOOK" ]]; then
    if current_renewal_hook_is_project_owned "$RENEWAL_HOOK"; then
      rm -f -- "$RENEWAL_HOOK"
    else
      warn "Leaving unrecognized renewal hook unchanged: $RENEWAL_HOOK"
    fi
  fi
  if ! mode_has_cloudflare && systemctl is-active --quiet nginx; then
    nginx -t
    systemctl reload nginx
  fi
}

listener_output() {
  ss -H -lntp "sport = :$1" 2>&1
}

require_listener_owner() {
  local port="$1" owner="$2" binding="${3:-}" output
  output="$(listener_output "$port")" || die "Unable to inspect listener on TCP $port: $output"
  [[ -n "$output" ]] || die "Expected $owner listener on TCP $port, but no listener was found"
  [[ "$output" == *"$owner"* ]] || die "TCP $port is not owned by $owner:
$output"
  if [[ -n "$binding" && "$output" != *"$binding:$port"* ]]; then
    die "TCP $port is not bound to $binding as required:
$output"
  fi
}

verify_started_services() {
  systemctl is-active --quiet xray || die "Xray is not active after restart"
  if mode_has_reality; then
    require_listener_owner "$REALITY_PORT" xray
  fi
  if mode_has_cloudflare; then
    systemctl is-active --quiet nginx || die "Nginx is not active after reload"
    require_listener_owner "$INTERNAL_WS_PORT" xray 127.0.0.1
    require_listener_owner "$CLOUDFLARE_PORT" nginx
    require_listener_owner 80 nginx
  fi
}

disable_legacy_v2ray_after_success() {
  if service_unit_exists v2ray; then
    systemctl disable --now v2ray
  fi
}

configure_firewall() {
  if mode_has_cloudflare; then
    open_firewall_port 80 tcp
    open_firewall_port "$CLOUDFLARE_PORT" tcp
  fi
  if mode_has_reality; then
    open_firewall_port "$REALITY_PORT" tcp
  fi
}

required_public_ports() {
  local -a ports=()
  mode_has_cloudflare && ports+=(80 "$CLOUDFLARE_PORT")
  mode_has_reality && ports+=("$REALITY_PORT")
  printf '%s\n' "${ports[@]}"
}

print_deployment_summary() {
  local port_list=""
  port_list="$(required_public_ports | paste -sd, -)"
  printf '\n'
  if mode_has_reality; then
    printf 'Primary direct entry: VLESS + REALITY + XTLS Vision\n'
    make_reality_link "$PUBLIC_ADDRESS"
  fi
  if mode_has_cloudflare; then
    printf 'Fallback entry: VLESS + WebSocket + TLS + Cloudflare\n'
    make_cloudflare_link
  fi
  printf 'State file: %s\n' "$STATE_FILE"
  printf 'Backup: %s\n' "$BACKUP_DIR"
  printf 'Open these TCP ports in the cloud security group: %s\n' "$port_list"
  if mode_has_cloudflare; then
    printf 'Diagnostics: systemctl status xray; journalctl -u xray -e; nginx -t\n'
  else
    printf 'Diagnostics: systemctl status xray; journalctl -u xray -e\n'
  fi
}

prepare_runtime_directory() {
  RUNTIME_DIR="${RUNTIME_DIR:-/run/v2ray-onekey/$RUN_TIMESTAMP}"
  install -d -m 700 "$RUNTIME_DIR"
}

deploy_services() {
  local staged_xray staged_nginx_initial staged_nginx_final formatted_address

  begin_transaction
  validate_managed_destination_ownership
  install_required_packages
  install_xray_core
  prepare_runtime_directory
  generate_runtime_values
  validate_loaded_runtime_values

  if mode_has_cloudflare; then
    download_cloudflare_ranges
    validate_cloudflare_domain
  else
    write_builtin_cloudflare_ranges
  fi
  if mode_has_reality; then
    validate_reality_target "$REALITY_TARGET"
    PUBLIC_ADDRESS="$(public_ip)"
    [[ -n "$PUBLIC_ADDRESS" ]] || die "Unable to determine the public IP for the REALITY link"
    valid_public_ip "$PUBLIC_ADDRESS" || die "Detected address is not a public IP: $PUBLIC_ADDRESS"
    formatted_address="$(format_uri_host "$PUBLIC_ADDRESS")" || die "Invalid public IP detected: $PUBLIC_ADDRESS"
    [[ -n "$formatted_address" ]] || die "Unable to format the public IP for the REALITY link"
  else
    PUBLIC_ADDRESS=""
  fi

  check_public_port_listeners
  check_internal_ws_port_listener
  staged_xray="$RUNTIME_DIR/xray-config.json"
  render_xray_config "$staged_xray"
  xray run -test -config "$staged_xray"

  stop_legacy_service_for_cutover
  release_legacy_nginx_listeners

  if mode_has_cloudflare; then
    staged_nginx_initial="$RUNTIME_DIR/nginx-initial.conf"
    staged_nginx_final="$RUNTIME_DIR/nginx-final.conf"
    install -d -m 755 "${ACME_WEBROOT:-/var/www/v2ray-onekey}"
    render_nginx_site "$staged_nginx_initial" initial
    install_nginx_config_atomically "$staged_nginx_initial"
    activate_nginx_config
    request_certificate
    render_nginx_site "$staged_nginx_final" final
    install_nginx_config_atomically "$staged_nginx_final"
    nginx -t
    create_renewal_hook "$RENEWAL_HOOK"
  fi

  install_validated_xray_config "$staged_xray"
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray
  if mode_has_cloudflare; then
    systemctl reload nginx
  fi
  verify_started_services

  disable_legacy_v2ray_after_success
  save_state
  configure_firewall
  if mode_has_cloudflare; then
    check_cloudflare_edge
  fi
  print_deployment_summary
}

transaction_exit_handler() {
  local status=$?
  trap - EXIT ERR INT TERM
  if [[ "${TRANSACTION_ACTIVE:-0}" != "1" || "$status" -eq 0 ]]; then
    exit "$status"
  fi
  TRANSACTION_ACTIVE="0"
  set +e
  warn "Deployment failed; restoring files from ${BACKUP_DIR:-the current backup}"
  rollback_current_run || warn "Automatic rollback was incomplete"
  exit "$status"
}

activate_transaction_traps() {
  TRANSACTION_ACTIVE="1"
  trap transaction_exit_handler EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

complete_transaction() {
  TRANSACTION_ACTIVE="0"
  trap - EXIT ERR INT TERM
}

make_reality_link() {
  local address="$1"
  local uri_host=""
  uri_host="$(format_uri_host "$address")" || return 1
  local server_name="${REALITY_TARGET%:*}"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s\n' \
    "$REALITY_UUID" "$uri_host" "$REALITY_PORT" \
    "$(urlencode "$server_name")" "$(urlencode "$REALITY_PUBLIC_KEY")" \
    "$(urlencode "$REALITY_SHORT_ID")" "$(urlencode "VLESS-REALITY-direct")"
}

make_cloudflare_link() {
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%s#%s\n' \
    "$CLOUDFLARE_UUID" "$DOMAIN" "$CLOUDFLARE_PORT" \
    "$(urlencode "$DOMAIN")" "$(urlencode "$DOMAIN")" \
    "$(urlencode "$WS_PATH")" "$(urlencode "VLESS-Cloudflare-fallback")"
}

main() {
  set -Eeuo pipefail
  reset_options
  parse_args "$@"
  [[ "$(id -u)" -eq 0 ]] || die "Please run as root: sudo bash v2ray-onekey.sh"
  prepare_configuration
  preflight_environment
  activate_transaction_traps
  deploy_services
  complete_transaction
}

if [[ "${V2RAY_ONEKEY_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
