#!/usr/bin/env bash
INSTALLER_VARIANT="new"

APP_NAME="v2ray-onekey"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
STATE_FILE="${STATE_FILE:-/etc/v2ray-onekey/state.env}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/v2ray-onekey}"
DEPLOYMENT_LOCK_DIR="${DEPLOYMENT_LOCK_DIR:-/run/lock/v2ray-onekey}"
NGINX_SITE="${NGINX_SITE:-/etc/nginx/conf.d/v2ray-onekey.conf}"
RENEWAL_HOOK="${RENEWAL_HOOK:-/etc/letsencrypt/renewal-hooks/deploy/v2ray-onekey-nginx.sh}"
LEGACY_V2RAY_CONFIG="${LEGACY_V2RAY_CONFIG:-/usr/local/etc/v2ray/config.json}"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
CLOUDFLARE_CONNECT_TIMEOUT="${CLOUDFLARE_CONNECT_TIMEOUT:-10}"
CLOUDFLARE_MAX_TIME="${CLOUDFLARE_MAX_TIME:-30}"
LISTENER_WAIT_ATTEMPTS="${LISTENER_WAIT_ATTEMPTS:-15}"
LISTENER_WAIT_INTERVAL="${LISTENER_WAIT_INTERVAL:-1}"
TRANSACTION_ACTIVE="0"
LOCK_HELD="0"

log() { printf '\033[1;32m[%s]\033[0m %s\n' "$APP_NAME" "$*"; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$APP_NAME" "$*"; }
die() { printf '\033[1;31m[%s]\033[0m %s\n' "$APP_NAME" "$*" >&2; exit 1; }

reset_options() {
  STATE_SCHEMA=""
  MODE=""
  DOMAIN=""
  EMAIL=""
  CLOUDFLARE_PORT=""
  INTERNAL_WS_PORT=""
  CLOUDFLARE_UUID=""
  WS_PATH=""
  HY2_PORT_RANGE=""
  HY2_AUTH=""
  HY2_OBFS_PASSWORD=""
  HY2_SNI=""
  HY2_CERT_PIN=""
  SS_PORT=""
  SS_METHOD=""
  SS_KEY=""
  SERVER_ADDRESS=""
  ROTATE="0"
  ALLOW_BITTORRENT="0"
  ALLOW_MAIL="0"
  CLI_MODE_SET="0"
  CLI_DOMAIN_SET="0"
  CLI_EMAIL_SET="0"
  CLI_CLOUDFLARE_PORT_SET="0"
  CLI_HY2_PORT_RANGE_SET="0"
  CLI_SS_PORT_SET="0"
  CLI_SERVER_ADDRESS_SET="0"
  CLI_CLOUDFLARE_UUID_SET="0"
  CLI_WS_PATH_SET="0"
  CLI_ALLOW_BITTORRENT_SET="0"
  CLI_ALLOW_MAIL_SET="0"
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

valid_hy2_port_range() {
  local range="${1:-}" start end
  [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
  start="$(normalize_port "${BASH_REMATCH[1]}")" || return 1
  end="$(normalize_port "${BASH_REMATCH[2]}")" || return 1
  valid_port "$start" && valid_port "$end" || return 1
  (( 10#$start <= 10#$end && 10#$end - 10#$start + 1 <= 1000 ))
}

normalize_hy2_port_range() {
  [[ "${1:-}" =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
  printf '%s-%s\n' "$(normalize_port "${BASH_REMATCH[1]}")" "$(normalize_port "${BASH_REMATCH[2]}")"
}

valid_server_address() {
  local address="${1:-}"
  if [[ "$address" == *:* || "$address" =~ ^[0-9.]+$ ]]; then
    printf '%s' "$address" | python3 -c '
import ipaddress
import sys

address = sys.stdin.read()
try:
    parsed = ipaddress.ip_address(address)
except ValueError:
    raise SystemExit(1)
if parsed.version == 4 and str(parsed) != address:
    raise SystemExit(1)
'
  else
    valid_domain "$address"
  fi
}

mode_needs_domain() {
  mode_has_cloudflare
}

mode_has_hysteria() {
  [[ "$MODE" == "direct" || "$MODE" == "full" ]]
}

mode_has_shadowsocks() {
  [[ "$MODE" == "direct" || "$MODE" == "full" ]]
}

mode_has_cloudflare() {
  [[ "$MODE" == "cloudflare" || "$MODE" == "full" ]]
}

resolve_default_ports() {
  case "$MODE" in
    direct)
      DOMAIN=""
      EMAIL=""
      CLOUDFLARE_PORT=""
      INTERNAL_WS_PORT=""
      CLOUDFLARE_UUID=""
      WS_PATH=""
      HY2_PORT_RANGE="${HY2_PORT_RANGE:-20000-20100}"
      SS_PORT="${SS_PORT:-8388}"
      ;;
    cloudflare)
      CLOUDFLARE_PORT="${CLOUDFLARE_PORT:-443}"
      HY2_PORT_RANGE=""
      HY2_AUTH=""
      HY2_OBFS_PASSWORD=""
      HY2_SNI=""
      HY2_CERT_PIN=""
      SS_PORT=""
      SS_METHOD=""
      SS_KEY=""
      SERVER_ADDRESS=""
      ;;
    full)
      CLOUDFLARE_PORT="${CLOUDFLARE_PORT:-443}"
      HY2_PORT_RANGE="${HY2_PORT_RANGE:-20000-20100}"
      SS_PORT="${SS_PORT:-8388}"
      ;;
    *) die "Mode must be direct, cloudflare, or full" ;;
  esac
}

choose_mode() {
  local choice=""
  printf '%s\n' "1) Direct: Hysteria2 + Shadowsocks 2022 (no domain)"
  printf '%s\n' "2) Cloudflare: VLESS + WebSocket + TLS"
  printf '%s\n' "3) Full: Cloudflare + Hysteria2 + Shadowsocks 2022 (recommended)"
  read -r -p "Select mode [3]: " choice
  case "${choice:-3}" in
    1) MODE="direct" ;;
    2) MODE="cloudflare" ;;
    3) MODE="full" ;;
    *) die "Invalid menu choice: $choice" ;;
  esac
}

