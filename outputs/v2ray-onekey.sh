#!/usr/bin/env bash

APP_NAME="v2ray-onekey"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
STATE_FILE="${STATE_FILE:-/etc/v2ray-onekey/state.env}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/v2ray-onekey}"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
DEFAULT_REALITY_TARGET="www.microsoft.com:443"
CLOUDFLARE_CONNECT_TIMEOUT="${CLOUDFLARE_CONNECT_TIMEOUT:-10}"
CLOUDFLARE_MAX_TIME="${CLOUDFLARE_MAX_TIME:-30}"

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
        [[ "$MODE" == "reality" || "$MODE" == "cloudflare" || "$MODE" == "dual" ]] ||
          die "--mode must be reality, cloudflare, or dual"
        shift 2
        ;;
      --domain)
        [[ $# -ge 2 && -n "$2" ]] || die "--domain requires a value"
        DOMAIN="$2"
        shift 2
        ;;
      --email)
        [[ $# -ge 2 && -n "$2" ]] || die "--email requires a value"
        EMAIL="$2"
        shift 2
        ;;
      --reality-port)
        [[ $# -ge 2 && -n "$2" ]] || die "--reality-port requires a value"
        REALITY_PORT="$2"
        shift 2
        ;;
      --cloudflare-port)
        [[ $# -ge 2 && -n "$2" ]] || die "--cloudflare-port requires a value"
        CLOUDFLARE_PORT="$2"
        shift 2
        ;;
      --reality-target)
        [[ $# -ge 2 && -n "$2" ]] || die "--reality-target requires a value"
        REALITY_TARGET="$2"
        shift 2
        ;;
      --reality-uuid)
        [[ $# -ge 2 && -n "$2" ]] || die "--reality-uuid requires a value"
        REALITY_UUID="$2"
        shift 2
        ;;
      --cloudflare-uuid)
        [[ $# -ge 2 && -n "$2" ]] || die "--cloudflare-uuid requires a value"
        CLOUDFLARE_UUID="$2"
        shift 2
        ;;
      --ws-path)
        [[ $# -ge 2 && -n "$2" ]] || die "--ws-path requires a value"
        WS_PATH="$2"
        shift 2
        ;;
      --rotate)
        ROTATE="1"
        shift
        ;;
      --allow-bittorrent)
        ALLOW_BITTORRENT="1"
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

  if mode_has_reality; then
    valid_port "$REALITY_PORT" || die "Invalid REALITY port: $REALITY_PORT"
    REALITY_PORT="$(normalize_port "$REALITY_PORT")"
    valid_reality_target "$REALITY_TARGET" || die "Invalid REALITY target: $REALITY_TARGET (expected HOST:PORT)"
  fi
  if mode_has_cloudflare; then
    valid_port "$CLOUDFLARE_PORT" || die "Invalid Cloudflare port: $CLOUDFLARE_PORT"
    CLOUDFLARE_PORT="$(normalize_port "$CLOUDFLARE_PORT")"
  fi
  if [[ "$MODE" == "dual" && "$REALITY_PORT" == "$CLOUDFLARE_PORT" ]]; then
    die "REALITY and Cloudflare public ports must be different in dual mode"
  fi

  [[ -z "$REALITY_UUID" ]] || valid_uuid "$REALITY_UUID" || die "Invalid REALITY UUID: $REALITY_UUID"
  [[ -z "$CLOUDFLARE_UUID" ]] || valid_uuid "$CLOUDFLARE_UUID" || die "Invalid Cloudflare UUID: $CLOUDFLARE_UUID"
  [[ -z "$WS_PATH" || "$WS_PATH" == /* ]] || die "WebSocket path must start with /"
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
  [[ "$1" =~ ^[A-Fa-f0-9]{1,16}$ ]]
}

valid_ws_path() {
  [[ "$1" =~ ^/[^[:space:]]+$ ]]
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

validate_reality_target() {
  local target="$1" hostname
  valid_reality_target "$target" || die "Invalid REALITY target: $target (expected HOST:PORT)"
  hostname="${target%:*}"
  host_resolves_to_cloudflare "$hostname" && die "REALITY target resolves to Cloudflare: $hostname"
  timeout 15 xray tls ping "$hostname" >/dev/null || die "REALITY target TLS ping failed: $hostname"
}

validate_unique_public_ports() {
  local -a ports=()
  mode_has_reality && ports+=("$REALITY_PORT")
  mode_has_cloudflare && ports+=("$CLOUDFLARE_PORT")
  [[ ${#ports[@]} -lt 2 || "${ports[0]}" != "${ports[1]}" ]] ||
    die "REALITY and Cloudflare public ports must be different in dual mode"
}

legacy_nginx_config_path() {
  [[ "$1" =~ ^/etc/nginx/conf\.d/v2ray-[A-Za-z0-9.-]+\.conf$ ]]
}

legacy_nginx_config_is_project_owned() {
  local path="$1"
  legacy_nginx_config_path "$path" || return 1
  grep -Fq 'proxy_set_header Upgrade' "$path" &&
    grep -Fq 'proxy_pass http://127.0.0.1:' "$path" &&
    grep -Fq 'return 200 "ok' "$path"
}

legacy_project_nginx_exists() {
  local path
  for path in /etc/nginx/conf.d/v2ray-*.conf; do
    [[ -e "$path" ]] || continue
    legacy_nginx_config_is_project_owned "$path" && return 0
  done
  return 1
}

legacy_nginx_config_for_port_is_project_owned() {
  local port="$1" nginx_output
  nginx_output="$(nginx -T 2>&1)" || return 1
  printf '%s\n' "$nginx_output" | python3 -c '
import re
import sys

port = re.escape(sys.argv[1])
path_pattern = re.compile(r"/etc/nginx/conf\.d/v2ray-[A-Za-z0-9.-]+\.conf")
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


def classify_section(path, content):
    listens_on_port = listen_pattern.search(content) is not None
    project_owned = (
        path_pattern.fullmatch(path) is not None
        and all(signature in content for signature in required_signatures)
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
' "$port"
}

listener_is_managed() {
  local listener="$1" port="$2"
  [[ "$listener" == *xray* || "$listener" == *v2ray* ]] && return 0
  [[ "$listener" == *nginx* ]] && legacy_nginx_config_for_port_is_project_owned "$port"
}

check_public_port_listeners() {
  local port listeners listener full_listeners
  for port in "${REALITY_PORT:-}" "${CLOUDFLARE_PORT:-}"; do
    [[ -n "$port" ]] || continue
    listeners="$(ss -H -ltnp "sport = :$port" 2>&1)" || die "Unable to inspect listeners with ss: $listeners"
    [[ -z "$listeners" ]] && continue
    while IFS= read -r listener; do
      [[ -z "$listener" ]] && continue
      listener_is_managed "$listener" "$port" && continue
      full_listeners="$(ss -lntp 2>&1)" || full_listeners="ss -lntp failed: $full_listeners"
      die "Public port $port listener conflict: $listener
ss -lntp output:
$full_listeners"
    done <<<"$listeners"
  done
}

preflight_environment() {
  [[ "$(uname -s)" == "Linux" ]] || die "This script requires Linux"
  [[ "$(id -u)" -eq 0 ]] || die "Please run as root"
  command -v systemctl >/dev/null 2>&1 || die "systemd is required"
  detect_pkg_manager
  validate_unique_public_ports
  check_public_port_listeners
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

random_port() {
  shuf -i 20000-60000 -n 1
}

generate_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
  fi
}

public_ip() {
  local ip=""
  ip="$(curl -4fsS --max-time 6 https://api.ipify.org || true)"
  [[ -n "$ip" ]] || ip="$(curl -4fsS --max-time 6 https://ifconfig.me || true)"
  [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "$ip"
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
    fallback_limit = {
        "afterBytes": 1048576,
        "bytesPerSec": 102400,
        "burstBytesPerSec": 1048576,
    }
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
                    "limitFallbackUpload": fallback_limit,
                    "limitFallbackDownload": fallback_limit,
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

install_v2ray() {
  log "Installing or updating V2Ray from the official V2Fly installer..."
  bash <(curl -fsSL "$INSTALL_SCRIPT_URL")
}

configure_nginx_tls() {
  local nginx_site="/etc/nginx/conf.d/v2ray-${DOMAIN}.conf"

  log "Installing Nginx and Certbot..."
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    install_packages nginx certbot python3-certbot-nginx
  else
    install_packages nginx certbot python3-certbot-nginx || install_packages nginx certbot
  fi

  systemctl enable --now nginx

  cat > "$nginx_site" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }

    location $WS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

  nginx -t
  systemctl reload nginx

  log "Requesting a Let's Encrypt certificate for $DOMAIN..."
  certbot --nginx --non-interactive --agree-tos --redirect --email "$EMAIL" -d "$DOMAIN"
  systemctl reload nginx
}

restart_v2ray() {
  systemctl daemon-reload
  systemctl enable --now v2ray
  systemctl restart v2ray
  systemctl --no-pager --full status v2ray >/tmp/v2ray-status.txt || {
    cat /tmp/v2ray-status.txt >&2 || true
    die "V2Ray failed to start. Check: journalctl -u v2ray -e --no-pager"
  }
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
  select_mode
  validate_options
  [[ "$(id -u)" -eq 0 ]] || die "Please run as root: sudo bash v2ray-onekey.sh"
  die "Deployment backend is being migrated; do not deploy from this feature branch yet."
}

if [[ "${V2RAY_ONEKEY_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