prompt_cloudflare_identity() {
  if [[ -z "$DOMAIN" ]]; then
    read -r -p "Cloudflare domain (for example vpn.example.com): " DOMAIN ||
      die "Unable to read Cloudflare domain"
  fi
  if [[ -z "$EMAIL" ]]; then
    read -r -p "Email for Let's Encrypt certificate notices: " EMAIL ||
      die "Unable to read certificate email"
  fi
}

usage() {
  cat <<'USAGE'
Usage:
  sudo bash v2ray-onekey.sh [options]

Options:
  --mode direct|cloudflare|full
  --domain DOMAIN
  --email EMAIL
  --cloudflare-port PORT
  --hy2-port-range START-END
  --ss-port PORT
  --server-address ADDRESS
  --cloudflare-uuid UUID
  --ws-path /PATH
  --rotate
  --allow-bittorrent
  --allow-mail
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
        [[ "$MODE" == "direct" || "$MODE" == "cloudflare" || "$MODE" == "full" ]] ||
          die "--mode must be direct, cloudflare, or full"
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
      --cloudflare-port)
        [[ $# -ge 2 && -n "$2" ]] || die "--cloudflare-port requires a value"
        CLOUDFLARE_PORT="$2"
        CLI_CLOUDFLARE_PORT_SET="1"
        shift 2
        ;;
      --hy2-port-range)
        [[ $# -ge 2 && -n "$2" ]] || die "--hy2-port-range requires a value"
        HY2_PORT_RANGE="$2"
        CLI_HY2_PORT_RANGE_SET="1"
        shift 2
        ;;
      --ss-port)
        [[ $# -ge 2 && -n "$2" ]] || die "--ss-port requires a value"
        SS_PORT="$2"
        CLI_SS_PORT_SET="1"
        shift 2
        ;;
      --server-address)
        [[ $# -ge 2 && -n "$2" ]] || die "--server-address requires a value"
        SERVER_ADDRESS="$2"
        CLI_SERVER_ADDRESS_SET="1"
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
      --allow-mail)
        ALLOW_MAIL="1"
        CLI_ALLOW_MAIL_SET="1"
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

  if stdin_is_tty; then
    choose_mode
  else
    die "--mode is required for non-interactive use. Example: sudo bash v2ray-onekey.sh --mode full --domain vpn.example.com --email admin@example.com"
  fi
}

valid_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

validate_explicit_option_values() {
  if [[ "$CLI_DOMAIN_SET" == "1" ]]; then
    valid_domain "$DOMAIN" || die "Invalid domain: $DOMAIN"
  fi
  if [[ "$CLI_CLOUDFLARE_PORT_SET" == "1" ]]; then
    valid_cloudflare_port "$CLOUDFLARE_PORT" || die "Unsupported Cloudflare port: $CLOUDFLARE_PORT"
  fi
  if [[ "$CLI_HY2_PORT_RANGE_SET" == "1" ]]; then
    valid_hy2_port_range "$HY2_PORT_RANGE" || die "Invalid Hysteria2 port range: $HY2_PORT_RANGE"
  fi
  if [[ "$CLI_SS_PORT_SET" == "1" ]]; then
    valid_port "$SS_PORT" || die "Invalid Shadowsocks port: $SS_PORT"
  fi
  if [[ "$CLI_SERVER_ADDRESS_SET" == "1" ]]; then
    valid_server_address "$SERVER_ADDRESS" || die "Invalid server address: $SERVER_ADDRESS"
  fi
  if [[ "$CLI_CLOUDFLARE_UUID_SET" == "1" ]]; then
    valid_uuid "$CLOUDFLARE_UUID" || die "Invalid Cloudflare UUID: $CLOUDFLARE_UUID"
  fi
  if [[ "$CLI_WS_PATH_SET" == "1" ]]; then
    valid_ws_path "$WS_PATH" ||
      die "WebSocket path must use / followed by A-Z, a-z, 0-9, ., _, ~, or -"
  fi
}

validate_mode_option_compatibility() {
  if [[ "$MODE" == "cloudflare" ]]; then
    [[ "$CLI_HY2_PORT_RANGE_SET" != "1" ]] || die "--hy2-port-range cannot be used with cloudflare mode"
    [[ "$CLI_SS_PORT_SET" != "1" ]] || die "--ss-port cannot be used with cloudflare mode"
    [[ "$CLI_SERVER_ADDRESS_SET" != "1" ]] || die "--server-address cannot be used with cloudflare mode"
  elif [[ "$MODE" == "direct" ]]; then
    [[ "$CLI_CLOUDFLARE_PORT_SET" != "1" ]] || die "--cloudflare-port cannot be used with direct mode"
    [[ "$CLI_DOMAIN_SET" != "1" ]] || die "--domain cannot be used with direct mode"
    [[ "$CLI_EMAIL_SET" != "1" ]] || die "--email cannot be used with direct mode"
    [[ "$CLI_CLOUDFLARE_UUID_SET" != "1" ]] || die "--cloudflare-uuid cannot be used with direct mode"
    [[ "$CLI_WS_PATH_SET" != "1" ]] || die "--ws-path cannot be used with direct mode"
  fi
}

validate_options() {
  if [[ "${1:-}" != "state" ]]; then
    validate_explicit_option_values
    validate_mode_option_compatibility
  fi
  resolve_default_ports

  if mode_needs_domain; then
    [[ -n "$DOMAIN" ]] || die "--domain is required for $MODE mode"
    [[ -n "$EMAIL" ]] || die "--email is required for $MODE mode"
  fi

  [[ -z "$DOMAIN" ]] || valid_domain "$DOMAIN" || die "Invalid domain: $DOMAIN"
  [[ -z "$DOMAIN" ]] || DOMAIN="$(normalize_domain "$DOMAIN")"

  if mode_has_cloudflare; then
    valid_cloudflare_port "$CLOUDFLARE_PORT" || die "Unsupported Cloudflare port: $CLOUDFLARE_PORT"
    CLOUDFLARE_PORT="$(normalize_port "$CLOUDFLARE_PORT")"
  fi
  if mode_has_hysteria; then
    valid_hy2_port_range "$HY2_PORT_RANGE" || die "Invalid Hysteria2 port range: $HY2_PORT_RANGE"
    HY2_PORT_RANGE="$(normalize_hy2_port_range "$HY2_PORT_RANGE")"
  fi
  if mode_has_shadowsocks; then
    valid_port "$SS_PORT" || die "Invalid Shadowsocks port: $SS_PORT"
    SS_PORT="$(normalize_port "$SS_PORT")"
  fi

  [[ -z "$SERVER_ADDRESS" ]] || valid_server_address "$SERVER_ADDRESS" ||
    die "Invalid server address: $SERVER_ADDRESS"
  [[ -z "$CLOUDFLARE_UUID" ]] || valid_uuid "$CLOUDFLARE_UUID" || die "Invalid Cloudflare UUID: $CLOUDFLARE_UUID"
  [[ -z "$WS_PATH" ]] || valid_ws_path "$WS_PATH" ||
    die "WebSocket path must use / followed by A-Z, a-z, 0-9, ., _, ~, or -"
}

STATE_KEYS=(
  STATE_SCHEMA MODE DOMAIN EMAIL CLOUDFLARE_PORT INTERNAL_WS_PORT
  CLOUDFLARE_UUID WS_PATH HY2_PORT_RANGE HY2_AUTH HY2_OBFS_PASSWORD
  HY2_SNI HY2_CERT_PIN SS_PORT SS_METHOD SS_KEY SERVER_ADDRESS
  ALLOW_BITTORRENT ALLOW_MAIL
)

LEGACY_STATE_KEYS=(
  STATE_SCHEMA MODE DOMAIN EMAIL REALITY_PORT CLOUDFLARE_PORT INTERNAL_WS_PORT
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

legacy_state_key_allowed() {
  local key="$1"
  local allowed=""
  for allowed in "${LEGACY_STATE_KEYS[@]}"; do
    [[ "$key" == "$allowed" ]] && return 0
  done
  return 1
}

state_record_is_shell_escaped() {
  python3 -c '
import sys

record = sys.stdin.buffer.read().split(b"\0")
if len(record) != 3 or record[2]:
    raise SystemExit(1)
key = record[0].decode("ascii")
value = record[1].decode("utf-8")
if not key:
    raise SystemExit(1)
safe = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
index = 0
while index < len(value):
    character = value[index]
    if character in safe:
        index += 1
    elif character == "\\":
        index += 2
    elif value.startswith(chr(39) * 2, index):
        index += 2
    elif value.startswith("$" + chr(39), index):
        index += 2
        while index < len(value):
            if value[index] == "\\":
                index += 2
            elif value[index] == chr(39):
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
'
}

validate_loaded_runtime_values() {
  if mode_has_cloudflare; then
    valid_uuid "$CLOUDFLARE_UUID" || die "Invalid Cloudflare UUID in state"
    valid_port "$INTERNAL_WS_PORT" || die "Invalid internal WebSocket port: $INTERNAL_WS_PORT"
    [[ "$INTERNAL_WS_PORT" != "$CLOUDFLARE_PORT" ]] ||
      die "Internal WebSocket port must not match a public port"
    valid_ws_path "$WS_PATH" || die "WebSocket path must start with / and contain no whitespace"
  else
    [[ -z "$CLOUDFLARE_UUID" && -z "$INTERNAL_WS_PORT" && -z "$WS_PATH" ]] ||
      die "Inactive Cloudflare state must not contain credentials"
  fi

  if ! mode_has_hysteria; then
    [[ -z "$HY2_AUTH$HY2_OBFS_PASSWORD$HY2_SNI$HY2_CERT_PIN" ]] ||
      die "Inactive Hysteria2 state must not contain credentials"
  fi
  if ! mode_has_shadowsocks; then
    [[ -z "$SS_METHOD$SS_KEY" ]] ||
      die "Inactive Shadowsocks state must not contain settings or credentials"
  fi
}

valid_ws_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._~\-]+$ ]]
}

save_state() (
  local state_dir state_name temp_state key
  STATE_SCHEMA="2"
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
  local owner mode line key value loaded_schema="1"
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
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "Malformed state assignment"
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if ! state_key_allowed "$key" && ! legacy_state_key_allowed "$key"; then
      die "State contains unexpected assignment: $key"
    fi
    [[ -z "${seen[$key]:-}" ]] || die "State contains duplicate assignment: $key"
    printf '%s\0%s\0' "$key" "$value" | state_record_is_shell_escaped ||
      die "Malformed state value for $key"
    if [[ "$key" == "STATE_SCHEMA" ]]; then
      [[ "$value" == "1" || "$value" == "2" ]] || die "Unsupported state schema: $value"
      loaded_schema="$value"
    fi
    seen["$key"]=1
  done <"$STATE_FILE"

  case "$loaded_schema" in
    1)
      for key in "${LEGACY_STATE_KEYS[@]}"; do
        [[ "$key" == "STATE_SCHEMA" ]] && continue
        [[ "${seen[$key]:-}" == "1" ]] || die "State is missing assignment: $key"
      done
      for key in "${!seen[@]}"; do
        legacy_state_key_allowed "$key" || die "Schema 1 state contains unexpected assignment: $key"
      done
      ;;
    2)
      for key in "${STATE_KEYS[@]}"; do
        [[ "${seen[$key]:-}" == "1" ]] || die "State is missing assignment: $key"
      done
      for key in "${!seen[@]}"; do
        state_key_allowed "$key" || die "Schema 2 state contains unexpected assignment: $key"
      done
      ;;
    *) die "Unsupported state schema: $loaded_schema" ;;
  esac

  if [[ "$loaded_schema" == "1" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      key="${line%%=*}"
      case "$key" in
        MODE|DOMAIN|EMAIL|CLOUDFLARE_PORT|INTERNAL_WS_PORT|CLOUDFLARE_UUID|WS_PATH|ALLOW_BITTORRENT)
          # The allowlist and shell-escape parser above make this assignment inert data.
          # shellcheck disable=SC1091
          source /dev/stdin <<<"$line"
          ;;
      esac
    done <"$STATE_FILE"
    case "$MODE" in
      reality)
        die "Automatic REALITY-only migration is unsafe; use the dedicated migration path or choose a supported mode"
        ;;
      cloudflare) MODE="cloudflare" ;;
      dual) MODE="full" ;;
      *) die "Invalid legacy mode in state: $MODE" ;;
    esac
    STATE_SCHEMA="2"
    HY2_PORT_RANGE=""
    HY2_AUTH=""
    HY2_OBFS_PASSWORD=""
    HY2_SNI=""
    HY2_CERT_PIN=""
    SS_PORT=""
    SS_METHOD=""
    SS_KEY=""
    SERVER_ADDRESS=""
    ALLOW_MAIL="0"
  else
    # The allowlist and shell-escape parser above make these assignments inert data.
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
  ROTATE="0"
  validate_options state
  validate_loaded_runtime_values
}

random_internal_ws_port() {
  local candidate attempts=0
  while (( attempts < 32 )); do
    candidate="$(shuf -i 20000-50000 -n 1)" || die "Unable to select an internal WebSocket port"
    if [[ "$candidate" != "$CLOUDFLARE_PORT" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    ((attempts += 1))
  done
  die "Unable to select an internal WebSocket port without a public-port collision"
}

generate_runtime_values() {
  if mode_has_cloudflare; then
    [[ -n "$CLOUDFLARE_UUID" ]] || CLOUDFLARE_UUID="$(xray uuid)"
    [[ -n "$INTERNAL_WS_PORT" ]] || INTERNAL_WS_PORT="$(random_internal_ws_port)"
    [[ -n "$WS_PATH" ]] || WS_PATH="/$(openssl rand -hex 12)"
  fi
}

rotate_runtime_values() {
  CLOUDFLARE_UUID=""
  INTERNAL_WS_PORT=""
  WS_PATH=""
  HY2_AUTH=""
  HY2_OBFS_PASSWORD=""
  HY2_SNI=""
  HY2_CERT_PIN=""
  SS_KEY=""
}

prepare_configuration() {
  local cli_mode="$MODE" cli_domain="$DOMAIN" cli_email="$EMAIL"
  local cli_cloudflare_port="$CLOUDFLARE_PORT" cli_hy2_port_range="$HY2_PORT_RANGE"
  local cli_ss_port="$SS_PORT" cli_server_address="$SERVER_ADDRESS"
  local cli_cloudflare_uuid="$CLOUDFLARE_UUID" cli_ws_path="$WS_PATH"
  local cli_rotate="$ROTATE" cli_allow_bittorrent="$ALLOW_BITTORRENT"
  local cli_allow_mail="$ALLOW_MAIL"
  local saved_mode=""

  if [[ -f "$STATE_FILE" ]]; then
    load_state
    saved_mode="$MODE"
    if [[ "$CLI_MODE_SET" == "1" ]]; then MODE="$cli_mode"; fi
    if [[ "$CLI_DOMAIN_SET" == "1" ]]; then DOMAIN="$cli_domain"; fi
    if [[ "$CLI_EMAIL_SET" == "1" ]]; then EMAIL="$cli_email"; fi
    if [[ "$CLI_CLOUDFLARE_PORT_SET" == "1" ]]; then CLOUDFLARE_PORT="$cli_cloudflare_port"; fi
    if [[ "$CLI_HY2_PORT_RANGE_SET" == "1" ]]; then HY2_PORT_RANGE="$cli_hy2_port_range"; fi
    if [[ "$CLI_SS_PORT_SET" == "1" ]]; then SS_PORT="$cli_ss_port"; fi
    if [[ "$CLI_SERVER_ADDRESS_SET" == "1" ]]; then SERVER_ADDRESS="$cli_server_address"; fi
    if [[ "$CLI_CLOUDFLARE_UUID_SET" == "1" ]]; then CLOUDFLARE_UUID="$cli_cloudflare_uuid"; fi
    if [[ "$CLI_WS_PATH_SET" == "1" ]]; then WS_PATH="$cli_ws_path"; fi
    if [[ "$CLI_ALLOW_BITTORRENT_SET" == "1" ]]; then ALLOW_BITTORRENT="$cli_allow_bittorrent"; fi
    if [[ "$CLI_ALLOW_MAIL_SET" == "1" ]]; then ALLOW_MAIL="$cli_allow_mail"; fi
    ROTATE="$cli_rotate"
    if [[ "$MODE" != "$saved_mode" && "$ROTATE" != "1" ]]; then
      die "Changing an existing deployment mode requires --rotate"
    fi
  else
    select_mode
  fi

  if mode_needs_domain && stdin_is_tty; then
    prompt_cloudflare_identity
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

legacy_nginx_config_path() {
  [[ "$1" != "$NGINX_SITE" && "$1" =~ ^/etc/nginx/conf\.d/v2ray-[A-Za-z0-9.-]+\.conf$ ]]
}

nginx_config_has_owned_shape() {
  local path="$1" shape="$2"
  awk -v shape="$shape" '
function trim(value) {
  sub(/^[[:space:]]+/, "", value)
  sub(/[[:space:]]+$/, "", value)
  return value
}

function regex_count(value, pattern, count) {
  count = 0
  while (match(value, pattern)) {
    count += 1
    value = substr(value, RSTART + RLENGTH)
  }
  return count
}

function one_server_block(value) {
  return regex_count(value, "(^|[[:space:]])server[[:space:]]*\\{") == 1
}

function block_server_name(value,    lines, count, line_number, line, name) {
  count = split(value, lines, "\n")
  name = ""
  for (line_number = 1; line_number <= count; line_number += 1) {
    line = trim(lines[line_number])
    if (line ~ /^server_name[[:space:]]+/) {
      sub(/^server_name[[:space:]]+/, "", line)
      sub(/;.*/, "", line)
      line = trim(line)
      if (name != "" || line == "" || line ~ /[[:space:]]/) return ""
      name = line
    }
  }
  return name
}

function legacy_proxy_block(value) {
  return one_server_block(value) &&
    block_server_name(value) != "" &&
    index(value, "proxy_set_header Upgrade") &&
    index(value, "proxy_pass http://127.0.0.1:") &&
    index(value, "return 200 \"ok")
}

function certbot_auxiliary_block(value, marker) {
  return marker && one_server_block(value) &&
    block_server_name(value) != "" &&
    !index(value, "proxy_pass ") &&
    regex_count(value, "(^|[[:space:]])location[[:space:]]") == 0 &&
    (index(value, "return 301 https://$host$request_uri;") ||
      regex_count(value, "return[[:space:]]+404[[:space:]]*;") == 1)
}

function managed_http_block(value) {
  return one_server_block(value) &&
    regex_count(value, "(^|[[:space:]])listen[[:space:]]") == 2 &&
    index(value, "listen 80;") &&
    index(value, "listen [::]:80;") &&
    regex_count(value, "(^|[[:space:]])server_name[[:space:]]") == 1 &&
    index(value, "location ^~ /.well-known/acme-challenge/ {") &&
    regex_count(value, "(^|[[:space:]])location[[:space:]]") == 2 &&
    regex_count(value, "(^|[[:space:]])root[[:space:]]") == 1 &&
    index(value, "location / {") &&
    regex_count(value, "return[[:space:]]+200[[:space:]]+\"ok") == 1 &&
    !index(value, "proxy_pass ")
}

function managed_tls_block(value) {
  return one_server_block(value) &&
    regex_count(value, "(^|[[:space:]])listen[[:space:]]") == 2 &&
    regex_count(value, "listen[[:space:]]+[0-9]+[[:space:]]+ssl;") == 1 &&
    regex_count(value, "listen[[:space:]]+\\[::\\]:[0-9]+[[:space:]]+ssl;") == 1 &&
    regex_count(value, "(^|[[:space:]])server_name[[:space:]]") == 1 &&
    regex_count(value, "(^|[[:space:]])ssl_certificate[[:space:]]") == 1 &&
    regex_count(value, "(^|[[:space:]])ssl_certificate_key[[:space:]]") == 1 &&
    index(value, "ssl_protocols TLSv1.2 TLSv1.3;") &&
    regex_count(value, "(^|[[:space:]])location[[:space:]]") == 2 &&
    regex_count(value, "location[[:space:]]*=[[:space:]]*/[A-Za-z0-9._~-]+[[:space:]]*\\{") == 1 &&
    regex_count(value, "proxy_pass[[:space:]]+http://127\\.0\\.0\\.1:[0-9]+;") == 1 &&
    index(value, "proxy_http_version 1.1;") &&
    index(value, "proxy_set_header Upgrade $http_upgrade;") &&
    index(value, "proxy_set_header Connection \"upgrade\";") &&
    index(value, "proxy_set_header Host $host;") &&
    index(value, "proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;") &&
    index(value, "proxy_read_timeout 3600s;") &&
    index(value, "proxy_send_timeout 3600s;") &&
    index(value, "proxy_buffering off;") &&
    index(value, "location / {") &&
    regex_count(value, "return[[:space:]]+200[[:space:]]+\"ok") == 1 &&
    !index(value, "location ^~ /.well-known/acme-challenge/")
}

{
  if ($0 ~ /^[[:space:]]*#[[:space:]]*Managed by v2ray-onekey[[:space:]]*$/) {
    marker_count += 1
  }
  if (depth > 0 && tolower($0) ~ /managed by certbot/) {
    certbot_marker[block_count] = 1
  }
  line = $0 "\n"
  for (position = 1; position <= length(line); position += 1) {
    character = substr(line, position, 1)
    if (comment) {
      if (character == "\n") {
        comment = 0
        if (depth > 0) block = block character
        else outside = outside character
      }
      continue
    }
    if (quote != "") {
      if (depth > 0) block = block character
      else outside = outside character
      if (escaped) escaped = 0
      else if (character == "\\") escaped = 1
      else if (character == quote) quote = ""
      continue
    }
    if (character == "#") {
      comment = 1
      continue
    }
    if (character == "\"" || character == "\047") {
      quote = character
      if (depth > 0) block = block character
      else outside = outside character
      continue
    }
    if (depth == 0) {
      if (character == "{") {
        if (trim(outside) != "server") invalid = 1
        outside = ""
        block_count += 1
        block = "server {"
        depth = 1
      } else if (character == "}") {
        invalid = 1
      } else {
        outside = outside character
      }
    } else {
      block = block character
      if (character == "{") depth += 1
      else if (character == "}") {
        depth -= 1
        if (depth == 0) {
          blocks[block_count] = block
          block = ""
        }
      }
    }
  }
}

END {
  if (invalid || depth != 0 || quote != "" || trim(outside) != "") exit 1
  if (shape == "legacy") {
    if (block_count < 1 || block_count > 3) exit 1
    project_blocks = 0
    expected_name = ""
    for (block_number = 1; block_number <= block_count; block_number += 1) {
      name = block_server_name(blocks[block_number])
      if (legacy_proxy_block(blocks[block_number])) {
        project_blocks += 1
        if (expected_name == "") expected_name = name
      } else if (!certbot_auxiliary_block(blocks[block_number], certbot_marker[block_number])) {
        exit 1
      }
    }
    if (project_blocks != 1 || expected_name == "") exit 1
    for (block_number = 1; block_number <= block_count; block_number += 1) {
      if (block_server_name(blocks[block_number]) != expected_name) exit 1
    }
    exit 0
  }
  if (shape == "current") {
    if (marker_count != 1 || !managed_http_block(blocks[1])) exit 1
    if (block_count == 1) exit 0
    if (block_count == 2 && managed_tls_block(blocks[2])) exit 0
    exit 1
  }
  exit 1
}
' "$path"
}

legacy_nginx_config_is_project_owned() {
  local path="$1"
  legacy_nginx_config_path "$path" || return 1
  [[ -f "$path" && ! -L "$path" ]] || return 1
  nginx_config_has_owned_shape "$path" legacy
}

current_nginx_config_is_project_owned() {
  local path="$1"
  [[ "$path" == "$NGINX_SITE" && -f "$path" && ! -L "$path" ]] || return 1
  nginx_config_has_owned_shape "$path" current
}

validate_managed_destination_ownership() {
  if mode_has_cloudflare; then
    if [[ -e "$NGINX_SITE" || -L "$NGINX_SITE" ]] &&
      ! current_nginx_config_is_project_owned "$NGINX_SITE"; then
      die "Refusing to overwrite Nginx site without v2ray-onekey ownership signatures: $NGINX_SITE"
    fi
    if [[ -e "$RENEWAL_HOOK" || -L "$RENEWAL_HOOK" ]] &&
      ! current_renewal_hook_is_project_owned "$RENEWAL_HOOK"; then
      die "Refusing to overwrite renewal hook without exact v2ray-onekey ownership: $RENEWAL_HOOK"
    fi
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
  while IFS= read -r path; do
    legacy_nginx_config_is_project_owned "$path" && return 0
  done < <(legacy_nginx_config_paths)
  return 1
}

legacy_nginx_config_paths() {
  local path
  for path in /etc/nginx/conf.d/v2ray-*.conf; do
    [[ -e "$path" || -L "$path" ]] || continue
    printf '%s\n' "$path"
  done
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

lock_directory_is_safe() {
  local path="$1" mode owner
  [[ -d "$path" && ! -L "$path" ]] || return 1
  mode="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
  owner="$(stat -c '%u' "$path" 2>/dev/null)" || return 1
  [[ "$mode" == "700" && "$owner" == "0" ]]
}

lock_has_only_owner_file() {
  local entry count=0
  for entry in "$DEPLOYMENT_LOCK_DIR"/* "$DEPLOYMENT_LOCK_DIR"/.[!.]* "$DEPLOYMENT_LOCK_DIR"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    ((count += 1))
    [[ "$entry" == "$DEPLOYMENT_LOCK_DIR/owner" ]] || return 1
  done
  [[ "$count" -eq 1 && -f "$DEPLOYMENT_LOCK_DIR/owner" && ! -L "$DEPLOYMENT_LOCK_DIR/owner" ]]
}

acquire_deployment_lock() {
  local owner owner_mode owner_uid lock_pid="$BASHPID" lock_parent
  [[ "${LOCK_HELD:-0}" != "1" ]] || return 0
  [[ "$DEPLOYMENT_LOCK_DIR" == /* && "$DEPLOYMENT_LOCK_DIR" != *$'\n'* ]] ||
    die "Invalid deployment lock path: $DEPLOYMENT_LOCK_DIR"
  lock_parent="$(dirname "$DEPLOYMENT_LOCK_DIR")"
  [[ ! -L "$lock_parent" ]] || die "Refusing symlink deployment lock parent: $lock_parent"
  [[ -d "$lock_parent" ]] || install -d -m 0755 "$lock_parent"

  if mkdir -m 0700 -- "$DEPLOYMENT_LOCK_DIR" 2>/dev/null; then
    if ! (umask 077; printf '%s\n' "$lock_pid" >"$DEPLOYMENT_LOCK_DIR/owner"); then
      rm -f -- "$DEPLOYMENT_LOCK_DIR/owner"
      rmdir -- "$DEPLOYMENT_LOCK_DIR" 2>/dev/null || true
      die "Unable to record deployment lock owner: $DEPLOYMENT_LOCK_DIR"
    fi
    if ! chmod 0600 "$DEPLOYMENT_LOCK_DIR/owner"; then
      rm -f -- "$DEPLOYMENT_LOCK_DIR/owner"
      rmdir -- "$DEPLOYMENT_LOCK_DIR" 2>/dev/null || true
      die "Unable to secure deployment lock owner: $DEPLOYMENT_LOCK_DIR/owner"
    fi
    LOCK_HELD="1"
    return 0
  fi

  lock_directory_is_safe "$DEPLOYMENT_LOCK_DIR" ||
    die "Unsafe deployment lock exists; inspect manually: $DEPLOYMENT_LOCK_DIR"
  if lock_has_only_owner_file; then
    owner_mode="$(stat -c '%a' "$DEPLOYMENT_LOCK_DIR/owner" 2>/dev/null)" || true
    owner_uid="$(stat -c '%u' "$DEPLOYMENT_LOCK_DIR/owner" 2>/dev/null)" || true
    IFS= read -r owner <"$DEPLOYMENT_LOCK_DIR/owner" || true
    if [[ "$owner_mode" == "600" && "$owner_uid" == "0" && "$owner" =~ ^[1-9][0-9]*$ ]] &&
      kill -0 "$owner" 2>/dev/null; then
      die "Another v2ray-onekey deployment is already running (PID $owner)"
    fi
  fi
  die "Deployment lock owner is stale or invalid. Verify no installer is running, then manually remove this exact lock directory: $DEPLOYMENT_LOCK_DIR"
}

release_deployment_lock() {
  local owner=""
  [[ "${LOCK_HELD:-0}" == "1" ]] || return 0
  if lock_directory_is_safe "$DEPLOYMENT_LOCK_DIR" && lock_has_only_owner_file; then
    IFS= read -r owner <"$DEPLOYMENT_LOCK_DIR/owner" || true
  fi
  if [[ "$owner" == "$BASHPID" ]]; then
    rm -f -- "$DEPLOYMENT_LOCK_DIR/owner" || true
    rmdir -- "$DEPLOYMENT_LOCK_DIR" 2>/dev/null ||
      warn "Could not remove deployment lock directory: $DEPLOYMENT_LOCK_DIR"
  else
    warn "Deployment lock ownership changed; leaving it for inspection: $DEPLOYMENT_LOCK_DIR"
  fi
  LOCK_HELD="0"
  return 0
}

create_unique_backup_directory() {
  local attempt candidate
  [[ "$BACKUP_ROOT" == /* && "$BACKUP_ROOT" != *$'\n'* ]] || die "Invalid backup root: $BACKUP_ROOT"
  [[ -L "$BACKUP_ROOT" ]] && die "Refusing symlink backup root: $BACKUP_ROOT"
  install -d -m 0700 "$BACKUP_ROOT"
  for ((attempt = 0; attempt < 100; attempt += 1)); do
    candidate="$BACKUP_ROOT/$RUN_TIMESTAMP"
    [[ "$attempt" -eq 0 ]] || candidate="${candidate}-${BASHPID}-${attempt}"
    if mkdir -m 0700 -- "$candidate" 2>/dev/null; then
      BACKUP_DIR="$candidate"
      return 0
    fi
    [[ -e "$candidate" || -L "$candidate" ]] ||
      die "Unable to create backup directory: $candidate"
  done
  die "Unable to allocate a unique backup directory under $BACKUP_ROOT"
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
  while IFS= read -r path; do
    if legacy_nginx_config_is_project_owned "$path"; then
      backup_file "$path"
      printf '%s\n' "$path" >>"$BACKUP_DIR/legacy-files"
    fi
  done < <(legacy_nginx_config_paths)
}

begin_transaction() {
  local managed_path
  RUN_TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  create_unique_backup_directory
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
    systemctl stop "$service" >/dev/null 2>&1 || true
  done <"$BACKUP_DIR/services"

  while IFS=$'\t' read -r service state enabled; do
    [[ -n "$service" ]] || continue
    if [[ "$state" == "active" ]]; then
      systemctl restart "$service" >/dev/null 2>&1 || warn "Could not restart $service during rollback"
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

analyze_nginx_configuration() {
  local analysis="$1" port="$2" domain="${3:-}" nginx_output
  nginx_output="$(nginx -T 2>&1)" || return 2
  printf '%s\n' "$nginx_output" | python3 -c '
import re
import sys

analysis, raw_port, domain, current_path = sys.argv[1:]
port = re.escape(raw_port)
domain = domain.lower()
legacy_path = re.compile(r"/etc/nginx/conf\.d/v2ray-[A-Za-z0-9.-]+\.conf")
header = re.compile(r"^# configuration file (.+):$")
listen = re.compile(
    rf"^\s*listen\s+(?:(?:\[[0-9A-Fa-f:]+\]|[0-9.]+):)?{port}(?=\s|;)",
    re.MULTILINE,
)
any_listen = re.compile(r"^\s*listen\s+[^;]+;", re.MULTILINE)
server_name = re.compile(r"^\s*server_name\s+([^;]+);", re.MULTILINE)
legacy_signatures = (
    "proxy_set_header Upgrade",
    "proxy_pass http://127.0.0.1:",
    "return 200 \"ok",
)


def file_sections(lines):
    path = None
    content = []
    for line in lines:
        match = header.match(line.rstrip("\n"))
        if match:
            if path is not None:
                yield path, "".join(content)
            path = match.group(1)
            content = []
        elif path is not None:
            content.append(line)
    if path is not None:
        yield path, "".join(content)


def matching_brace(text, opening):
    depth = 0
    quote = None
    escaped = False
    comment = False
    for index in range(opening, len(text)):
        character = text[index]
        if comment:
            if character == "\n":
                comment = False
            continue
        if quote:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = None
            continue
        if character == "#":
            comment = True
        elif character in ("\"", chr(39)):
            quote = character
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return index
    return None


def server_blocks(content):
    position = 0
    start_pattern = re.compile(r"\bserver\s*\{")
    while True:
        match = start_pattern.search(content, position)
        if not match:
            return
        opening = content.find("{", match.start())
        closing = matching_brace(content, opening)
        if closing is None:
            return
        yield content[match.start():closing + 1]
        position = closing + 1


def block_is_owned(path, file_content, block):
    legacy_file = path != current_path and legacy_path.fullmatch(path) is not None
    legacy_owned = (
        legacy_file
        and all(signature in block for signature in legacy_signatures)
    )
    certbot_auxiliary = (
        legacy_file
        and "managed by certbot" in block.lower()
        and server_name.search(block) is not None
        and "proxy_pass " not in block
        and (
            "return 301 https://$host$request_uri;" in block
            or re.search(r"\breturn\s+404\s*;", block) is not None
        )
    )
    if legacy_owned or certbot_auxiliary:
        return True
    if path != current_path or "# Managed by v2ray-onekey" not in file_content:
        return False
    if "return 200 \"ok" not in block or not server_name.search(block):
        return False
    proxy_block = all(signature in block for signature in legacy_signatures)
    acme_block = (
        "location ^~ /.well-known/acme-challenge/" in block
        and re.search(r"^\s*root\s+[^;]+;", block, re.MULTILINE) is not None
    )
    return proxy_block or acme_block


matching_blocks = []
for path, file_content in file_sections(sys.stdin):
    for block in server_blocks(file_content):
        explicit_listen = any_listen.search(block) is not None
        listens_on_port = listen.search(block) is not None
        if not listens_on_port and not (not explicit_listen and raw_port == "80"):
            continue
        names = {
            name.lower()
            for match in server_name.finditer(block)
            for name in match.group(1).split()
        }
        matching_blocks.append((block_is_owned(path, file_content, block), names))

if analysis == "all-owned":
    raise SystemExit(0 if matching_blocks and all(owned for owned, _ in matching_blocks) else 1)
if analysis == "domain-conflict":
    conflict = any(domain in names and not owned for owned, names in matching_blocks)
    raise SystemExit(0 if conflict else 1)
raise SystemExit(2)
' "$analysis" "$port" "$domain" "$NGINX_SITE"
}

legacy_nginx_config_for_port_is_project_owned() {
  analyze_nginx_configuration all-owned "$1"
}

nginx_has_unmanaged_domain_conflict() {
  local status=0
  analyze_nginx_configuration domain-conflict "$1" "$2" && return 0
  status=$?
  [[ "$status" -eq 1 ]] && return 1
  return 0
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
    [[ "$listener" == *nginx* ]] && continue
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

resolve_cloudflare_port() {
  local attempt replacement full_listeners
  for attempt in 1 2 3 4 5; do
    port_listener_conflicts cloudflare "$CLOUDFLARE_PORT" || return 0
    if ! stdin_is_tty; then
      full_listeners="$(complete_listener_diagnostics)"
      die "TCP port $CLOUDFLARE_PORT is occupied. Rerun using --cloudflare-port PORT. Conflict: $PORT_CONFLICT_DETAILS
ss -lntp output:
$full_listeners"
    fi
    warn "TCP port $CLOUDFLARE_PORT is unavailable: $PORT_CONFLICT_DETAILS"
    read -r -p "Enter a replacement Cloudflare port (or q to cancel): " replacement ||
      die "Port selection cancelled"
    [[ "$replacement" != "q" && "$replacement" != "Q" ]] || die "Port selection cancelled"
    valid_cloudflare_port "$replacement" || {
      warn "Cloudflare HTTPS ports: 443, 2053, 2083, 2087, 2096, 8443"
      continue
    }
    replacement="$(normalize_port "$replacement")"
    CLOUDFLARE_PORT="$replacement"
    port_listener_conflicts cloudflare "$replacement" || return 0
  done
  die "Unable to select an available Cloudflare port after 5 attempts"
}

resolve_public_port_conflicts() {
  local full_listeners=""
  mode_has_cloudflare || return 0
  resolve_cloudflare_port
  if port_listener_conflicts acme 80; then
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

direct_bundle_ready() {
  return 1
}

require_mode_ready() {
  if mode_has_hysteria || mode_has_shadowsocks; then
    direct_bundle_ready || die "Direct bundle is not available in this build yet"
  fi
}

preflight_environment() {
  require_mode_ready
  [[ "$(uname -s)" == "Linux" ]] || die "This script requires Linux"
  [[ "$(id -u)" -eq 0 ]] || die "Please run as root"
  command -v systemctl >/dev/null 2>&1 || die "systemd is required"
  detect_pkg_manager
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
  local -a base_packages=(curl ca-certificates openssl python3 coreutils gawk)
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    base_packages+=(iproute2)
  else
    base_packages+=(iproute)
  fi
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
    "$INTERNAL_WS_PORT" \
    "$CLOUDFLARE_UUID" \
    "$WS_PATH" \
    "$ALLOW_BITTORRENT" <<'PY' || render_status=$?
import json
import sys


(
    output_path,
    mode,
    internal_ws_port,
    cloudflare_uuid,
    ws_path,
    allow_bittorrent,
) = sys.argv[1:]

sniffing = {
    "enabled": True,
    "destOverride": ["http", "tls", "quic"],
    "routeOnly": True,
}
inbounds = []

if mode in ("cloudflare", "full"):
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

open_firewall_port() {
  local port="$1"
  local proto="${2:-tcp}"

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    if ! ufw allow "${port}/${proto}" >/dev/null; then
      warn "UFW failed to allow ${port}/${proto}; add this rule manually"
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    if ! firewall-cmd --add-port="${port}/${proto}" >/dev/null; then
      warn "firewalld failed to add runtime rule ${port}/${proto}; add it manually"
    fi
    if ! firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null; then
      warn "firewalld failed to add permanent rule ${port}/${proto}; add it manually"
    fi
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
  systemctl enable nginx
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl start nginx
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

print_service_diagnostics() {
  local service="$1"
  warn "Recent $service service diagnostics:"
  systemctl status "$service" --no-pager --full 2>&1 || true
  journalctl -u "$service" -n 30 --no-pager 2>&1 || true
}

wait_for_listener_owner() {
  local port="$1" owner="$2" binding="${3:-}" output attempt
  for ((attempt = 1; attempt <= LISTENER_WAIT_ATTEMPTS; attempt++)); do
    output="$(listener_output "$port")" || die "Unable to inspect listener on TCP $port: $output"
    if [[ -n "$output" && "$output" == *"$owner"* ]]; then
      if [[ -z "$binding" || "$output" == *"$binding:$port"* ]]; then
        return 0
      fi
    fi
    (( attempt < LISTENER_WAIT_ATTEMPTS )) && sleep "$LISTENER_WAIT_INTERVAL"
  done
  print_service_diagnostics "$owner"
  require_listener_owner "$port" "$owner" "$binding"
}

verify_started_services() {
  systemctl is-active --quiet xray || die "Xray is not active after restart"
  if mode_has_cloudflare; then
    systemctl is-active --quiet nginx || die "Nginx is not active after reload"
    wait_for_listener_owner "$INTERNAL_WS_PORT" xray 127.0.0.1
    wait_for_listener_owner "$CLOUDFLARE_PORT" nginx
    wait_for_listener_owner 80 nginx
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
}

required_public_ports() {
  local -a ports=()
  mode_has_cloudflare && ports+=(80 "$CLOUDFLARE_PORT")
  ((${#ports[@]} > 0)) && printf '%s\n' "${ports[@]}"
}

print_deployment_summary() {
  local port_list=""
  port_list="$(required_public_ports | paste -sd, -)"
  printf '\n'
  if mode_has_cloudflare; then
    printf 'Cloudflare entry: VLESS + WebSocket + TLS\n'
    make_cloudflare_link
  fi
  printf 'State file: %s\n' "$STATE_FILE"
  printf 'Backup: %s\n' "$BACKUP_DIR"
  if mode_has_cloudflare; then
    printf 'Open these TCP ports in the cloud security group: %s\n' "$port_list"
    printf 'Diagnostics: systemctl status xray; journalctl -u xray -e; nginx -t\n'
  else
    printf 'No public listeners are configured for direct mode in this installer stage.\n'
    printf 'Diagnostics: systemctl status xray; journalctl -u xray -e\n'
  fi
}

prepare_runtime_directory() {
  RUNTIME_DIR="${RUNTIME_DIR:-/run/v2ray-onekey/$RUN_TIMESTAMP}"
  install -d -m 700 "$RUNTIME_DIR"
}

deploy_services() {
  local staged_xray staged_nginx_initial staged_nginx_final

  require_mode_ready
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
  if [[ "${TRANSACTION_ACTIVE:-0}" != "1" ]]; then
    exit "$status"
  fi
  TRANSACTION_ACTIVE="0"
  set +e
  if [[ "$status" -eq 0 ]]; then
    status=1
    warn "Deployment ended before the transaction was completed"
  fi
  warn "Deployment failed; restoring files from ${BACKUP_DIR:-the current backup}"
  rollback_current_run || warn "Automatic rollback was incomplete"
  release_deployment_lock
  exit "$status"
}

activate_transaction_traps() {
  TRANSACTION_ACTIVE="1"
  trap transaction_exit_handler EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

complete_transaction() {
  release_deployment_lock
  TRANSACTION_ACTIVE="0"
  trap - EXIT ERR INT TERM
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
  acquire_deployment_lock
  deploy_services
  complete_transaction
}

if [[ "${V2RAY_ONEKEY_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
