#!/usr/bin/env bash
INSTALLER_VARIANT="new"

APP_NAME="v2ray-onekey"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
STATE_FILE="${STATE_FILE:-/etc/v2ray-onekey/state.env}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/v2ray-onekey}"
DEPLOYMENT_LOCK_DIR="${DEPLOYMENT_LOCK_DIR:-/run/lock/v2ray-onekey}"
NGINX_SITE="${NGINX_SITE:-/etc/nginx/conf.d/v2ray-onekey.conf}"
RENEWAL_HOOK="${RENEWAL_HOOK:-/etc/letsencrypt/renewal-hooks/deploy/v2ray-onekey-nginx.sh}"
LETSENCRYPT_LIVE_ROOT="${LETSENCRYPT_LIVE_ROOT:-/etc/letsencrypt/live}"
LEGACY_V2RAY_CONFIG="${LEGACY_V2RAY_CONFIG:-/usr/local/etc/v2ray/config.json}"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
XRAY_BIN="/usr/local/bin/xray"
XRAY_DATA_DIR="/usr/local/share/xray"
XRAY_LOG_DIR="/var/log/xray"
XRAY_SYSTEMD_DIR="/etc/systemd/system"
HYSTERIA_DOWNLOAD_URL="https://download.hysteria.network/app/latest/hysteria-linux-amd64"
HYSTERIA_BIN="/usr/local/bin/hysteria"
HYSTERIA_CONFIG="/etc/hysteria/config.yaml"
HYSTERIA_ACL="/etc/hysteria/acl.txt"
HYSTERIA_CERT="/etc/hysteria/server.crt"
HYSTERIA_KEY="/etc/hysteria/server.key"
HYSTERIA_UNIT="/etc/systemd/system/hysteria-server.service"
HYSTERIA_OWNERSHIP_MANIFEST="/etc/v2ray-onekey/hysteria.manifest"
HYSTERIA_CONFIG_MARKER="# Managed by v2ray-onekey: Hysteria2 config v1"
HYSTERIA_ACL_MARKER="# Managed by v2ray-onekey: Hysteria2 ACL v1"
HYSTERIA_UNIT_MARKER="# Managed by v2ray-onekey: Hysteria2 unit v1"
CLOUDFLARE_CONNECT_TIMEOUT="${CLOUDFLARE_CONNECT_TIMEOUT:-10}"
CLOUDFLARE_MAX_TIME="${CLOUDFLARE_MAX_TIME:-30}"
LISTENER_WAIT_ATTEMPTS="${LISTENER_WAIT_ATTEMPTS:-15}"
LISTENER_WAIT_INTERVAL="${LISTENER_WAIT_INTERVAL:-1}"
TRANSACTION_ACTIVE="0"
LOCK_HELD="0"
LEGACY_NGINX_FILES_CHANGED="0"

log() { printf '\033[1;32m[%s]\033[0m %s\n' "$APP_NAME" "$*"; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$APP_NAME" "$*"; }
die() { printf '\033[1;31m[%s]\033[0m %s\n' "$APP_NAME" "$*" >&2; exit 1; }

SENSITIVE_RUNTIME_VARS=(
  CLOUDFLARE_UUID WS_PATH HY2_AUTH HY2_OBFS_PASSWORD HY2_SNI HY2_CERT_PIN SS_KEY
)

unexport_sensitive_runtime_values() {
  local name
  for name in "${SENSITIVE_RUNTIME_VARS[@]}"; do
    export -n "$name" 2>/dev/null || true
  done
}

reset_options() {
  unexport_sensitive_runtime_values
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
  LEGACY_HY2_BOOTSTRAP="0"
  HY2_PORT_START=""
  HY2_PORT_END=""
  HY2_CONFLICT_DETAILS=""
  SS_CONFLICT_DETAILS=""
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

parse_port_range() {
  local range="${1:-}" start end
  [[ "$range" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || return 1
  start="$(normalize_port "${BASH_REMATCH[1]}")" || return 1
  end="$(normalize_port "${BASH_REMATCH[2]}")" || return 1
  valid_port "$start" && valid_port "$end" || return 1
  (( 10#$start <= 10#$end )) || return 1
  (( 10#$end - 10#$start <= 1000 )) || return 1
  HY2_PORT_START="$start"
  HY2_PORT_END="$end"
}

valid_hy2_port_range() {
  local saved_start="${HY2_PORT_START:-}" saved_end="${HY2_PORT_END:-}" status=0
  parse_port_range "${1:-}" || status=$?
  HY2_PORT_START="$saved_start"
  HY2_PORT_END="$saved_end"
  return "$status"
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
      SS_METHOD="${SS_METHOD:-2022-blake3-aes-128-gcm}"
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
      SS_METHOD="${SS_METHOD:-2022-blake3-aes-128-gcm}"
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

valid_ss_key() {
  local key="${1:-}" decoded_size canonical
  [[ "$key" =~ ^[A-Za-z0-9+/]{22}==$ ]] || return 1
  decoded_size="$(printf '%s' "$key" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d '[:space:]')" || return 1
  [[ "$decoded_size" == "16" ]] || return 1
  canonical="$(printf '%s' "$key" | openssl base64 -d -A 2>/dev/null | openssl base64 -A 2>/dev/null)" || return 1
  [[ "$canonical" == "$key" ]]
}

generate_ss_key() {
  openssl rand -base64 16 | tr -d '\r\n'
}

valid_hy2_secret() {
  local secret="${1:-}" decoded_size canonical
  [[ "$secret" =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1
  decoded_size="$(
    printf '%s=' "$secret" | tr '_-' '/+' |
      openssl base64 -d -A 2>/dev/null | wc -c | tr -d '[:space:]'
  )" || return 1
  [[ "$decoded_size" == "32" ]] || return 1
  canonical="$(
    printf '%s=' "$secret" | tr '_-' '/+' |
      openssl base64 -d -A 2>/dev/null |
      openssl base64 -A 2>/dev/null | tr '+/' '-_' | tr -d '='
  )" || return 1
  [[ "$canonical" == "$secret" ]]
}

valid_hy2_sni() {
  [[ "${1:-}" =~ ^[0-9a-f]{16}\.invalid$ ]]
}

valid_hy2_cert_pin() {
  [[ "${1:-}" =~ ^([0-9A-F]{2}:){31}[0-9A-F]{2}$ ]]
}

random_urlsafe_secret() {
  openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\r\n'
}

generate_hy2_sni() {
  printf '%s.invalid\n' "$(openssl rand -hex 8)"
}

validate_loaded_runtime_values() {
  local allow_missing_hy2_pin="${1:-0}"
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

  if mode_has_hysteria; then
    valid_hy2_secret "$HY2_AUTH" || die "Invalid Hysteria2 authentication value in state"
    valid_hy2_secret "$HY2_OBFS_PASSWORD" || die "Invalid Hysteria2 obfuscation value in state"
    valid_hy2_sni "$HY2_SNI" || die "Invalid Hysteria2 SNI in state"
    if [[ -n "$HY2_CERT_PIN" ]]; then
      valid_hy2_cert_pin "$HY2_CERT_PIN" || die "Invalid Hysteria2 certificate pin in state"
    elif [[ "$allow_missing_hy2_pin" != "1" ]]; then
      die "Invalid Hysteria2 certificate pin in state"
    fi
  else
    [[ -z "$HY2_AUTH$HY2_OBFS_PASSWORD$HY2_SNI$HY2_CERT_PIN" ]] ||
      die "Inactive Hysteria2 state must not contain credentials"
  fi
  if mode_has_shadowsocks; then
    [[ "$SS_METHOD" == "2022-blake3-aes-128-gcm" ]] ||
      die "Invalid Shadowsocks method in state"
    valid_ss_key "$SS_KEY" || die "Invalid Shadowsocks key in state"
  else
    [[ -z "$SS_METHOD$SS_KEY" ]] ||
      die "Inactive Shadowsocks state must not contain settings or credentials"
  fi
}

valid_ws_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._~\-]+$ ]]
}

save_state() (
  local state_dir state_name temp_state key
  unexport_sensitive_runtime_values
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
  unexport_sensitive_runtime_values
  LEGACY_HY2_BOOTSTRAP="0"
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
    if mode_has_shadowsocks; then
      SS_METHOD="2022-blake3-aes-128-gcm"
      SS_KEY="$(generate_ss_key)"
    fi
    if mode_has_hysteria; then
      HY2_AUTH="$(random_urlsafe_secret)"
      HY2_OBFS_PASSWORD="$(random_urlsafe_secret)"
      HY2_SNI="$(generate_hy2_sni)"
      LEGACY_HY2_BOOTSTRAP="1"
    fi
  else
    # The allowlist and shell-escape parser above make these assignments inert data.
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
  ROTATE="0"
  validate_options state
  if [[ "$loaded_schema" == "1" ]]; then
    validate_loaded_runtime_values 1
  else
    validate_loaded_runtime_values
  fi
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
  unexport_sensitive_runtime_values
  if mode_has_cloudflare; then
    [[ -n "$CLOUDFLARE_UUID" ]] || CLOUDFLARE_UUID="$(xray uuid)"
    [[ -n "$INTERNAL_WS_PORT" ]] || INTERNAL_WS_PORT="$(random_internal_ws_port)"
    [[ -n "$WS_PATH" ]] || WS_PATH="/$(openssl rand -hex 12)"
  fi
  if mode_has_hysteria; then
    [[ -n "$HY2_AUTH" ]] || HY2_AUTH="$(random_urlsafe_secret)"
    [[ -n "$HY2_OBFS_PASSWORD" ]] || HY2_OBFS_PASSWORD="$(random_urlsafe_secret)"
    [[ -n "$HY2_SNI" ]] || HY2_SNI="$(generate_hy2_sni)"
    valid_hy2_secret "$HY2_AUTH" || die "Unable to generate valid Hysteria2 authentication"
    valid_hy2_secret "$HY2_OBFS_PASSWORD" || die "Unable to generate valid Hysteria2 obfuscation"
    valid_hy2_sni "$HY2_SNI" || die "Unable to generate a valid Hysteria2 SNI"
    [[ -z "$HY2_CERT_PIN" ]] || valid_hy2_cert_pin "$HY2_CERT_PIN" ||
      die "Invalid Hysteria2 certificate pin"
  fi
  if mode_has_shadowsocks; then
    SS_METHOD="${SS_METHOD:-2022-blake3-aes-128-gcm}"
    [[ -n "$SS_KEY" ]] || SS_KEY="$(generate_ss_key)"
    valid_ss_key "$SS_KEY" || die "Unable to generate a valid Shadowsocks key"
  fi
}

rotate_runtime_values() {
  unexport_sensitive_runtime_values
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
    validate_loaded_runtime_values "$LEGACY_HY2_BOOTSTRAP"
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

validate_cloudflare_preflight() (
  local preflight_dir="" temp_root="${TMPDIR:-/tmp}"
  cleanup_cloudflare_preflight() {
    [[ -z "$preflight_dir" ]] || rm -rf -- "$preflight_dir" || true
  }
  trap cleanup_cloudflare_preflight EXIT
  [[ -d "$temp_root" && ! -L "$temp_root" ]] || die "Invalid temporary directory: $temp_root"
  preflight_dir="$(mktemp -d "$temp_root/v2ray-onekey-preflight.XXXXXX")"
  chmod 0700 "$preflight_dir"
  RUNTIME_DIR="$preflight_dir"
  CLOUDFLARE_IPV4_FILE="$preflight_dir/ips-v4"
  CLOUDFLARE_IPV6_FILE="$preflight_dir/ips-v6"
  download_cloudflare_ranges
  validate_cloudflare_domain
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
  if hysteria_managed_deployment_exists &&
    { mode_has_hysteria || systemctl is-active --quiet hysteria-server; } &&
    ! hysteria_deployment_is_strictly_project_owned; then
    die "Refusing unmanaged Hysteria2 files; the exact v2ray-onekey ownership manifest is missing or does not match"
  fi
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

hysteria_managed_paths() {
  printf '%s\n' \
    "$HYSTERIA_BIN" "$HYSTERIA_CONFIG" "$HYSTERIA_ACL" "$HYSTERIA_CERT" \
    "$HYSTERIA_KEY" "$HYSTERIA_UNIT"
}

hysteria_config_directory() {
  dirname "$HYSTERIA_CONFIG"
}

hysteria_vendor_unit_paths() {
  printf '%s\n' \
    /lib/systemd/system/hysteria-server.service \
    /usr/lib/systemd/system/hysteria-server.service \
    /usr/local/lib/systemd/system/hysteria-server.service
}

hysteria_drop_in_directories() {
  printf '%s\n' \
    /etc/systemd/system/hysteria-server.service.d \
    /run/systemd/system/hysteria-server.service.d \
    /usr/local/lib/systemd/system/hysteria-server.service.d \
    /usr/lib/systemd/system/hysteria-server.service.d \
    /lib/systemd/system/hysteria-server.service.d
}

loaded_service_fragment_path() {
  systemctl show -p FragmentPath --value "$1" 2>/dev/null || true
}

hysteria_config_directory_has_entries() {
  local directory entry
  directory="$(hysteria_config_directory)"
  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    return 0
  done
  return 1
}

hysteria_config_directory_contains_only_managed_paths() {
  local directory entry
  directory="$(hysteria_config_directory)"
  if [[ -e "$directory" || -L "$directory" ]]; then
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
  else
    return 0
  fi
  for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    case "$entry" in
      "$HYSTERIA_CONFIG"|"$HYSTERIA_ACL"|"$HYSTERIA_CERT"|"$HYSTERIA_KEY") ;;
      *) return 1 ;;
    esac
  done
}

hysteria_vendor_deployment_exists() {
  local path
  while IFS= read -r path; do
    [[ -e "$path" || -L "$path" ]] && return 0
  done < <(hysteria_vendor_unit_paths)
  return 1
}

hysteria_drop_in_deployment_exists() {
  local directory entry
  while IFS= read -r directory; do
    if [[ -e "$directory" || -L "$directory" ]]; then
      [[ -d "$directory" && ! -L "$directory" ]] || return 0
    else
      continue
    fi
    for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      return 0
    done
  done < <(hysteria_drop_in_directories)
  return 1
}

hysteria_managed_deployment_exists() {
  local path fragment directory drop_in_paths
  [[ -e "$HYSTERIA_OWNERSHIP_MANIFEST" || -L "$HYSTERIA_OWNERSHIP_MANIFEST" ]] && return 0
  while IFS= read -r path; do
    [[ -e "$path" || -L "$path" ]] && return 0
  done < <(hysteria_managed_paths)
  directory="$(hysteria_config_directory)"
  if [[ -e "$directory" || -L "$directory" ]]; then
    [[ -d "$directory" && ! -L "$directory" ]] || return 0
  fi
  hysteria_config_directory_has_entries && return 0
  hysteria_vendor_deployment_exists && return 0
  hysteria_drop_in_deployment_exists && return 0
  drop_in_paths="$(systemctl show -p DropInPaths --value hysteria-server 2>/dev/null || true)"
  [[ -n "${drop_in_paths//[[:space:]]/}" ]] && return 0
  fragment="$(loaded_service_fragment_path hysteria-server)"
  [[ -n "$fragment" ]] && return 0
  return 1
}

hysteria_deployment_is_strictly_project_owned() {
  local fragment drop_in_paths
  hysteria_ownership_manifest_is_valid || return 1
  hysteria_config_directory_contains_only_managed_paths || return 1
  hysteria_vendor_deployment_exists && return 1
  hysteria_drop_in_deployment_exists && return 1
  fragment="$(loaded_service_fragment_path hysteria-server)"
  [[ "$fragment" == "$HYSTERIA_UNIT" ]] || return 1
  drop_in_paths="$(systemctl show -p DropInPaths --value hysteria-server 2>/dev/null)" || return 1
  [[ -z "${drop_in_paths//[[:space:]]/}" ]]
}

hysteria_ownership_manifest_is_valid() {
  local expected_path digest recorded_path extra owner mode actual_digest
  [[ -f "$HYSTERIA_OWNERSHIP_MANIFEST" && ! -L "$HYSTERIA_OWNERSHIP_MANIFEST" ]] || return 1
  owner="$(stat -c '%u' "$HYSTERIA_OWNERSHIP_MANIFEST" 2>/dev/null)" || return 1
  mode="$(stat -c '%a' "$HYSTERIA_OWNERSHIP_MANIFEST" 2>/dev/null)" || return 1
  [[ "$owner" == "0" && "$mode" == "600" ]] || return 1
  hysteria_text_markers_are_valid || return 1
  exec 3<"$HYSTERIA_OWNERSHIP_MANIFEST" || return 1
  IFS= read -r extra <&3 || { exec 3<&-; return 1; }
  [[ "$extra" == '# Managed by v2ray-onekey: Hysteria2 ownership v1' ]] || {
    exec 3<&-
    return 1
  }
  while IFS= read -r expected_path; do
    IFS=$'\t' read -r digest recorded_path <&3 || { exec 3<&-; return 1; }
    [[ "$recorded_path" == "$expected_path" && "$digest" =~ ^[0-9a-f]{64}$ ]] || {
      exec 3<&-
      return 1
    }
    [[ -f "$expected_path" && ! -L "$expected_path" ]] || { exec 3<&-; return 1; }
    actual_digest="$(sha256sum -- "$expected_path" 2>/dev/null)" || { exec 3<&-; return 1; }
    actual_digest="${actual_digest%% *}"
    [[ "$actual_digest" == "$digest" ]] || {
      exec 3<&-
      return 1
    }
  done < <(hysteria_managed_paths)
  if IFS= read -r extra <&3; then
    exec 3<&-
    return 1
  fi
  exec 3<&-
}

hysteria_text_markers_are_valid() {
  local first_line
  [[ -f "$HYSTERIA_CONFIG" && ! -L "$HYSTERIA_CONFIG" ]] || return 1
  IFS= read -r first_line <"$HYSTERIA_CONFIG" || return 1
  [[ "$first_line" == "$HYSTERIA_CONFIG_MARKER" ]] || return 1
  [[ -f "$HYSTERIA_ACL" && ! -L "$HYSTERIA_ACL" ]] || return 1
  IFS= read -r first_line <"$HYSTERIA_ACL" || return 1
  [[ "$first_line" == "$HYSTERIA_ACL_MARKER" ]] || return 1
  [[ -f "$HYSTERIA_UNIT" && ! -L "$HYSTERIA_UNIT" ]] || return 1
  IFS= read -r first_line <"$HYSTERIA_UNIT" || return 1
  [[ "$first_line" == "$HYSTERIA_UNIT_MARKER" ]]
}

write_hysteria_ownership_manifest() (
  local manifest_dir temp_path="" path digest
  cleanup_hysteria_manifest() { [[ -z "$temp_path" ]] || rm -f -- "$temp_path" || true; }
  trap cleanup_hysteria_manifest EXIT
  manifest_dir="$(dirname "$HYSTERIA_OWNERSHIP_MANIFEST")"
  hysteria_text_markers_are_valid || die "Hysteria2 managed-file markers are missing or invalid"
  install -d -o root -g root -m 0700 "$manifest_dir"
  temp_path="$(mktemp "$manifest_dir/.hysteria-manifest.XXXXXX")"
  chmod 0600 "$temp_path"
  printf '%s\n' '# Managed by v2ray-onekey: Hysteria2 ownership v1' >"$temp_path"
  while IFS= read -r path; do
    [[ -f "$path" && ! -L "$path" ]] || die "Cannot record missing Hysteria2 managed file: $path"
    digest="$(sha256sum -- "$path")" || die "Unable to hash Hysteria2 managed file: $path"
    digest="${digest%% *}"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "Invalid Hysteria2 managed-file digest"
    printf '%s\t%s\n' "$digest" "$path" >>"$temp_path"
  done < <(hysteria_managed_paths)
  install -o root -g root -m 0600 "$temp_path" "$HYSTERIA_OWNERSHIP_MANIFEST"
)

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

project_nginx_configuration_exists() {
  current_nginx_config_is_project_owned "$NGINX_SITE" || legacy_project_nginx_exists
}

mode_manages_nginx() {
  mode_has_cloudflare || project_nginx_configuration_exists
}

legacy_nginx_config_paths() {
  local path
  for path in /etc/nginx/conf.d/v2ray-*.conf; do
    [[ -e "$path" || -L "$path" ]] || continue
    printf '%s\n' "$path"
  done
}

xray_installer_managed_paths() {
  printf '%s\n' \
    "$XRAY_BIN" \
    "$XRAY_DATA_DIR/geoip.dat" \
    "$XRAY_DATA_DIR/geosite.dat" \
    "$XRAY_CONFIG" \
    "$XRAY_LOG_DIR/access.log" \
    "$XRAY_LOG_DIR/error.log" \
    "$XRAY_SYSTEMD_DIR/xray.service" \
    "$XRAY_SYSTEMD_DIR/xray@.service" \
    "$XRAY_SYSTEMD_DIR/xray.service.d/10-donot_touch_single_conf.conf" \
    "$XRAY_SYSTEMD_DIR/xray.service.d/10-donot_touch_multi_conf.conf" \
    "$XRAY_SYSTEMD_DIR/xray@.service.d/10-donot_touch_single_conf.conf" \
    "$XRAY_SYSTEMD_DIR/xray@.service.d/10-donot_touch_multi_conf.conf"
}

xray_enablement_link() {
  printf '%s\n' "$XRAY_SYSTEMD_DIR/multi-user.target.wants/xray.service"
}

xray_enablement_directory() {
  dirname "$(xray_enablement_link)"
}

xray_enablement_target_is_project_unit() {
  [[ "$1" == "../xray.service" || "$1" == "$XRAY_SYSTEMD_DIR/xray.service" ]]
}

xray_installer_managed_directories() {
  printf '%s\n' \
    "$XRAY_DATA_DIR" \
    "$(dirname "$XRAY_CONFIG")" \
    "$XRAY_LOG_DIR" \
    "$XRAY_SYSTEMD_DIR/xray.service.d" \
    "$XRAY_SYSTEMD_DIR/xray@.service.d" \
    "$(xray_enablement_directory)"
}

xray_standard_unit_directories() {
  printf '%s\n' \
    /etc/systemd/system \
    /run/systemd/system \
    /usr/local/lib/systemd/system \
    /usr/lib/systemd/system \
    /lib/systemd/system
}

xray_installer_known_dropin_path() {
  case "$1" in
    "$XRAY_SYSTEMD_DIR/xray.service.d/10-donot_touch_single_conf.conf" | \
      "$XRAY_SYSTEMD_DIR/xray.service.d/10-donot_touch_multi_conf.conf" | \
      "$XRAY_SYSTEMD_DIR/xray@.service.d/10-donot_touch_single_conf.conf" | \
      "$XRAY_SYSTEMD_DIR/xray@.service.d/10-donot_touch_multi_conf.conf") return 0 ;;
    *) return 1 ;;
  esac
}

validate_xray_not_found_systemd_paths() {
  local unit_root unit_name dropin_directory entry
  while IFS= read -r unit_root; do
    for unit_name in xray.service xray@.service; do
      entry="$unit_root/$unit_name"
      [[ ! -e "$entry" && ! -L "$entry" ]] ||
        die "Xray is reported not-found but an unmanaged unit already exists: $entry"
      dropin_directory="$unit_root/$unit_name.d"
      [[ ! -L "$dropin_directory" ]] ||
        die "Refusing unmanaged Xray systemd drop-in: $dropin_directory"
      if [[ -e "$dropin_directory" ]]; then
        [[ -d "$dropin_directory" ]] ||
          die "Refusing unmanaged Xray systemd drop-in: $dropin_directory"
        for entry in "$dropin_directory"/* "$dropin_directory"/.[!.]* \
          "$dropin_directory"/..?*; do
          [[ -e "$entry" || -L "$entry" ]] || continue
          [[ -f "$entry" && ! -L "$entry" ]] && xray_installer_known_dropin_path "$entry" ||
            die "Refusing unmanaged Xray systemd drop-in: $entry"
        done
      fi
    done
  done < <(xray_standard_unit_directories)
}

xray_installer_path_allowed() {
  local wanted="$1" path
  while IFS= read -r path; do
    [[ "$wanted" == "$path" ]] && return 0
  done < <(xray_installer_managed_paths)
  return 1
}

managed_directory_allowed() {
  local wanted="$1" directory
  [[ "$wanted" == "$(hysteria_config_directory)" ]] && return 0
  while IFS= read -r directory; do
    [[ "$wanted" == "$directory" ]] && return 0
  done < <(xray_installer_managed_directories)
  return 1
}

managed_path_allowed() {
  local path="$1"
  [[ "$path" == "$LEGACY_V2RAY_CONFIG" ||
    "$path" == "$XRAY_CONFIG" ||
    "$path" == "$STATE_FILE" ||
    "$path" == "$NGINX_SITE" ||
    "$path" == "$RENEWAL_HOOK" ||
    "$path" == "$HYSTERIA_BIN" ||
    "$path" == "$HYSTERIA_CONFIG" ||
    "$path" == "$HYSTERIA_ACL" ||
    "$path" == "$HYSTERIA_CERT" ||
    "$path" == "$HYSTERIA_KEY" ||
    "$path" == "$HYSTERIA_UNIT" ||
    "$path" == "$HYSTERIA_OWNERSHIP_MANIFEST" ]] && return 0
  xray_installer_path_allowed "$path" && return 0
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
  : >"$BACKUP_DIR/firewall-rules"
  : >"$BACKUP_DIR/accounts"
  : >"$BACKUP_DIR/directories"
  : >"$BACKUP_DIR/symlinks"
  : >"$BACKUP_DIR/services-touched"
  chmod 0600 "$BACKUP_DIR/manifest" "$BACKUP_DIR/services" "$BACKUP_DIR/legacy-renames" \
    "$BACKUP_DIR/firewall-rules" "$BACKUP_DIR/accounts" "$BACKUP_DIR/directories" \
    "$BACKUP_DIR/symlinks" "$BACKUP_DIR/services-touched"
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

systemd_property_value() {
  local service="$1" property="$2" output="" status=0
  output="$(systemctl show -p "$property" --value "$service" 2>/dev/null)" || status=$?
  [[ "$output" != *$'\n'* && "$output" =~ ^[A-Za-z-]*$ ]] || return 1
  [[ "$status" -eq 0 || -n "$output" ]] || return 1
  printf '%s\n' "$output"
}

query_service_state() {
  local service="$1" load active unit
  load="$(systemd_property_value "$service" LoadState)" || return 1
  active="$(systemd_property_value "$service" ActiveState)" || return 1
  if [[ "$load" == "not-found" ]]; then
    [[ "$active" == "inactive" ]] || return 1
    unit="not-found"
  else
    unit="$(systemd_property_value "$service" UnitFileState)" || return 1
    [[ -n "$unit" ]] || return 1
  fi
  printf '%s\t%s\n' "$active" "$unit"
}

service_state_is_restorable() {
  local active="$1" unit="$2"
  [[ "$active" == "active" || "$active" == "inactive" ]] || return 1
  case "$unit" in
    enabled|enabled-runtime|disabled|masked|masked-runtime|not-found) return 0 ;;
    *) return 1 ;;
  esac
}

recorded_service_state() {
  local service="$1"
  awk -F '\t' -v wanted="$service" '$1 == wanted { print $2 "\t" $3; found = 1 }
    END { exit !found }' "$BACKUP_DIR/services"
}

recorded_service_state_is_restorable() {
  local service="$1" state active unit
  state="$(recorded_service_state "$service")" || return 1
  active="${state%%$'\t'*}"
  unit="${state#*$'\t'}"
  service_state_is_restorable "$active" "$unit"
}

record_service_states() {
  local service state active unit
  local -a services=(v2ray xray)
  mode_manages_nginx && services+=(nginx)
  services+=(hysteria-server)
  : >"$BACKUP_DIR/services"
  for service in "${services[@]}"; do
    state="$(query_service_state "$service")" || die "Unable to inspect exact service state: $service"
    active="${state%%$'\t'*}"
    unit="${state#*$'\t'}"
    printf '%s\t%s\t%s\n' "$service" "$active" "$unit" >>"$BACKUP_DIR/services"
  done
  chmod 0600 "$BACKUP_DIR/services"
}

managed_service_name() {
  case "$1" in
    v2ray|xray|nginx|hysteria-server) return 0 ;;
    *) return 1 ;;
  esac
}

record_service_touch() {
  local service="$1" journal="${BACKUP_DIR:-}/services-touched"
  managed_service_name "$service" || die "Refusing to journal unmanaged service: $service"
  [[ -f "$journal" && ! -L "$journal" ]] || die "Service touch journal is unavailable"
  recorded_service_state_is_restorable "$service" ||
    die "Refusing to touch $service with an unsupported original service state"
  if ! grep -Fqx -- "$service" "$journal"; then
    printf '%s\n' "$service" >>"$journal"
  fi
  chmod 0600 "$journal"
}

service_was_touched() {
  local service="$1"
  [[ -f "${BACKUP_DIR:-}/services-touched" ]] || return 1
  grep -Fqx -- "$service" "$BACKUP_DIR/services-touched"
}

run_service_mutation() {
  local service="$1" action="${2:-}"
  shift 2 || die "Invalid service mutation"
  managed_service_name "$service" || die "Refusing to mutate unmanaged service: $service"
  case "$action" in
    stop|start|restart|enable|disable|reload) ;;
    *) die "Unsupported service mutation: $action" ;;
  esac
  record_service_touch "$service"
  systemctl "$action" "$@" "$service"
}

run_guarded_service_action() {
  local service="$1" before after command_status=0 after_status=0 had_errexit=0
  shift
  [[ "$#" -gt 0 ]] || die "Missing guarded service action"
  managed_service_name "$service" || die "Refusing to guard unmanaged service: $service"
  before="$(query_service_state "$service")" || die "Unable to inspect $service before external action"
  service_state_is_restorable "${before%%$'\t'*}" "${before#*$'\t'}" ||
    die "Refusing external action for $service with an unsupported service state"
  [[ "$-" == *e* ]] && had_errexit=1
  set +e
  "$@"
  command_status=$?
  after="$(query_service_state "$service")"
  after_status=$?
  if [[ "$had_errexit" == "1" ]]; then set -e; else set +e; fi
  if [[ "$after_status" -ne 0 ]] ||
    ! service_state_is_restorable "${after%%$'\t'*}" "${after#*$'\t'}"; then
    record_service_touch "$service"
    [[ "$command_status" -ne 0 ]] && return "$command_status"
    die "Unable to inspect $service after external action"
  fi
  [[ "$before" == "$after" ]] || record_service_touch "$service"
  return "$command_status"
}

directory_state_is_recorded() {
  local directory="$1"
  awk -F '\t' -v wanted="$directory" '$2 == wanted { found = 1 } END { exit !found }' \
    "$BACKUP_DIR/directories"
}

record_managed_directory_state() {
  local directory="$1" owner group mode
  [[ "$directory" == /* && "$directory" != "/" && "$directory" != *$'\n'* ]] ||
    die "Invalid managed directory: $directory"
  managed_directory_allowed "$directory" || die "Refusing to record unmanaged directory: $directory"
  directory_state_is_recorded "$directory" && return 0
  [[ ! -L "$directory" ]] || die "Refusing symlink managed directory: $directory"
  if [[ -e "$directory" ]]; then
    [[ -d "$directory" ]] || die "Managed directory path is not a directory: $directory"
    owner="$(stat -c '%u' "$directory")" || die "Unable to inspect managed directory owner: $directory"
    group="$(stat -c '%g' "$directory")" || die "Unable to inspect managed directory group: $directory"
    mode="$(stat -c '%a' "$directory")" || die "Unable to inspect managed directory mode: $directory"
    printf 'present\t%s\t%s\t%s\t%s\n' "$directory" "$owner" "$group" "$mode" \
      >>"$BACKUP_DIR/directories"
  else
    printf 'absent\t%s\n' "$directory" >>"$BACKUP_DIR/directories"
  fi
  chmod 0600 "$BACKUP_DIR/directories"
}

record_hysteria_directory_state() {
  record_managed_directory_state "$(hysteria_config_directory)"
}

record_xray_enablement_state() {
  local unit="$1" link journal target="" kind="absent"
  link="$(xray_enablement_link)"
  journal="${BACKUP_DIR:-}/symlinks"
  [[ -f "$journal" && ! -L "$journal" ]] || die "Xray symlink journal is unavailable"
  [[ "$link" == /* && "$link" != *$'\n'* ]] || die "Invalid Xray enablement path"

  if [[ "$unit" == "not-found" ]]; then
    [[ ! -e "$link" && ! -L "$link" ]] ||
      die "Xray is reported not-found with inconsistent Xray enablement: $link"
  elif [[ -L "$link" ]]; then
    target="$(readlink -- "$link")" || die "Unable to inspect Xray enablement link"
    [[ -n "$target" && "$target" != *$'\n'* ]] &&
      xray_enablement_target_is_project_unit "$target" ||
      die "Refusing unmanaged Xray enablement link: $link"
    kind="present"
  elif [[ -e "$link" ]]; then
    die "Refusing non-symlink Xray enablement path: $link"
  fi

  if [[ "$kind" == "present" ]]; then
    printf 'present\t%s\t%s\n' "$link" "$target" >>"$journal" ||
      die "Unable to record Xray enablement link"
  else
    printf 'absent\t%s\n' "$link" >>"$journal" ||
      die "Unable to record absent Xray enablement link"
  fi
  chmod 0600 "$journal" || die "Unable to secure Xray symlink journal"
}

record_xray_installer_state() {
  local active unit state path directory entry
  state="$(recorded_service_state xray)" || die "Missing original Xray service state"
  active="${state%%$'\t'*}"
  unit="${state#*$'\t'}"
  service_state_is_restorable "$active" "$unit" || die "Unsupported original Xray service state"

  if [[ "$unit" == "not-found" ]]; then
    validate_xray_not_found_systemd_paths
  fi
  record_xray_enablement_state "$unit"

  if [[ -d "$XRAY_LOG_DIR" && ! -L "$XRAY_LOG_DIR" ]]; then
    for entry in "$XRAY_LOG_DIR"/*.log; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      [[ "$entry" == "$XRAY_LOG_DIR/access.log" || "$entry" == "$XRAY_LOG_DIR/error.log" ]] ||
        die "Refusing Xray installer because it may modify an unmanaged log file: $entry"
    done
  fi

  while IFS= read -r directory; do
    record_managed_directory_state "$directory"
  done < <(xray_installer_managed_directories)
  while IFS= read -r path; do
    backup_file "$path"
  done < <(xray_installer_managed_paths)
}

restore_managed_symlink_states() {
  local kind path target current parent
  [[ -f "${BACKUP_DIR:-}/symlinks" && ! -L "$BACKUP_DIR/symlinks" ]] || return 0
  while IFS=$'\t' read -r kind path target; do
    [[ -n "$path" ]] || continue
    [[ "$path" == "$(xray_enablement_link)" ]] || {
      warn "Skipping unmanaged rollback symlink: $path"
      continue
    }
    if [[ "$kind" == "absent" ]]; then
      if [[ -L "$path" ]]; then
        rm -f -- "$path" || warn "Could not remove current-run Xray enablement link"
      elif [[ -e "$path" ]]; then
        warn "Refusing to remove non-symlink Xray enablement path: $path"
      fi
    elif [[ "$kind" == "present" ]] && xray_enablement_target_is_project_unit "$target"; then
      if [[ -L "$path" ]]; then
        current="$(readlink -- "$path" 2>/dev/null)" || current=""
        [[ "$current" == "$target" ]] && continue
        rm -f -- "$path" || {
          warn "Could not replace Xray enablement link during rollback"
          continue
        }
      elif [[ -e "$path" ]]; then
        warn "Refusing to replace non-symlink Xray enablement path: $path"
        continue
      fi
      parent="$(dirname "$path")"
      install -d -m 0755 "$parent" || {
        warn "Could not recreate Xray enablement directory during rollback"
        continue
      }
      ln -s -- "$target" "$path" || warn "Could not restore Xray enablement link"
    else
      warn "Skipping malformed Xray symlink rollback metadata"
    fi
  done <"$BACKUP_DIR/symlinks"
}

restore_managed_directory_states() {
  local kind directory owner group mode
  [[ -f "${BACKUP_DIR:-}/directories" ]] || return 0
  while IFS=$'\t' read -r kind directory owner group mode; do
    [[ -n "$directory" ]] || continue
    [[ "$directory" == /* && "$directory" != "/" && "$directory" != *$'\n'* ]] &&
      managed_directory_allowed "$directory" || {
      warn "Skipping invalid managed rollback directory: $directory"
      continue
    }
    [[ ! -L "$directory" ]] || {
      warn "Refusing symlink managed rollback directory: $directory"
      continue
    }
    if [[ "$kind" == "present" ]]; then
      [[ "$owner" =~ ^[0-9]+$ && "$group" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]{3,4}$ ]] || {
        warn "Skipping malformed managed directory metadata: $directory"
        continue
      }
      if [[ ! -e "$directory" ]]; then
        mkdir -p -- "$directory" || {
          warn "Could not recreate managed directory: $directory"
          continue
        }
      fi
      [[ -d "$directory" ]] || {
        warn "Cannot restore non-directory managed path: $directory"
        continue
      }
      chown "$owner:$group" "$directory" || warn "Could not restore managed directory ownership: $directory"
      chmod "$mode" "$directory" || warn "Could not restore managed directory mode: $directory"
    elif [[ "$kind" == "absent" && -d "$directory" ]]; then
      if ! rmdir -- "$directory" 2>/dev/null; then
        if [[ "$directory" == "$(hysteria_config_directory)" ]]; then
          chown root:root "$directory" || warn "Could not detach retained Hysteria2 directory from its temporary group"
          chmod 0750 "$directory" || warn "Could not secure retained Hysteria2 directory"
        fi
        warn "Retaining non-empty managed directory because it contains external content: $directory"
      fi
    fi
  done <"$BACKUP_DIR/directories"
}

restore_hysteria_directory_state() {
  restore_managed_directory_states
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
  record_xray_installer_state
  if mode_has_hysteria; then
    record_hysteria_directory_state
  fi
  for managed_path in \
    "$LEGACY_V2RAY_CONFIG" "$XRAY_CONFIG" "$STATE_FILE" "$NGINX_SITE" "$RENEWAL_HOOK"; do
    backup_file "$managed_path"
  done
  if mode_has_hysteria; then
    while IFS= read -r managed_path; do
      backup_file "$managed_path"
    done < <(hysteria_managed_paths)
    backup_file "$HYSTERIA_OWNERSHIP_MANIFEST"
  fi
  collect_owned_legacy_nginx_files
}

disable_owned_legacy_nginx_files() {
  local path disabled
  LEGACY_NGINX_FILES_CHANGED="0"
  [[ -f "$BACKUP_DIR/legacy-files" ]] || return 0
  while IFS= read -r path; do
    [[ -n "$path" && -f "$path" && ! -L "$path" ]] || continue
    legacy_nginx_config_is_project_owned "$path" || die "Legacy Nginx ownership changed during deployment: $path"
    disabled="${path}.v2ray-onekey-disabled-${RUN_TIMESTAMP}"
    [[ ! -e "$disabled" ]] || die "Legacy Nginx disabled path already exists: $disabled"
    mv -- "$path" "$disabled"
    printf '%s\t%s\n' "$path" "$disabled" >>"$BACKUP_DIR/legacy-renames"
    LEGACY_NGINX_FILES_CHANGED="1"
  done <"$BACKUP_DIR/legacy-files"
}

restore_service_states() {
  local service active unit
  [[ -f "$BACKUP_DIR/services" ]] || return 0

  while IFS=$'\t' read -r service active unit; do
    [[ -n "$service" ]] || continue
    service_was_touched "$service" || continue
    service_state_is_restorable "$active" "$unit" || {
      warn "Skipping unsupported service state during rollback: $service"
      continue
    }
    [[ "$unit" != "not-found" ]] || continue
    systemctl unmask "$service" >/dev/null 2>&1 || true
    systemctl unmask --runtime "$service" >/dev/null 2>&1 || true
    if [[ "$active" == "active" ]]; then
      systemctl restart "$service" >/dev/null 2>&1 || warn "Could not restart $service during rollback"
    fi
  done <"$BACKUP_DIR/services"

  while IFS=$'\t' read -r service active unit; do
    [[ -n "$service" ]] || continue
    service_was_touched "$service" || continue
    case "$unit" in
      enabled) systemctl enable "$service" >/dev/null 2>&1 || warn "Could not re-enable $service during rollback" ;;
      enabled-runtime)
        systemctl disable "$service" >/dev/null 2>&1 || true
        systemctl enable --runtime "$service" >/dev/null 2>&1 || warn "Could not restore runtime enablement for $service"
        ;;
      disabled) systemctl disable "$service" >/dev/null 2>&1 || true ;;
      not-found) : ;;
      masked)
        systemctl disable "$service" >/dev/null 2>&1 || true
        systemctl mask "$service" >/dev/null 2>&1 || warn "Could not restore masked state for $service"
        ;;
      masked-runtime)
        systemctl disable "$service" >/dev/null 2>&1 || true
        systemctl mask --runtime "$service" >/dev/null 2>&1 || warn "Could not restore runtime mask for $service"
        ;;
    esac
  done <"$BACKUP_DIR/services"
}

stop_touched_services() {
  local service
  [[ -f "${BACKUP_DIR:-}/services-touched" ]] || return 0
  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    managed_service_name "$service" || {
      warn "Skipping unmanaged touched service: $service"
      continue
    }
    systemctl stop "$service" >/dev/null 2>&1 || true
  done <"$BACKUP_DIR/services-touched"
}

rollback_firewall_rules() {
  local -a records=()
  local backend rule index
  [[ -f "${BACKUP_DIR:-}/firewall-rules" ]] || return 0
  while IFS=$'\t' read -r backend rule; do
    [[ -n "$backend" && -n "$rule" ]] && records+=("$backend"$'\t'"$rule")
  done <"$BACKUP_DIR/firewall-rules"
  for ((index = ${#records[@]} - 1; index >= 0; index--)); do
    backend="${records[index]%%$'\t'*}"
    rule="${records[index]#*$'\t'}"
    case "$backend" in
      ufw)
        ufw delete allow "$rule" >/dev/null 2>&1 || warn "Could not remove current-run UFW rule $rule"
        ;;
      firewalld-runtime)
        firewall-cmd --remove-port="$rule" >/dev/null 2>&1 ||
          warn "Could not remove current-run firewalld runtime rule $rule"
        ;;
      firewalld-permanent)
        firewall-cmd --permanent --remove-port="$rule" >/dev/null 2>&1 ||
          warn "Could not remove current-run firewalld permanent rule $rule"
        ;;
    esac
  done
}

rollback_hysteria_account() {
  local name user_state group_state
  [[ -f "${BACKUP_DIR:-}/accounts" ]] || return 0
  while IFS=$'\t' read -r name user_state group_state; do
    [[ "$name" == "hysteria" ]] || continue
    if [[ "$user_state" == "created" ]]; then
      userdel hysteria >/dev/null 2>&1 || warn "Could not remove the current-run Hysteria2 user"
    fi
    if [[ "$group_state" == "created" ]]; then
      groupdel hysteria >/dev/null 2>&1 || warn "Could not remove the current-run Hysteria2 group"
    fi
  done <"$BACKUP_DIR/accounts"
}

rollback_current_run() {
  local kind path backup_path original disabled
  [[ -n "${BACKUP_DIR:-}" && -f "$BACKUP_DIR/manifest" ]] || return 0
  stop_touched_services
  rollback_firewall_rules
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
  restore_managed_symlink_states
  restore_managed_directory_states
  systemctl daemon-reload >/dev/null 2>&1 || true
  restore_service_states
  rollback_hysteria_account
  cleanup_runtime_directory || true
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

project_service_proc_root() {
  if [[ "${V2RAY_ONEKEY_SOURCE_ONLY:-0}" == "1" && -n "${SERVICE_PROC_ROOT:-}" ]]; then
    printf '%s\n' "$SERVICE_PROC_ROOT"
  elif [[ "${V2RAY_ONEKEY_SOURCE_ONLY:-0}" == "1" && -n "${HYSTERIA_PROC_ROOT:-}" ]]; then
    printf '%s\n' "$HYSTERIA_PROC_ROOT"
  else
    printf '/proc\n'
  fi
}

inspect_hysteria_runtime_identity() {
  local pid="${1:-}" proc_root status_file runtime_identity executable command_line
  local loaded_user loaded_group field value numeric account_ids account_uid account_gid
  local expected_cap_mask=$(( (1 << 10) | (1 << 12) ))
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || {
    printf 'Hysteria2 does not have a live MainPID\n'
    return 1
  }
  loaded_user="$(systemctl show -p User --value hysteria-server 2>/dev/null)" || {
    printf 'Unable to inspect the Hysteria2 service user\n'
    return 1
  }
  loaded_group="$(systemctl show -p Group --value hysteria-server 2>/dev/null)" || {
    printf 'Unable to inspect the Hysteria2 service group\n'
    return 1
  }
  [[ "$loaded_user" == "hysteria" && "$loaded_group" == "hysteria" ]] || {
    printf 'Hysteria2 is not loaded with the dedicated service identity\n'
    return 1
  }
  account_ids="$(hysteria_account_identity_is_safe)" || {
    printf 'Hysteria2 service account is not a minimal system identity\n'
    return 1
  }
  account_uid="${account_ids%%:*}"
  account_gid="${account_ids#*:}"
  proc_root="$(project_service_proc_root)"
  [[ -d "$proc_root/$pid" && ! -L "$proc_root/$pid" ]] || {
    printf 'Hysteria2 MainPID is not present in procfs\n'
    return 1
  }
  runtime_identity="$(stat -c '%U:%G' "$proc_root/$pid" 2>/dev/null)" || {
    printf 'Unable to inspect the Hysteria2 runtime identity\n'
    return 1
  }
  [[ "$runtime_identity" == "hysteria:hysteria" ]] || {
    printf 'Hysteria2 is not running as hysteria:hysteria\n'
    return 1
  }
  executable="$(readlink "$proc_root/$pid/exe" 2>/dev/null)" || {
    printf 'Unable to inspect the Hysteria2 runtime executable\n'
    return 1
  }
  [[ "$executable" == "$HYSTERIA_BIN" ]] || {
    printf 'Hysteria2 is running an unexpected executable: %s\n' "$executable"
    return 1
  }
  command_line="$(tr '\0' ' ' <"$proc_root/$pid/cmdline" 2>/dev/null)" || {
    printf 'Unable to inspect the Hysteria2 runtime command line\n'
    return 1
  }
  [[ "$command_line" == "$HYSTERIA_BIN server -c $HYSTERIA_CONFIG " ]] || {
    printf 'Hysteria2 is running with an unexpected command line\n'
    return 1
  }
  status_file="$proc_root/$pid/status"
  [[ -f "$status_file" && ! -L "$status_file" ]] || {
    printf 'Hysteria2 procfs status is unavailable\n'
    return 1
  }
  value="$(awk '$1 == "Uid:" { print $2 " " $3 " " $4 " " $5 }' "$status_file" 2>/dev/null)" || return 1
  [[ "$value" == "$account_uid $account_uid $account_uid $account_uid" ]] || {
    printf 'Hysteria2 runtime UID set is unexpected\n'
    return 1
  }
  value="$(awk '$1 == "Gid:" { print $2 " " $3 " " $4 " " $5 }' "$status_file" 2>/dev/null)" || return 1
  [[ "$value" == "$account_gid $account_gid $account_gid $account_gid" ]] || {
    printf 'Hysteria2 runtime GID set is unexpected\n'
    return 1
  }
  value="$(awk '$1 == "Groups:" { $1=""; sub(/^[[:space:]]+/, ""); print }' "$status_file" 2>/dev/null)" || return 1
  [[ "$value" == "$account_gid" ]] || {
    printf 'Hysteria2 runtime has unexpected supplementary groups\n'
    return 1
  }
  for field in CapEff CapBnd CapAmb; do
    value="$(awk -v wanted="$field:" '$1 == wanted { print $2 }' "$status_file" 2>/dev/null)" || {
      printf 'Unable to inspect Hysteria2 runtime capabilities\n'
      return 1
    }
    [[ "$value" =~ ^[0-9A-Fa-f]{1,16}$ ]] || {
      printf 'Hysteria2 runtime %s is malformed\n' "$field"
      return 1
    }
    numeric=$((16#$value))
    ((numeric == expected_cap_mask)) || {
      printf 'Hysteria2 runtime %s grants unexpected capabilities\n' "$field"
      return 1
    }
  done
  value="$(awk '$1 == "NoNewPrivs:" { print $2 }' "$status_file" 2>/dev/null)" || {
    printf 'Unable to inspect Hysteria2 NoNewPrivileges state\n'
    return 1
  }
  [[ "$value" == "1" ]] || {
    printf 'Hysteria2 runtime does not enforce NoNewPrivileges\n'
    return 1
  }
}

hysteria_runtime_identity_is_expected() {
  inspect_hysteria_runtime_identity "$1" >/dev/null
}

project_hysteria_listener_pid() {
  local pid
  hysteria_deployment_is_strictly_project_owned || return 1
  pid="$(systemctl show -p MainPID --value hysteria-server 2>/dev/null)" || return 1
  hysteria_runtime_identity_is_expected "$pid" || return 1
  printf '%s\n' "$pid"
}

project_xray_disk_deployment_is_consistent() (
  local compare_dir compare_config
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || return 1
  [[ -f "$XRAY_CONFIG" && ! -L "$XRAY_CONFIG" ]] || return 1
  grep -Fqx 'STATE_SCHEMA=2' "$STATE_FILE" || return 1
  load_state >/dev/null 2>&1 || return 1
  compare_dir="$(mktemp -d "${TMPDIR:-/tmp}/.v2ray-onekey-xray-compare.XXXXXX")" || return 1
  trap 'rm -rf -- "$compare_dir"' EXIT
  compare_config="$compare_dir/config.json"
  render_xray_config "$compare_config" >/dev/null 2>&1 || return 1
  cmp -s -- "$compare_config" "$XRAY_CONFIG"
)

project_xray_listener_pid() {
  local pid proc_root executable command_line loaded_user loaded_group runtime_identity
  project_xray_disk_deployment_is_consistent || return 1
  pid="$(systemctl show -p MainPID --value xray 2>/dev/null)" || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  loaded_user="$(systemctl show -p User --value xray 2>/dev/null)" || return 1
  loaded_user="${loaded_user:-root}"
  loaded_group="$(systemctl show -p Group --value xray 2>/dev/null)" || return 1
  if [[ -z "$loaded_group" ]]; then
    loaded_group="$(id -gn "$loaded_user" 2>/dev/null)" || return 1
  fi
  proc_root="$(project_service_proc_root)"
  [[ -d "$proc_root/$pid" && ! -L "$proc_root/$pid" ]] || return 1
  runtime_identity="$(stat -c '%U:%G' "$proc_root/$pid" 2>/dev/null)" || return 1
  [[ "$runtime_identity" == "$loaded_user:$loaded_group" ]] || return 1
  executable="$(readlink "$proc_root/$pid/exe" 2>/dev/null)" || return 1
  [[ "$executable" == "$XRAY_BIN" ]] || return 1
  command_line="$(tr '\0' ' ' <"$proc_root/$pid/cmdline" 2>/dev/null)" || return 1
  [[ "$command_line" == "$XRAY_BIN run -config $XRAY_CONFIG " ]] || return 1
  printf '%s\n' "$pid"
}

listener_output_is_only_expected_service() {
  local output="$1" process="$2" pid="$3" line stripped found=0
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" == *"\"$process\""* && "$line" == *"pid=$pid,"* ]] || return 1
    stripped="${line//pid=$pid,/}"
    [[ "$stripped" != *'pid='* ]] || return 1
    found=1
  done <<<"$output"
  [[ "$found" == "1" ]]
}

hysteria_range_conflicts() {
  local port output owned_pid=""
  HY2_CONFLICT_DETAILS=""
  parse_port_range "$HY2_PORT_RANGE" || die "Invalid Hysteria2 UDP range: $HY2_PORT_RANGE"
  owned_pid="$(project_hysteria_listener_pid 2>/dev/null || true)"
  for ((port = 10#$HY2_PORT_START; port <= 10#$HY2_PORT_END; port++)); do
    output="$(ss -H -lnup "sport = :$port" 2>&1)" ||
      die "Unable to inspect UDP port $port: $output"
    if [[ -n "$output" ]]; then
      if listener_output_is_only_expected_service "$output" hysteria "$owned_pid"; then
        continue
      fi
      [[ -z "$HY2_CONFLICT_DETAILS" ]] || HY2_CONFLICT_DETAILS+=$'\n'
      HY2_CONFLICT_DETAILS+="UDP $port conflict:"$'\n'"$output"
    fi
  done
  [[ -n "$HY2_CONFLICT_DETAILS" ]]
}

shadowsocks_port_conflicts() {
  local owned_pid=""
  valid_port "$SS_PORT" || die "Invalid Shadowsocks port: $SS_PORT"
  SS_PORT="$(normalize_port "$SS_PORT")"
  SS_CONFLICT_DETAILS="$(ss -H -lntup "sport = :$SS_PORT" 2>&1)" ||
    die "Unable to inspect TCP/UDP port $SS_PORT: $SS_CONFLICT_DETAILS"
  owned_pid="$(project_xray_listener_pid 2>/dev/null || true)"
  if [[ -n "$SS_CONFLICT_DETAILS" ]] &&
    listener_output_is_only_expected_service "$SS_CONFLICT_DETAILS" xray "$owned_pid"; then
    SS_CONFLICT_DETAILS=""
  fi
  [[ -n "$SS_CONFLICT_DETAILS" ]]
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

resolve_hysteria_port_range() {
  local attempt replacement
  hysteria_range_conflicts || return 0
  for attempt in 1 2 3 4 5; do
    warn "Hysteria2 UDP range $HY2_PORT_RANGE is unavailable: $HY2_CONFLICT_DETAILS"
    read -r -p "Enter a replacement Hysteria2 UDP range START-END (or q to cancel): " replacement ||
      die "Port selection cancelled"
    [[ "$replacement" != "q" && "$replacement" != "Q" ]] || die "Port selection cancelled"
    parse_port_range "$replacement" || {
      warn "Hysteria2 requires START-END with a span no larger than 1000"
      continue
    }
    HY2_PORT_RANGE="$HY2_PORT_START-$HY2_PORT_END"
    hysteria_range_conflicts || return 0
  done
  die "Unable to select an available Hysteria2 UDP range after 5 attempts"
}

resolve_shadowsocks_port() {
  local attempt replacement
  shadowsocks_port_conflicts || return 0
  for attempt in 1 2 3 4 5; do
    warn "Shadowsocks TCP/UDP port $SS_PORT is unavailable: $SS_CONFLICT_DETAILS"
    read -r -p "Enter a replacement Shadowsocks TCP/UDP port (or q to cancel): " replacement ||
      die "Port selection cancelled"
    [[ "$replacement" != "q" && "$replacement" != "Q" ]] || die "Port selection cancelled"
    valid_port "$replacement" || {
      warn "Shadowsocks requires a port from 1 through 65535"
      continue
    }
    SS_PORT="$(normalize_port "$replacement")"
    shadowsocks_port_conflicts || return 0
  done
  die "Unable to select an available Shadowsocks port after 5 attempts"
}

resolve_direct_port_conflicts() {
  local hy2_conflict=0 ss_conflict=0 message=""
  if mode_has_hysteria && hysteria_range_conflicts; then
    hy2_conflict=1
  fi
  if mode_has_shadowsocks && shadowsocks_port_conflicts; then
    ss_conflict=1
  fi
  if ((hy2_conflict == 0 && ss_conflict == 0)); then
    return 0
  fi
  if ! stdin_is_tty; then
    if ((hy2_conflict == 1)); then
      message="Hysteria2 UDP range $HY2_PORT_RANGE is occupied. Rerun using --hy2-port-range START-END. Conflict details:"$'\n'"$HY2_CONFLICT_DETAILS"
    fi
    if ((ss_conflict == 1)); then
      [[ -z "$message" ]] || message+=$'\n'
      message+="Shadowsocks TCP/UDP port $SS_PORT is occupied. Rerun using --ss-port PORT. Conflict details:"$'\n'"$SS_CONFLICT_DETAILS"
    fi
    die "$message"
  fi
  ((hy2_conflict == 0)) || resolve_hysteria_port_range
  ((ss_conflict == 0)) || resolve_shadowsocks_port
}

resolve_public_port_conflicts() {
  local full_listeners=""
  if mode_has_cloudflare; then
    resolve_cloudflare_port
    if port_listener_conflicts acme 80; then
      full_listeners="$(complete_listener_diagnostics)"
      die "TCP port 80 is unavailable for the ACME HTTP-01 challenge. Conflict: $PORT_CONFLICT_DETAILS
ss -lntp output:
$full_listeners"
    fi
  fi
  if mode_has_hysteria || mode_has_shadowsocks; then
    resolve_direct_port_conflicts
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
  return 0
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
  if mode_has_cloudflare; then
    run_guarded_service_action nginx install_packages "${base_packages[@]}"
    run_guarded_service_action nginx install_packages nginx certbot
    if ! run_guarded_service_action nginx install_packages python3-certbot-nginx; then
      warn "The optional certbot Nginx plugin is unavailable; webroot issuance will still be used."
    fi
  else
    install_packages "${base_packages[@]}"
  fi
}

install_xray_core() (
  local installer
  log "Installing or updating Xray from the official XTLS installer..."
  installer="$(curl -LfsS --connect-timeout 10 --max-time 120 "$XRAY_INSTALL_URL")"
  [[ -n "$installer" ]] || die "The official Xray installer download was empty"
  unset DAT_PATH JSON_PATH JSONS_PATH BASH_ENV ENV check_all_service_files XRAY_CUSTOMIZE
  DAT_PATH="$XRAY_DATA_DIR" JSON_PATH="$(dirname "$XRAY_CONFIG")" \
    bash -c "$installer" @ install
)

stage_hysteria_binary() (
  local staged="$1" staged_dir effective_file="" hashes_file="" effective_url=""
  local release_version="" hashes_url line expected_hash="" actual_hash checksum_output
  local target_count=0 valid_count=0 keep_binary="0"
  cleanup_hysteria_download() {
    [[ -z "$effective_file" ]] || rm -f -- "$effective_file" || true
    [[ -z "$hashes_file" ]] || rm -f -- "$hashes_file" || true
    if [[ "$keep_binary" != "1" ]]; then
      rm -f -- "$staged" || true
    fi
  }
  trap cleanup_hysteria_download EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  umask 077
  [[ "$staged" != "$HYSTERIA_BIN" ]] || die "Hysteria2 must be validated in staging before installation"
  staged_dir="$(dirname "$staged")"
  install -d -m 0700 "$staged_dir" || die "Unable to create the Hysteria2 staging directory"
  [[ -d "$staged_dir" && ! -L "$staged_dir" ]] || die "Invalid Hysteria2 staging directory"
  rm -f -- "$staged" || die "Unable to clear the Hysteria2 staging binary"
  effective_file="$(mktemp "$staged_dir/.hysteria-effective.XXXXXX")" ||
    die "Unable to create the Hysteria2 effective URL file"
  if ! curl -LfsS --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --max-time 120 -o "$staged" \
    --write-out '%{url_effective}\n' "$HYSTERIA_DOWNLOAD_URL" >"$effective_file"; then
    die "Unable to download the official Hysteria2 binary"
  fi
  [[ -f "$staged" && ! -L "$staged" && -s "$staged" ]] ||
    die "The official Hysteria2 binary download was empty or invalid"

  [[ "$(wc -l <"$effective_file" | tr -d '[:space:]')" == "1" ]] ||
    die "Hysteria2 binary effective URL was malformed"
  IFS= read -r effective_url <"$effective_file" ||
    die "Hysteria2 binary effective URL was missing"
  [[ "$effective_url" != *$'\r'* ]] ||
    die "Hysteria2 binary effective URL was malformed"
  if [[ "$effective_url" =~ ^https://download\.hysteria\.network/app/(v[0-9]+\.[0-9]+\.[0-9]+)/hysteria-linux-amd64$ ]]; then
    release_version="${BASH_REMATCH[1]}"
  elif [[ "$effective_url" =~ ^https://github\.com/apernet/hysteria/releases/download/app%2F(v[0-9]+\.[0-9]+\.[0-9]+)/hysteria-linux-amd64$ ]]; then
    release_version="${BASH_REMATCH[1]}"
  elif [[ "$effective_url" =~ ^https://github\.com/apernet/hysteria/releases/download/app/(v[0-9]+\.[0-9]+\.[0-9]+)/hysteria-linux-amd64$ ]]; then
    release_version="${BASH_REMATCH[1]}"
  else
    die "Hysteria2 binary effective URL was not an official versioned release asset"
  fi

  hashes_url="https://github.com/apernet/hysteria/releases/download/app/$release_version/hashes.txt"
  hashes_file="$(mktemp "$staged_dir/.hysteria-hashes.XXXXXX")" ||
    die "Unable to create the Hysteria2 checksum file"
  if ! curl -LfsS --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --max-time 120 -o "$hashes_file" "$hashes_url"; then
    die "Unable to download the Hysteria2 release checksums"
  fi
  [[ -f "$hashes_file" && ! -L "$hashes_file" && -s "$hashes_file" ]] ||
    die "The Hysteria2 release checksum file was empty or invalid"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == *"build/hysteria-linux-amd64" ]]; then
      ((target_count += 1))
      if [[ "$line" =~ ^([0-9a-f]{64})\ \ build/hysteria-linux-amd64$ ]]; then
        ((valid_count += 1))
        expected_hash="${BASH_REMATCH[1]}"
      fi
    fi
  done <"$hashes_file"
  [[ "$target_count" == "1" && "$valid_count" == "1" ]] ||
    die "Hysteria2 release checksum entry was missing, duplicate, or malformed"

  checksum_output="$(sha256sum -- "$staged")" ||
    die "Unable to calculate the Hysteria2 binary checksum"
  actual_hash="${checksum_output%% *}"
  [[ "$actual_hash" =~ ^[0-9a-f]{64}$ ]] ||
    die "The calculated Hysteria2 binary checksum was malformed"
  [[ "$actual_hash" == "$expected_hash" ]] ||
    die "Hysteria2 binary checksum mismatch"

  chmod 0700 "$staged" || die "Unable to protect the staged Hysteria2 binary"
  if ! "$staged" version >/dev/null 2>&1; then
    die "Hysteria2 version validation failed"
  fi
  chmod 0755 "$staged" || die "Unable to finalize the staged Hysteria2 binary"
  keep_binary="1"
)

install_validated_hysteria_binary() {
  local staged="$1"
  [[ -f "$staged" && ! -L "$staged" && -s "$staged" ]] ||
    die "Validated Hysteria2 staging binary is missing"
  [[ "$(stat -c '%a' "$staged")" == "755" ]] ||
    die "Hysteria2 staging binary has not passed validation"
  install -o root -g root -m 0755 "$staged" "$HYSTERIA_BIN"
}

write_hysteria_account_record() {
  printf '%s\n' "$2" >"$1"
}

record_hysteria_account_state() {
  local user_state="$1" group_state="$2" journal="${BACKUP_DIR:-}/accounts"
  local mode owner temp_path record
  case "$user_state" in absent|preexisting|created) ;; *) return 1 ;; esac
  case "$group_state" in preexisting|created) ;; *) return 1 ;; esac
  [[ -f "$journal" && ! -L "$journal" ]] || return 1
  mode="$(stat -c '%a' "$journal" 2>/dev/null)" || return 1
  owner="$(stat -c '%u' "$journal" 2>/dev/null)" || return 1
  [[ "$mode" == "600" && "$owner" == "0" ]] || return 1
  temp_path="$(mktemp "$BACKUP_DIR/.accounts.XXXXXX")" || return 1
  record="hysteria"$'\t'"$user_state"$'\t'"$group_state"
  if ! write_hysteria_account_record "$temp_path" "$record" ||
    ! chmod 0600 "$temp_path" || ! mv -f -- "$temp_path" "$journal"; then
    rm -f -- "$temp_path"
    return 1
  fi
  [[ -f "$journal" && ! -L "$journal" ]] || return 1
  mode="$(stat -c '%a' "$journal" 2>/dev/null)" || return 1
  owner="$(stat -c '%u' "$journal" 2>/dev/null)" || return 1
  [[ "$mode" == "600" && "$owner" == "0" ]]
}

hysteria_system_account_limits() {
  local login_defs="${LOGIN_DEFS_FILE:-/etc/login.defs}" uid_max="999" gid_max="999" value
  if [[ -f "$login_defs" && ! -L "$login_defs" ]]; then
    value="$(awk '$1 == "SYS_UID_MAX" && $2 ~ /^[0-9]+$/ { found=$2 } END { if (found != "") print found }' "$login_defs")"
    [[ -z "$value" ]] || uid_max="$value"
    value="$(awk '$1 == "SYS_GID_MAX" && $2 ~ /^[0-9]+$/ { found=$2 } END { if (found != "") print found }' "$login_defs")"
    [[ -z "$value" ]] || gid_max="$value"
  fi
  [[ "$uid_max" =~ ^[1-9][0-9]*$ && "$gid_max" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s:%s\n' "$uid_max" "$gid_max"
}

hysteria_account_identity_is_safe() {
  local passwd_entry group_entry limits uid gid passwd_gid primary_gid groups primary_name home shell members_field
  passwd_entry="$(getent passwd hysteria 2>/dev/null)" || return 1
  group_entry="$(getent group hysteria 2>/dev/null)" || return 1
  limits="$(hysteria_system_account_limits)" || return 1
  uid="$(awk -F: '{print $3}' <<<"$passwd_entry")"
  passwd_gid="$(awk -F: '{print $4}' <<<"$passwd_entry")"
  gid="$(awk -F: '{print $3}' <<<"$group_entry")"
  members_field="$(awk -F: '{print $4}' <<<"$group_entry")"
  home="$(awk -F: '{print $6}' <<<"$passwd_entry")"
  shell="$(awk -F: '{print $7}' <<<"$passwd_entry")"
  [[ "$uid" =~ ^[1-9][0-9]*$ && "$gid" =~ ^[1-9][0-9]*$ && "$passwd_gid" == "$gid" ]] || return 1
  [[ -z "$members_field" ]] || return 1
  ((10#$uid <= 10#${limits%%:*} && 10#$gid <= 10#${limits#*:})) || return 1
  [[ "$home" == "/nonexistent" ]] || return 1
  [[ "$shell" == "/usr/sbin/nologin" || "$shell" == "/sbin/nologin" ]] || return 1
  [[ "$(id -u hysteria 2>/dev/null)" == "$uid" ]] || return 1
  primary_gid="$(id -g hysteria 2>/dev/null)" || return 1
  [[ "$primary_gid" == "$gid" ]] || return 1
  primary_name="$(id -gn hysteria 2>/dev/null)" || return 1
  [[ "$primary_name" == "hysteria" ]] || return 1
  groups="$(id -G hysteria 2>/dev/null)" || return 1
  [[ "$groups" == "$gid" ]] || return 1
  printf '%s:%s\n' "$uid" "$gid"
}

ensure_hysteria_account() {
  local user_state="preexisting" group_state="preexisting"
  if ! getent group hysteria >/dev/null 2>&1; then
    groupadd --system hysteria
    group_state="created"
    if ! record_hysteria_account_state absent "$group_state"; then
      groupdel hysteria >/dev/null 2>&1 || true
      die "Hysteria2 account journal could not record the created group"
    fi
  fi
  if ! id hysteria >/dev/null 2>&1; then
    useradd --system --gid hysteria --home-dir /nonexistent --shell /usr/sbin/nologin hysteria
    user_state="created"
    if ! record_hysteria_account_state "$user_state" "$group_state"; then
      userdel hysteria >/dev/null 2>&1 || true
      [[ "$group_state" != "created" ]] || groupdel hysteria >/dev/null 2>&1 || true
      die "Hysteria2 account journal could not record the created user"
    fi
  fi
  hysteria_account_identity_is_safe >/dev/null ||
    die "Hysteria2 account must be a non-root system identity without supplementary groups or other group members"
  if ! record_hysteria_account_state "$user_state" "$group_state"; then
    if [[ "$user_state" == "created" ]]; then
      userdel hysteria >/dev/null 2>&1 || true
    fi
    if [[ "$group_state" == "created" ]]; then
      groupdel hysteria >/dev/null 2>&1 || true
    fi
    die "Hysteria2 account journal could not record the validated account"
  fi
}

generate_hysteria_certificate_files() (
  local staged_cert="$1" staged_key="$2" config="" pin cert_dir key_dir
  local keep_files="0"
  cleanup_hysteria_certificate_files() {
    [[ -z "$config" ]] || rm -f -- "$config" || true
    if [[ "$keep_files" != "1" ]]; then
      rm -f -- "$staged_cert" "$staged_key" || true
    fi
  }
  trap cleanup_hysteria_certificate_files EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  unexport_sensitive_runtime_values
  cert_dir="$(dirname "$staged_cert")"
  key_dir="$(dirname "$staged_key")"
  install -d -m 0700 "$cert_dir" "$key_dir" || exit 1
  config="$(mktemp "$cert_dir/.openssl-hysteria.XXXXXX")" || exit 1
  chmod 0600 "$config" || exit 1
  printf '%s\n' \
    '[req]' \
    'distinguished_name=dn' \
    'prompt=no' \
    'x509_extensions=v3_req' \
    '[dn]' \
    "CN=$HY2_SNI" \
    '[v3_req]' \
    "subjectAltName=DNS:$HY2_SNI" >"$config" || exit 1
  rm -f -- "$staged_cert" "$staged_key" || exit 1
  if ! openssl ecparam -genkey -name prime256v1 -noout -out "$staged_key"; then
    exit 1
  fi
  chmod 0400 "$staged_key" || exit 1
  if ! openssl req -new -x509 -sha256 -days 3650 -key "$staged_key" \
    -out "$staged_cert" -config "$config"; then
    exit 1
  fi
  rm -f -- "$config" || exit 1
  config=""
  chmod 0440 "$staged_cert" || exit 1
  pin="$(
    openssl x509 -noout -fingerprint -sha256 -in "$staged_cert" 2>/dev/null |
      awk -F= 'NF == 2 { print $2 }' | tr 'a-f' 'A-F' | tr -d '\r\n'
  )" || exit 1
  valid_hy2_cert_pin "$pin" || exit 1
  keep_files="1"
  printf '%s\n' "$pin"
)

generate_hysteria_certificate() {
  local staged_cert="$1" staged_key="$2" pin
  unexport_sensitive_runtime_values
  valid_hy2_sni "$HY2_SNI" || die "Invalid generated Hysteria2 SNI"
  pin="$(generate_hysteria_certificate_files "$staged_cert" "$staged_key")" ||
    die "Unable to generate the Hysteria2 certificate or compute its pin"
  valid_hy2_cert_pin "$pin" || die "Unable to compute a valid Hysteria2 certificate pin"
  HY2_CERT_PIN="$pin"
  export -n HY2_CERT_PIN 2>/dev/null || true
}

render_hysteria_config() (
  local output_path="$1" cert_path="$2" key_path="$3" acl_path="$4"
  local listen_value="${5:-$HY2_PORT_RANGE}"
  local output_dir temp_path="" render_status="0" source_path normalized_port
  cleanup_hysteria_config_render() {
    [[ -z "$temp_path" ]] || rm -f -- "$temp_path" || true
  }
  trap cleanup_hysteria_config_render EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  unexport_sensitive_runtime_values
  if valid_port "$listen_value"; then
    normalized_port="$(normalize_port "$listen_value")"
    listen_value="$normalized_port"
  else
    valid_hy2_port_range "$listen_value" || die "Invalid Hysteria2 listen port or range"
  fi
  valid_hy2_secret "$HY2_AUTH" || die "Invalid Hysteria2 authentication value"
  valid_hy2_secret "$HY2_OBFS_PASSWORD" || die "Invalid Hysteria2 obfuscation value"
  for source_path in "$cert_path" "$key_path" "$acl_path"; do
    if [[ -e "$source_path" || -L "$source_path" ]]; then
      [[ -f "$source_path" && ! -L "$source_path" ]] ||
        die "Hysteria2 renderer source must not be a symlink or non-regular file"
    fi
  done
  output_dir="$(dirname "$output_path")"
  install -d -m 0700 "$output_dir" || die "Unable to create the Hysteria2 config staging directory"
  temp_path="$(mktemp "$output_dir/.hysteria-config.XXXXXX")" ||
    die "Unable to create the Hysteria2 config staging file"
  printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$listen_value" "$HY2_AUTH" "$HY2_OBFS_PASSWORD" \
    "$cert_path" "$key_path" "$acl_path" |
    python3 - "$temp_path" 3<&0 <<'PY' || render_status=$?
import json
import os
import sys


records = os.fdopen(3, "rb").read().decode("utf-8").split("\0")
if records[-1] != "" or len(records) != 7:
    raise SystemExit("invalid Hysteria2 renderer input")
port_range, auth, obfs_password, cert, key, acl = records[:-1]


def quoted(value):
    return json.dumps(value, ensure_ascii=True)


content = "\n".join(
    [
        "# Managed by v2ray-onekey: Hysteria2 config v1",
        "listen: " + quoted(":" + port_range),
        "tls:",
        "  cert: " + quoted(cert),
        "  key: " + quoted(key),
        "  sniGuard: " + quoted("strict"),
        "auth:",
        "  type: " + quoted("password"),
        "  password: " + quoted(auth),
        "obfs:",
        "  type: " + quoted("salamander"),
        "  salamander:",
        "    password: " + quoted(obfs_password),
        "acl:",
        "  file: " + quoted(acl),
        "",
    ]
)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(content)
PY
  if (( render_status != 0 )); then
    rm -f -- "$temp_path" || true
    return "$render_status"
  fi
  chmod 0600 "$temp_path" || return 1
  mv -f -- "$temp_path" "$output_path" || return 1
  temp_path=""
)

render_hysteria_acl() (
  local output_path="$1" output_dir temp_path=""
  cleanup_hysteria_acl_render() {
    [[ -z "$temp_path" ]] || rm -f -- "$temp_path" || true
  }
  trap cleanup_hysteria_acl_render EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  output_dir="$(dirname "$output_path")"
  install -d -m 0700 "$output_dir" || die "Unable to create the Hysteria2 ACL staging directory"
  temp_path="$(mktemp "$output_dir/.hysteria-acl.XXXXXX")" ||
    die "Unable to create the Hysteria2 ACL staging file"
  {
    printf '%s\n' "$HYSTERIA_ACL_MARKER"
    printf '%s\n' \
      'reject(0.0.0.0/8)' \
      'reject(10.0.0.0/8)' \
      'reject(100.64.0.0/10)' \
      'reject(127.0.0.0/8)' \
      'reject(169.254.0.0/16)' \
      'reject(172.16.0.0/12)' \
      'reject(192.168.0.0/16)' \
      'reject(224.0.0.0/4)' \
      'reject(::1/128)' \
      'reject(fc00::/7)' \
      'reject(fe80::/10)'
    if [[ "$ALLOW_MAIL" != "1" ]]; then
      printf '%s\n' \
        'reject(all, tcp/25)' \
        'reject(all, tcp/465)' \
        'reject(all, tcp/587)'
    fi
    printf '%s\n' 'direct(all)'
  } >"$temp_path" || return 1
  # Hysteria2 has no reliable BitTorrent matcher; Xray enforces that policy separately.
  chmod 0600 "$temp_path" || return 1
  mv -f -- "$temp_path" "$output_path" || return 1
  temp_path=""
)

render_hysteria_unit() (
  local output_path="$1" output_dir temp_path=""
  cleanup_hysteria_unit_render() {
    [[ -z "$temp_path" ]] || rm -f -- "$temp_path" || true
  }
  trap cleanup_hysteria_unit_render EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  output_dir="$(dirname "$output_path")"
  install -d -m 0755 "$output_dir" || die "Unable to create the Hysteria2 unit staging directory"
  temp_path="$(mktemp "$output_dir/.hysteria-unit.XXXXXX")" ||
    die "Unable to create the Hysteria2 unit staging file"
  cat >"$temp_path" <<'EOF' || return 1
# Managed by v2ray-onekey: Hysteria2 unit v1
[Unit]
Description=Hysteria2 Server
After=network-online.target
Wants=network-online.target

[Service]
User=hysteria
Group=hysteria
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5s
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$temp_path" || return 1
  mv -f -- "$temp_path" "$output_path" || return 1
  temp_path=""
)

install_hysteria_runtime_files() {
  local staged_config="$1" staged_acl="$2" staged_cert="$3" staged_key="$4"
  local staged_unit="$5" staged
  for staged in "$staged_config" "$staged_acl" "$staged_cert" "$staged_key" "$staged_unit"; do
    [[ -f "$staged" && ! -L "$staged" && -s "$staged" ]] ||
      die "Invalid Hysteria2 staging file"
  done
  install -d -o root -g hysteria -m 0750 "$(dirname "$HYSTERIA_CONFIG")"
  install -o root -g hysteria -m 0440 "$staged_config" "$HYSTERIA_CONFIG"
  install -o root -g hysteria -m 0440 "$staged_acl" "$HYSTERIA_ACL"
  install -o root -g hysteria -m 0440 "$staged_cert" "$HYSTERIA_CERT"
  install -o root -g hysteria -m 0440 "$staged_key" "$HYSTERIA_KEY"
  install -o root -g root -m 0644 "$staged_unit" "$HYSTERIA_UNIT"
}

verify_hysteria_service_definition() {
  local loaded_user loaded_group loaded_unit path identity
  loaded_user="$(systemctl show -p User --value hysteria-server 2>/dev/null)" ||
    die "Unable to inspect the Hysteria2 service user"
  loaded_group="$(systemctl show -p Group --value hysteria-server 2>/dev/null)" ||
    die "Unable to inspect the Hysteria2 service group"
  [[ "$loaded_user" == "hysteria" && "$loaded_group" == "hysteria" ]] ||
    die "Hysteria2 is not loaded with the dedicated service identity"
  loaded_unit="$(systemctl cat hysteria-server 2>/dev/null)" ||
    die "Unable to inspect the loaded Hysteria2 unit"
  for identity in \
    'User=hysteria' \
    'Group=hysteria' \
    'ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml' \
    'AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE' \
    'CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE' \
    'NoNewPrivileges=true'; do
    grep -Fqx "$identity" <<<"$loaded_unit" ||
      die "Loaded Hysteria2 unit is missing the required identity or capability setting: $identity"
  done
  for path in "$HYSTERIA_CONFIG" "$HYSTERIA_ACL" "$HYSTERIA_CERT" "$HYSTERIA_KEY"; do
    identity="$(stat -c '%U:%G:%a' "$path" 2>/dev/null)" ||
      die "Unable to inspect Hysteria2 file permissions: $path"
    [[ "$identity" == "root:hysteria:440" ]] ||
      die "Unsafe Hysteria2 file permissions on $path: $identity"
  done
  [[ "$(stat -c '%U:%G:%a' "$(dirname "$HYSTERIA_CONFIG")" 2>/dev/null)" == "root:hysteria:750" ]] ||
    die "Unsafe Hysteria2 configuration directory permissions"
  [[ "$(stat -c '%U:%G:%a' "$HYSTERIA_BIN" 2>/dev/null)" == "root:root:755" ]] ||
    die "Unsafe Hysteria2 binary permissions"
  [[ "$(stat -c '%U:%G:%a' "$HYSTERIA_UNIT" 2>/dev/null)" == "root:root:644" ]] ||
    die "Unsafe Hysteria2 unit permissions"
}

verify_hysteria_runtime_identity() {
  local pid diagnostic
  pid="$(systemctl show -p MainPID --value hysteria-server 2>/dev/null)" ||
    die "Unable to inspect the Hysteria2 MainPID"
  diagnostic="$(inspect_hysteria_runtime_identity "$pid")" || die "$diagnostic"
}

validate_hysteria_staged() (
  local binary="$1" config="$2" log_path="$3" status runner_pid=""
  terminate_hysteria_smoke() {
    [[ -n "$runner_pid" ]] || return 0
    kill -TERM -- "-$runner_pid" >/dev/null 2>&1 || kill -TERM "$runner_pid" >/dev/null 2>&1 || true
    sleep 1
    kill -KILL -- "-$runner_pid" >/dev/null 2>&1 || kill -KILL "$runner_pid" >/dev/null 2>&1 || true
    wait "$runner_pid" >/dev/null 2>&1 || true
    runner_pid=""
  }
  trap terminate_hysteria_smoke EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  unexport_sensitive_runtime_values
  : >"$log_path"
  chmod 0600 "$log_path"
  set +e
  timeout --signal=TERM --kill-after=2s 4s \
    "$binary" server -c "$config" >"$log_path" 2>&1 &
  runner_pid=$!
  wait "$runner_pid"
  status=$?
  runner_pid=""
  set -e
  if [[ "$status" != "124" && "$status" != "143" ]] ||
    ! grep -Fq 'server up and running' "$log_path"; then
    die "Hysteria2 staged validation did not become ready"
  fi
)

hysteria_certificate_pin() {
  local cert="$1" pin
  pin="$(
    openssl x509 -noout -fingerprint -sha256 -in "$cert" 2>/dev/null |
      awk -F= 'NF == 2 { print $2 }' | tr 'a-f' 'A-F' | tr -d '\r\n'
  )" || return 1
  valid_hy2_cert_pin "$pin" || return 1
  printf '%s\n' "$pin"
}

require_hysteria_port_hopping_backend() {
  command -v nft >/dev/null 2>&1 || command -v iptables >/dev/null 2>&1 ||
    die "Hysteria2 port hopping requires nftables or iptables"
}

select_hysteria_smoke_port() {
  local port output
  for ((port = 49152; port <= 65535; port++)); do
    if [[ "$port" -ge "${HY2_PORT_START:-0}" && "$port" -le "${HY2_PORT_END:-0}" ]]; then
      continue
    fi
    output="$(ss -H -lnup "sport = :$port" 2>&1)" ||
      die "Unable to inspect Hysteria2 smoke UDP port $port: $output"
    if [[ -z "$output" ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  done
  die "Unable to find a free high UDP port for Hysteria2 staged validation"
}

stage_hysteria_bundle() {
  local staged_binary="$1" staged_config="$2" staged_acl="$3" staged_cert="$4"
  local staged_key="$5" staged_unit="$6" staged_smoke_config="$7" smoke_log="$8" pin smoke_port
  require_hysteria_port_hopping_backend
  stage_hysteria_binary "$staged_binary"
  render_hysteria_acl "$staged_acl"
  if [[ "$ROTATE" != "1" ]] && hysteria_ownership_manifest_is_valid; then
    cp -a -- "$HYSTERIA_CERT" "$staged_cert"
    cp -a -- "$HYSTERIA_KEY" "$staged_key"
    chmod 0440 "$staged_cert" "$staged_key"
    pin="$(hysteria_certificate_pin "$staged_cert")" ||
      die "Unable to validate the managed Hysteria2 certificate pin"
    [[ "$pin" == "$HY2_CERT_PIN" ]] ||
      die "Managed Hysteria2 certificate does not match the saved pin"
  else
    generate_hysteria_certificate "$staged_cert" "$staged_key"
  fi
  smoke_port="$(select_hysteria_smoke_port)"
  render_hysteria_config "$staged_smoke_config" "$staged_cert" "$staged_key" "$staged_acl" "$smoke_port"
  validate_hysteria_staged "$staged_binary" "$staged_smoke_config" "$smoke_log"
  render_hysteria_config "$staged_config" "$HYSTERIA_CERT" "$HYSTERIA_KEY" "$HYSTERIA_ACL"
  render_hysteria_unit "$staged_unit"
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
  unexport_sensitive_runtime_values
  output_dir="$(dirname "$output_path")"
  install -d -m 755 "$output_dir"
  temp_path="$(mktemp "$output_dir/.xray-config.XXXXXX")"
  printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$MODE" "$INTERNAL_WS_PORT" "$CLOUDFLARE_UUID" "$WS_PATH" \
    "$ALLOW_BITTORRENT" "$SS_PORT" "$SS_METHOD" "$SS_KEY" |
    python3 - "$temp_path" 3<&0 <<'PY' || render_status=$?
import json
import os
import sys


records = os.fdopen(3, "rb").read().decode("utf-8").split("\0")
if records[-1] != "" or len(records) != 9:
    raise SystemExit("invalid renderer input")
(
    mode,
    internal_ws_port,
    cloudflare_uuid,
    ws_path,
    allow_bittorrent,
    ss_port,
    ss_method,
    ss_key,
) = records[:-1]
output_path = sys.argv[1]

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

if mode in ("direct", "full"):
    inbounds.append(
        {
            "tag": "shadowsocks-2022-in",
            "listen": "0.0.0.0",
            "port": int(ss_port),
            "protocol": "shadowsocks",
            "settings": {
                "method": ss_method,
                "password": ss_key,
                "network": "tcp,udp",
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
  case "$1" in
    *:*) printf '[%s]\n' "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

append_firewall_record() {
  printf '%s\t%s\n' "$1" "$2" >>"$BACKUP_DIR/firewall-rules"
}

record_firewall_addition() {
  local backend="$1" rule="$2" journal="${BACKUP_DIR:-}/firewall-rules"
  [[ -f "$journal" && ! -L "$journal" ]] || die "Firewall journal is unavailable"
  append_firewall_record "$backend" "$rule" || die "Unable to persist firewall rollback rule $rule"
  chmod 0600 "$journal" || die "Unable to secure firewall rollback journal"
}

ufw_rule_exists() {
  local rule="$1" output status=0
  output="$(LC_ALL=C ufw status 2>/dev/null)" || status=$?
  [[ "$status" -eq 0 ]] || return 2
  awk -v wanted="$rule" 'NR > 1 && $1 == wanted { found = 1 } END { exit !found }' <<<"$output"
}

firewalld_is_active() {
  local output status=0
  output="$(LC_ALL=C systemctl is-active firewalld 2>/dev/null)" || status=$?
  [[ "$output" != *$'\n'* && "$output" =~ ^[a-z-]+$ ]] || return 2
  if [[ "$status" -eq 0 && "$output" == "active" ]]; then
    return 0
  fi
  if { [[ "$status" -eq 3 && "$output" == "inactive" ]] ||
    [[ "$status" -eq 4 && "$output" == "unknown" ]]; }; then
    return 1
  fi
  return 2
}

open_firewall_rule() {
  local ufw_rule="$1" firewalld_rule="$2" status=0 firewall_state=""
  if command -v ufw >/dev/null 2>&1; then
    firewall_state="$(LC_ALL=C ufw status 2>/dev/null)" ||
      die "Unable to inspect UFW status"
    if grep -Fqx "Status: active" <<<"$firewall_state"; then
      if ufw_rule_exists "$ufw_rule"; then
        :
      else
        status=$?
        [[ "$status" -eq 1 ]] || die "Unable to query active UFW rule $ufw_rule"
        record_firewall_addition ufw "$ufw_rule"
        ufw allow "$ufw_rule" >/dev/null || die "UFW failed to allow required rule $ufw_rule"
      fi
    elif ! grep -Fqx "Status: inactive" <<<"$firewall_state"; then
      die "Unable to classify UFW status"
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    if firewalld_is_active; then
      :
    else
      status=$?
      [[ "$status" -eq 1 ]] && return 0
      die "Unable to inspect firewalld state"
    fi
    if firewall-cmd --query-port="$firewalld_rule" >/dev/null 2>&1; then
      :
    else
      status=$?
      [[ "$status" -eq 1 ]] || die "Unable to query active firewalld runtime rule $firewalld_rule"
      record_firewall_addition firewalld-runtime "$firewalld_rule"
      firewall-cmd --add-port="$firewalld_rule" >/dev/null ||
        die "firewalld failed to add required runtime rule $firewalld_rule"
    fi
    if firewall-cmd --permanent --query-port="$firewalld_rule" >/dev/null 2>&1; then
      :
    else
      status=$?
      [[ "$status" -eq 1 ]] || die "Unable to query active firewalld permanent rule $firewalld_rule"
      record_firewall_addition firewalld-permanent "$firewalld_rule"
      firewall-cmd --permanent --add-port="$firewalld_rule" >/dev/null ||
        die "firewalld failed to add required permanent rule $firewalld_rule"
    fi
  fi
}

open_firewall_port() {
  local port="$1" proto="${2:-tcp}"
  valid_port "$port" || die "Invalid firewall port: $port"
  [[ "$proto" == "tcp" || "$proto" == "udp" ]] || die "Invalid firewall protocol: $proto"
  port="$(normalize_port "$port")"
  open_firewall_rule "$port/$proto" "$port/$proto"
}

open_firewall_range() {
  local start="$1" end="$2" proto="${3:-udp}"
  parse_port_range "$start-$end" || die "Invalid firewall port range: $start-$end"
  [[ "$proto" == "udp" ]] || die "Hysteria2 firewall ranges must use UDP"
  open_firewall_rule "$HY2_PORT_START:$HY2_PORT_END/$proto" "$HY2_PORT_START-$HY2_PORT_END/$proto"
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

validate_staged_nginx_config() (
  local staged="$1" phase="$2" prefix="" candidate nginx_config
  local test_cert test_key source_cert source_key
  cleanup_staged_nginx_validation() {
    [[ -z "$prefix" ]] || rm -rf -- "$prefix" || true
  }
  trap cleanup_staged_nginx_validation EXIT

  [[ "$phase" == "initial" || "$phase" == "final" ]] ||
    die "Invalid staged Nginx validation phase: $phase"
  [[ -f "$staged" && ! -L "$staged" ]] || die "Staged Nginx config is missing: $staged"
  [[ -n "${RUNTIME_DIR:-}" && -d "$RUNTIME_DIR" && ! -L "$RUNTIME_DIR" ]] ||
    die "Runtime directory is unavailable for staged Nginx validation"
  prefix="$(mktemp -d "$RUNTIME_DIR/nginx-validate.XXXXXX")"
  chmod 0700 "$prefix"
  candidate="$prefix/site.conf"
  nginx_config="$prefix/nginx.conf"

  if [[ "$phase" == "final" ]]; then
    test_cert="$prefix/test.crt"
    test_key="$prefix/test.key"
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
      -subj '/CN=v2ray-onekey.invalid' -keyout "$test_key" -out "$test_cert" >/dev/null 2>&1 ||
      die "Unable to generate an isolated Nginx validation certificate"
    chmod 0600 "$test_key"
    chmod 0644 "$test_cert"
    source_cert="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    source_key="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    python3 - "$staged" "$candidate" "$source_cert" "$source_key" "$test_cert" "$test_key" <<'PY'
import pathlib
import sys

source, destination, source_cert, source_key, test_cert, test_key = sys.argv[1:]
content = pathlib.Path(source).read_text(encoding="utf-8")
if content.count(source_cert) != 1 or content.count(source_key) != 1:
    raise SystemExit("staged certificate paths are missing or duplicated")
content = content.replace(source_cert, test_cert).replace(source_key, test_key)
pathlib.Path(destination).write_text(content, encoding="utf-8")
PY
  else
    cp -- "$staged" "$candidate"
  fi
  chmod 0600 "$candidate"
  cat >"$nginx_config" <<EOF
worker_processes 1;
pid "$prefix/nginx.pid";
error_log stderr notice;
events { worker_connections 16; }
http {
    access_log off;
    include "$candidate";
}
EOF
  chmod 0600 "$nginx_config"
  nginx -t -p "$prefix/" -c "$nginx_config"
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

stop_project_hysteria_for_cutover() {
  service_was_active hysteria-server || return 0
  project_hysteria_listener_pid >/dev/null ||
    die "Refusing to stop an unproved or unsafe Hysteria2 service for staged validation"
  log "Temporarily stopping the existing project Hysteria2 service for cutover..."
  run_service_mutation hysteria-server stop
}

stop_legacy_service_for_cutover() {
  if service_was_active xray; then
    log "Temporarily stopping the existing Xray service for cutover..."
    run_service_mutation xray stop
  fi
  if service_was_active v2ray; then
    log "Temporarily stopping V2Ray for the validated cutover..."
    run_service_mutation v2ray stop
  fi
  if service_was_active hysteria-server; then
    stop_project_hysteria_for_cutover
  fi
}

activate_nginx_config() {
  nginx -t
  run_service_mutation nginx enable
  if systemctl is-active --quiet nginx; then
    run_service_mutation nginx reload
  else
    run_service_mutation nginx start
  fi
}

release_legacy_nginx_listeners() {
  local nginx_configuration_changed="0"
  disable_owned_legacy_nginx_files
  [[ "$LEGACY_NGINX_FILES_CHANGED" == "0" ]] || nginx_configuration_changed="1"
  if ! mode_has_cloudflare && current_nginx_config_is_project_owned "$NGINX_SITE"; then
    rm -f -- "$NGINX_SITE"
    nginx_configuration_changed="1"
  fi
  if ! mode_has_cloudflare && [[ -e "$RENEWAL_HOOK" ]]; then
    if current_renewal_hook_is_project_owned "$RENEWAL_HOOK"; then
      rm -f -- "$RENEWAL_HOOK"
    else
      warn "Leaving unrecognized renewal hook unchanged: $RENEWAL_HOOK"
    fi
  fi
  if ! mode_has_cloudflare && [[ "$nginx_configuration_changed" == "1" ]]; then
    nginx -t
    if systemctl is-active --quiet nginx; then
      run_service_mutation nginx reload
    fi
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

protocol_listener_output() {
  local protocol="$1" port="$2"
  case "$protocol" in
    tcp) ss -H -lntp "sport = :$port" 2>&1 ;;
    udp) ss -H -lnup "sport = :$port" 2>&1 ;;
    *) return 2 ;;
  esac
}

multi_protocol_services_ready() {
  local output
  systemctl is-active --quiet xray || return 1
  if mode_has_shadowsocks; then
    output="$(protocol_listener_output tcp "$SS_PORT")" || return 1
    [[ -n "$output" && "$output" == *xray* ]] || return 1
    output="$(protocol_listener_output udp "$SS_PORT")" || return 1
    [[ -n "$output" && "$output" == *xray* ]] || return 1
  fi
  if mode_has_hysteria; then
    systemctl is-active --quiet hysteria-server || return 1
    parse_port_range "$HY2_PORT_RANGE" || return 1
    output="$(protocol_listener_output udp "$HY2_PORT_START")" || return 1
    [[ -n "$output" && "$output" == *hysteria* ]] || return 1
  fi
}

print_multi_protocol_diagnostics() {
  print_service_diagnostics xray
  if mode_has_hysteria; then
    print_service_diagnostics hysteria-server
  fi
  warn "Current TCP/UDP listeners:"
  ss -H -lntup 2>&1 || true
}

wait_for_multi_protocol_readiness() {
  local attempt
  for ((attempt = 1; attempt <= LISTENER_WAIT_ATTEMPTS; attempt++)); do
    multi_protocol_services_ready && return 0
    ((attempt < LISTENER_WAIT_ATTEMPTS)) && sleep "$LISTENER_WAIT_INTERVAL"
  done
  print_multi_protocol_diagnostics
  die "Multi-protocol readiness timed out"
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
  wait_for_multi_protocol_readiness
  if mode_has_cloudflare; then
    systemctl is-active --quiet nginx || die "Nginx is not active after reload"
    wait_for_listener_owner "$INTERNAL_WS_PORT" xray 127.0.0.1
    wait_for_listener_owner "$CLOUDFLARE_PORT" nginx
    wait_for_listener_owner 80 nginx
  fi
}

disable_legacy_v2ray_after_success() {
  if service_unit_exists v2ray; then
    run_service_mutation v2ray disable --now
  fi
}

configure_firewall() {
  if mode_has_cloudflare; then
    open_firewall_port 80 tcp
    open_firewall_port "$CLOUDFLARE_PORT" tcp
  fi
  if mode_has_shadowsocks; then
    open_firewall_port "$SS_PORT" tcp
    open_firewall_port "$SS_PORT" udp
  fi
  if mode_has_hysteria; then
    parse_port_range "$HY2_PORT_RANGE" || die "Invalid Hysteria2 UDP range"
    open_firewall_range "$HY2_PORT_START" "$HY2_PORT_END" udp
  fi
}

required_public_ports() {
  if mode_has_cloudflare; then
    printf 'TCP %s\n' 80 "$CLOUDFLARE_PORT"
  fi
  if mode_has_shadowsocks; then
    printf 'TCP %s\nUDP %s\n' "$SS_PORT" "$SS_PORT"
  fi
  if mode_has_hysteria; then
    printf 'UDP %s\n' "$HY2_PORT_RANGE"
  fi
}

print_deployment_summary() {
  local diagnostics="systemctl status xray" journals="journalctl -u xray -e"
  local -a tcp_ports=() udp_ports=()
  printf '\n'
  if mode_has_cloudflare; then
    printf 'Cloudflare entry: VLESS + WebSocket + TLS\n'
    make_cloudflare_link
  fi
  if mode_has_hysteria; then
    printf 'Hysteria2 entry: Salamander + pinned certificate\n'
    make_hysteria_link
  fi
  if mode_has_shadowsocks; then
    printf 'Shadowsocks entry: %s\n' "$SS_METHOD"
    make_shadowsocks_link
  fi
  printf 'State file: %s\n' "$STATE_FILE"
  printf 'Backup: %s\n' "$BACKUP_DIR"
  if mode_has_cloudflare; then
    tcp_ports+=(80 "$CLOUDFLARE_PORT")
  fi
  if mode_has_shadowsocks; then
    tcp_ports+=("$SS_PORT")
    udp_ports+=("$SS_PORT")
  fi
  if mode_has_hysteria; then
    diagnostics+=' hysteria-server'
    journals="journalctl -u xray -u hysteria-server -e"
    udp_ports+=("$HY2_PORT_RANGE")
  fi
  if mode_has_cloudflare; then
    printf 'Diagnostics: %s; %s; nginx -t\n' "$diagnostics" "$journals"
  else
    printf 'Diagnostics: %s; %s\n' "$diagnostics" "$journals"
  fi
  printf 'Cloud security group: TCP %s' "$(IFS=,; printf '%s' "${tcp_ports[*]}")"
  if ((${#udp_ports[@]} > 0)); then
    printf ' and UDP %s' "$(IFS=,; printf '%s' "${udp_ports[*]}")"
  fi
  printf '\n'
  printf 'Warning: only the Cloudflare path avoids direct client connections to the server IP; Hysteria2 and Shadowsocks still connect directly, and no protocol can guarantee that an IP will never be blocked.\n'
}

prepare_runtime_directory() {
  RUNTIME_DIR="${RUNTIME_DIR:-/run/v2ray-onekey/$RUN_TIMESTAMP}"
  [[ "$RUNTIME_DIR" == /* && "$RUNTIME_DIR" != "/" && "$RUNTIME_DIR" != *$'\n'* ]] ||
    die "Invalid runtime staging directory"
  [[ ! -L "$RUNTIME_DIR" ]] || die "Refusing symlink runtime staging directory"
  install -d -m 700 "$RUNTIME_DIR"
  printf '%s\n' "$RUN_TIMESTAMP" >"$RUNTIME_DIR/.v2ray-onekey-runtime"
  chmod 0600 "$RUNTIME_DIR/.v2ray-onekey-runtime"
}

cleanup_runtime_directory() {
  local marker expected
  [[ -n "${RUNTIME_DIR:-}" ]] || return 0
  marker="$RUNTIME_DIR/.v2ray-onekey-runtime"
  [[ "$RUNTIME_DIR" == /* && "$RUNTIME_DIR" != "/" && -d "$RUNTIME_DIR" && ! -L "$RUNTIME_DIR" ]] ||
    return 1
  [[ -f "$marker" && ! -L "$marker" ]] || return 1
  IFS= read -r expected <"$marker" || return 1
  [[ -n "$expected" && "$expected" == "${RUN_TIMESTAMP:-$expected}" ]] || return 1
  rm -rf -- "$RUNTIME_DIR"
  RUNTIME_DIR=""
}

prepare_fresh_inputs() {
  require_mode_ready
  validate_managed_destination_ownership
  if mode_has_cloudflare; then
    [[ -n "$INTERNAL_WS_PORT" ]] || INTERNAL_WS_PORT="$(random_internal_ws_port)"
    validate_cloudflare_preflight
  fi
  check_public_port_listeners
  check_internal_ws_port_listener
}

install_mode_dependencies() {
  install_required_packages
  run_guarded_service_action xray install_xray_core
}

generate_mode_credentials() {
  prepare_runtime_directory
  generate_runtime_values
  validate_loaded_runtime_values
}

stage_mode_configurations() {
  STAGED_XRAY="$RUNTIME_DIR/xray-config.json"
  render_xray_config "$STAGED_XRAY"

  if mode_has_cloudflare; then
    STAGED_NGINX_INITIAL="$RUNTIME_DIR/nginx-initial.conf"
    STAGED_NGINX_FINAL="$RUNTIME_DIR/nginx-final.conf"
    render_nginx_site "$STAGED_NGINX_INITIAL" initial
    render_nginx_site "$STAGED_NGINX_FINAL" final
  fi

  if mode_has_hysteria; then
    STAGED_HYSTERIA_BINARY="$RUNTIME_DIR/hysteria"
    STAGED_HYSTERIA_CONFIG="$RUNTIME_DIR/hysteria-config.yaml"
    STAGED_HYSTERIA_ACL="$RUNTIME_DIR/hysteria-acl.txt"
    STAGED_HYSTERIA_CERT="$RUNTIME_DIR/hysteria-server.crt"
    STAGED_HYSTERIA_KEY="$RUNTIME_DIR/hysteria-server.key"
    STAGED_HYSTERIA_UNIT="$RUNTIME_DIR/hysteria-server.service"
    STAGED_HYSTERIA_SMOKE_CONFIG="$RUNTIME_DIR/hysteria-smoke.yaml"
    STAGED_HYSTERIA_SMOKE_LOG="$RUNTIME_DIR/hysteria-smoke.log"
    stage_hysteria_bundle "$STAGED_HYSTERIA_BINARY" "$STAGED_HYSTERIA_CONFIG" \
      "$STAGED_HYSTERIA_ACL" "$STAGED_HYSTERIA_CERT" "$STAGED_HYSTERIA_KEY" \
      "$STAGED_HYSTERIA_UNIT" "$STAGED_HYSTERIA_SMOKE_CONFIG" "$STAGED_HYSTERIA_SMOKE_LOG"
  fi
}

validate_staged_configurations() {
  xray run -test -config "$STAGED_XRAY"
  if mode_has_cloudflare; then
    validate_staged_nginx_config "$STAGED_NGINX_INITIAL" initial ||
      die "Staged initial Nginx configuration failed syntax validation"
    validate_staged_nginx_config "$STAGED_NGINX_FINAL" final ||
      die "Staged final Nginx configuration failed syntax validation"
  fi
  validate_loaded_runtime_values
}

stop_mode_services() {
  stop_legacy_service_for_cutover
}

install_staged_configurations() {
  release_legacy_nginx_listeners

  if mode_has_cloudflare; then
    install -d -m 755 "${ACME_WEBROOT:-/var/www/v2ray-onekey}"
    install_nginx_config_atomically "$STAGED_NGINX_INITIAL"
    activate_nginx_config
    request_certificate
    install_nginx_config_atomically "$STAGED_NGINX_FINAL"
    nginx -t
    run_service_mutation nginx reload
    create_renewal_hook "$RENEWAL_HOOK"
  fi

  install_validated_xray_config "$STAGED_XRAY"
  if mode_has_hysteria; then
    ensure_hysteria_account
    install_validated_hysteria_binary "$STAGED_HYSTERIA_BINARY"
    install_hysteria_runtime_files "$STAGED_HYSTERIA_CONFIG" "$STAGED_HYSTERIA_ACL" \
      "$STAGED_HYSTERIA_CERT" "$STAGED_HYSTERIA_KEY" "$STAGED_HYSTERIA_UNIT"
    write_hysteria_ownership_manifest
  fi
}

start_mode_services() {
  systemctl daemon-reload
  if mode_has_hysteria; then
    verify_hysteria_service_definition
  fi
  run_service_mutation xray enable --now
  run_service_mutation xray restart
  if mode_has_hysteria; then
    run_service_mutation hysteria-server enable --now
    run_service_mutation hysteria-server restart
  fi
}

verify_mode_services() {
  verify_started_services
  if mode_has_hysteria; then
    verify_hysteria_runtime_identity
  elif hysteria_deployment_is_strictly_project_owned; then
    run_service_mutation hysteria-server disable --now
  fi
  disable_legacy_v2ray_after_success
}

verify_cloudflare_when_enabled() {
  mode_has_cloudflare && check_cloudflare_edge
  return 0
}

deploy_services() {
  local preflight_complete="${1:-0}"
  [[ "$preflight_complete" == "0" || "$preflight_complete" == "1" ]] ||
    die "Invalid deployment preflight state"
  if [[ "$preflight_complete" == "0" ]]; then
    prepare_fresh_inputs
  fi
  begin_transaction
  install_mode_dependencies
  generate_mode_credentials
  stage_mode_configurations
  validate_staged_configurations
  stop_mode_services
  install_staged_configurations
  start_mode_services
  verify_mode_services
  save_state
  configure_firewall
  verify_cloudflare_when_enabled
  print_deployment_summary
  complete_transaction
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
  cleanup_runtime_directory
  release_deployment_lock
  TRANSACTION_ACTIVE="0"
  trap - EXIT ERR INT TERM
}

upgrade_usage() {
  cat <<'USAGE'
Usage:
  sudo bash v2ray-onekey-upgrade-cf.sh [options]

Options:
  --hy2-port-range START-END
  --ss-port PORT
  --server-address ADDRESS
  --rotate
  --allow-bittorrent
  --allow-mail
  -h, --help

This installer reads the existing project-managed Cloudflare deployment.
Domain, email, Cloudflare port, WebSocket path, and mode cannot be overridden.
USAGE
}

parse_upgrade_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hy2-port-range)
        [[ $# -ge 2 && -n "$2" ]] || die "--hy2-port-range requires a value"
        HY2_PORT_RANGE="$2"; CLI_HY2_PORT_RANGE_SET="1"; shift 2 ;;
      --ss-port)
        [[ $# -ge 2 && -n "$2" ]] || die "--ss-port requires a value"
        SS_PORT="$2"; CLI_SS_PORT_SET="1"; shift 2 ;;
      --server-address)
        [[ $# -ge 2 && -n "$2" ]] || die "--server-address requires a value"
        SERVER_ADDRESS="$2"; CLI_SERVER_ADDRESS_SET="1"; shift 2 ;;
      --rotate) ROTATE="1"; shift ;;
      --allow-bittorrent) ALLOW_BITTORRENT="1"; CLI_ALLOW_BITTORRENT_SET="1"; shift ;;
      --allow-mail) ALLOW_MAIL="1"; CLI_ALLOW_MAIL_SET="1"; shift ;;
      --mode|--domain|--email|--cloudflare-port|--cloudflare-uuid|--ws-path|--rotate-cloudflare)
        die "$1 is not accepted by the Cloudflare upgrade installer; this value is read from the existing managed deployment" ;;
      -h|--help) upgrade_usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

upgrade_managed_file_is_safe() {
  local path="$1" owner mode
  [[ -f "$path" && ! -L "$path" ]] || return 1
  owner="$(stat -c '%u' "$path" 2>/dev/null)" || return 1
  mode="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
  [[ "$owner" == "0" ]] || return 1
  (( (8#$mode & 0077) == 0 ))
}

upgrade_certificate_is_safe() {
  local path="$1" owner mode
  [[ -f "$path" ]] || return 1
  owner="$(stat -c '%u' "$path" 2>/dev/null)" || return 1
  mode="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
  [[ "$owner" == "0" ]] || return 1
  (( (8#$mode & 0077) == 0 ))
}

inspect_existing_cloudflare_xray() {
  python3 - "$XRAY_CONFIG" "$CLOUDFLARE_UUID" "$WS_PATH" "$INTERNAL_WS_PORT" <<'PY'
import json
import sys

path, wanted_uuid, wanted_path, wanted_port = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        config = json.load(handle)
except (OSError, ValueError):
    raise SystemExit("Unable to parse the existing Xray configuration")

matches = []
for inbound in config.get("inbounds", []):
    stream = inbound.get("streamSettings", {})
    if (inbound.get("protocol") == "vless" and
        inbound.get("listen") in ("127.0.0.1", "::1") and
        stream.get("network") == "ws" and
        stream.get("security") == "none"):
        matches.append(inbound)
if len(matches) != 1:
    raise SystemExit("Existing Xray configuration must contain exactly one project Cloudflare WebSocket inbound")
inbound = matches[0]
clients = inbound.get("settings", {}).get("clients", [])
paths = stream.get("wsSettings", {}).get("path")
if (str(inbound.get("port")) != wanted_port or paths != wanted_path or
    len(clients) != 1 or clients[0].get("id") != wanted_uuid):
    raise SystemExit("Existing Xray Cloudflare UUID, path, or internal port does not match managed state")
PY
}

inspect_existing_cloudflare() {
  local cert_dir
  MODE="full"
  load_state
  [[ "$MODE" == "full" || "$MODE" == "cloudflare" ]] ||
    die "The existing state is not a Cloudflare deployment"
  mode_has_cloudflare || die "The existing state has no Cloudflare entry"
  MODE="full"
  upgrade_managed_file_is_safe "$STATE_FILE" || die "State file ownership or permissions are unsafe"
  upgrade_managed_file_is_safe "$XRAY_CONFIG" || die "Xray config ownership or permissions are unsafe"
  upgrade_managed_file_is_safe "$NGINX_SITE" || die "Project Nginx config is missing or unsafe"
  current_nginx_config_is_project_owned "$NGINX_SITE" ||
    die "Existing Nginx config is not owned by v2ray-onekey"
  upgrade_managed_file_is_safe "$RENEWAL_HOOK" || die "Project renewal hook is missing or unsafe"
  current_renewal_hook_is_project_owned "$RENEWAL_HOOK" || die "Renewal hook ownership check failed"
  grep -Eq "^[[:space:]]*server_name[[:space:]]+$DOMAIN;" "$NGINX_SITE" ||
    die "Nginx server_name does not match managed state"
  grep -Fq "location $WS_PATH" "$NGINX_SITE" || die "Nginx WebSocket path does not match managed state"
  grep -Fq "proxy_pass http://127.0.0.1:$INTERNAL_WS_PORT;" "$NGINX_SITE" ||
    die "Nginx upstream does not match managed state"
  cert_dir="$LETSENCRYPT_LIVE_ROOT/$DOMAIN"
  upgrade_certificate_is_safe "$cert_dir/fullchain.pem" || die "Managed certificate is missing or unsafe"
  upgrade_certificate_is_safe "$cert_dir/privkey.pem" || die "Managed private key is missing or unsafe"
  "$XRAY_BIN" run -test -config "$XRAY_CONFIG" || die "Existing Xray config test failed"
  nginx -t || die "Existing Nginx config test failed"
  systemctl is-active --quiet xray || die "Existing Xray service is not active"
  systemctl is-active --quiet nginx || die "Existing Nginx service is not active"
  inspect_existing_cloudflare_xray
  PRESERVED_DOMAIN="$DOMAIN"
  PRESERVED_EMAIL="$EMAIL"
  PRESERVED_CLOUDFLARE_PORT="$CLOUDFLARE_PORT"
  PRESERVED_CLOUDFLARE_UUID="$CLOUDFLARE_UUID"
  PRESERVED_WS_PATH="$WS_PATH"
  PRESERVED_INTERNAL_WS_PORT="$INTERNAL_WS_PORT"
  PRESERVED_NGINX_SHA256="$(sha256sum "$NGINX_SITE" | awk '{print $1}')"
  PRESERVED_HOOK_SHA256="$(sha256sum "$RENEWAL_HOOK" | awk '{print $1}')"
  PRESERVED_CLOUDFLARE_LINK="$(make_cloudflare_link)"
}

assert_preserved_cloudflare_values() {
  [[ "$DOMAIN" == "$PRESERVED_DOMAIN" && "$EMAIL" == "$PRESERVED_EMAIL" &&
    "$CLOUDFLARE_PORT" == "$PRESERVED_CLOUDFLARE_PORT" &&
    "$CLOUDFLARE_UUID" == "$PRESERVED_CLOUDFLARE_UUID" &&
    "$WS_PATH" == "$PRESERVED_WS_PATH" &&
    "$INTERNAL_WS_PORT" == "$PRESERVED_INTERNAL_WS_PORT" ]] ||
    die "Cloudflare values changed during upgrade"
  [[ "$(sha256sum "$NGINX_SITE" | awk '{print $1}')" == "$PRESERVED_NGINX_SHA256" ]] ||
    die "Cloudflare Nginx config changed during upgrade"
  [[ "$(sha256sum "$RENEWAL_HOOK" | awk '{print $1}')" == "$PRESERVED_HOOK_SHA256" ]] ||
    die "Cloudflare renewal hook changed during upgrade"
  [[ "$(make_cloudflare_link)" == "$PRESERVED_CLOUDFLARE_LINK" ]] ||
    die "Cloudflare sharing link changed during upgrade"
}

prepare_upgrade_inputs() {
  validate_options state
  [[ "$CLI_ALLOW_BITTORRENT_SET" != "1" ]] || ALLOW_BITTORRENT="1"
  [[ "$CLI_ALLOW_MAIL_SET" != "1" ]] || ALLOW_MAIL="1"
  [[ "$CLI_HY2_PORT_RANGE_SET" != "1" ]] || {
    valid_hy2_port_range "$HY2_PORT_RANGE" || die "Invalid Hysteria2 port range: $HY2_PORT_RANGE"
  }
  [[ "$CLI_SS_PORT_SET" != "1" ]] || {
    valid_port "$SS_PORT" || die "Invalid Shadowsocks port: $SS_PORT"
  }
  if [[ -z "$SERVER_ADDRESS" ]]; then
    SERVER_ADDRESS="$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  fi
  valid_server_address "$SERVER_ADDRESS" ||
    die "A valid --server-address is required when the existing state has no direct server address"
  resolve_direct_port_conflicts
  assert_preserved_cloudflare_values
}

rotate_upgrade_direct_values() {
  [[ "$ROTATE" == "1" ]] || return 0
  HY2_AUTH=""
  HY2_OBFS_PASSWORD=""
  HY2_SNI=""
  HY2_CERT_PIN=""
  SS_KEY=""
}

install_upgrade_dependencies() {
  local -a packages=(curl ca-certificates openssl python3 coreutils gawk)
  if [[ "$PKG_MANAGER" == "apt" ]]; then packages+=(iproute2); else packages+=(iproute); fi
  install_packages "${packages[@]}"
  run_guarded_service_action xray install_xray_core
}

stage_upgrade_configurations() {
  prepare_runtime_directory
  rotate_upgrade_direct_values
  generate_runtime_values
  validate_loaded_runtime_values
  STAGED_XRAY="$RUNTIME_DIR/xray-config.json"
  render_xray_config "$STAGED_XRAY"
  STAGED_HYSTERIA_BINARY="$RUNTIME_DIR/hysteria"
  STAGED_HYSTERIA_CONFIG="$RUNTIME_DIR/hysteria-config.yaml"
  STAGED_HYSTERIA_ACL="$RUNTIME_DIR/hysteria-acl.txt"
  STAGED_HYSTERIA_CERT="$RUNTIME_DIR/hysteria-server.crt"
  STAGED_HYSTERIA_KEY="$RUNTIME_DIR/hysteria-server.key"
  STAGED_HYSTERIA_UNIT="$RUNTIME_DIR/hysteria-server.service"
  STAGED_HYSTERIA_SMOKE_CONFIG="$RUNTIME_DIR/hysteria-smoke.yaml"
  STAGED_HYSTERIA_SMOKE_LOG="$RUNTIME_DIR/hysteria-smoke.log"
  stage_hysteria_bundle "$STAGED_HYSTERIA_BINARY" "$STAGED_HYSTERIA_CONFIG" \
    "$STAGED_HYSTERIA_ACL" "$STAGED_HYSTERIA_CERT" "$STAGED_HYSTERIA_KEY" \
    "$STAGED_HYSTERIA_UNIT" "$STAGED_HYSTERIA_SMOKE_CONFIG" "$STAGED_HYSTERIA_SMOKE_LOG"
}

validate_upgrade_staged_configurations() {
  "$XRAY_BIN" run -test -config "$STAGED_XRAY" || die "Staged Xray config test failed"
  validate_loaded_runtime_values
  [[ "$(grep -Eic 'REALITY|X25519|SHORT_ID|REALITY_TARGET' "$STAGED_XRAY" || true)" == "0" ]] ||
    die "Staged Xray config still contains retired REALITY state"
}

install_upgrade_staged_configurations() {
  install_validated_xray_config "$STAGED_XRAY"
  ensure_hysteria_account
  install_validated_hysteria_binary "$STAGED_HYSTERIA_BINARY"
  install_hysteria_runtime_files "$STAGED_HYSTERIA_CONFIG" "$STAGED_HYSTERIA_ACL" \
    "$STAGED_HYSTERIA_CERT" "$STAGED_HYSTERIA_KEY" "$STAGED_HYSTERIA_UNIT"
  write_hysteria_ownership_manifest
}

deploy_upgrade_cf() {
  inspect_existing_cloudflare
  prepare_upgrade_inputs
  acquire_deployment_lock
  begin_transaction
  install_upgrade_dependencies
  stage_upgrade_configurations
  validate_upgrade_staged_configurations
  stop_mode_services
  install_upgrade_staged_configurations
  start_mode_services
  verify_mode_services
  assert_preserved_cloudflare_values
  save_state
  ! grep -Eiq 'REALITY|X25519|SHORT_ID|REALITY_TARGET' "$STATE_FILE" ||
    die "Saved state contains retired REALITY fields"
  configure_firewall
  check_cloudflare_edge
  print_deployment_summary
  complete_transaction
}

main_upgrade_cf() {
  set -Eeuo pipefail
  reset_options
  MODE="full"
  parse_upgrade_args "$@"
  [[ "$(id -u)" -eq 0 ]] || die "Please run as root: sudo bash v2ray-onekey-upgrade-cf.sh"
  preflight_environment
  deploy_upgrade_cf
}

make_cloudflare_link() {
  unexport_sensitive_runtime_values
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%s#%s\n' \
    "$CLOUDFLARE_UUID" "$DOMAIN" "$CLOUDFLARE_PORT" \
    "$(urlencode "$DOMAIN")" "$(urlencode "$DOMAIN")" \
    "$(urlencode "$WS_PATH")" "$(urlencode "VLESS-Cloudflare-fallback")"
}

make_shadowsocks_link() {
  local authority
  unexport_sensitive_runtime_values
  authority="$(printf '%s' "$SS_METHOD:$SS_KEY" | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
  printf 'ss://%s@%s:%s#%s\n' "$authority" "$(format_uri_host "$SERVER_ADDRESS")" \
    "$SS_PORT" "$(urlencode 'Shadowsocks-2022-direct')"
}

make_hysteria_link() {
  local link_status="0"
  unexport_sensitive_runtime_values
  if ! valid_server_address "$SERVER_ADDRESS" ||
    ! valid_hy2_port_range "$HY2_PORT_RANGE" ||
    ! valid_hy2_secret "$HY2_AUTH" ||
    ! valid_hy2_secret "$HY2_OBFS_PASSWORD" ||
    ! valid_hy2_sni "$HY2_SNI" ||
    ! valid_hy2_cert_pin "$HY2_CERT_PIN"; then
    die "Invalid Hysteria2 link values"
  fi
  printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$HY2_AUTH" "$SERVER_ADDRESS" "$HY2_PORT_RANGE" \
    "$HY2_OBFS_PASSWORD" "$HY2_SNI" "$HY2_CERT_PIN" |
    python3 - 3<&0 <<'PY' || link_status=$?
import ipaddress
import os
import re
import urllib.parse


records = os.fdopen(3, "rb").read().decode("utf-8").split("\0")
if records[-1] != "" or len(records) != 7:
    raise SystemExit("invalid Hysteria2 URI input")
auth, address, port_range, obfs_password, sni, pin = records[:-1]
if not re.fullmatch(r"[A-Za-z0-9_-]{43}", auth):
    raise SystemExit("invalid auth")
if not re.fullmatch(r"[A-Za-z0-9_-]{43}", obfs_password):
    raise SystemExit("invalid obfuscation password")
if not re.fullmatch(r"[0-9a-f]{16}\.invalid", sni):
    raise SystemExit("invalid SNI")
if not re.fullmatch(r"(?:[0-9A-F]{2}:){31}[0-9A-F]{2}", pin):
    raise SystemExit("invalid certificate pin")
if not re.fullmatch(r"[1-9][0-9]{0,4}-[1-9][0-9]{0,4}", port_range):
    raise SystemExit("invalid port range")
start, end = (int(value) for value in port_range.split("-", 1))
if not (1 <= start <= end <= 65535 and end - start <= 1000):
    raise SystemExit("invalid port range")
try:
    parsed_address = ipaddress.ip_address(address)
except ValueError:
    host = address.lower()
else:
    host = "[{}]".format(parsed_address) if parsed_address.version == 6 else str(parsed_address)

quote = lambda value: urllib.parse.quote(value, safe="")
query = urllib.parse.urlencode(
    [
        ("obfs", "salamander"),
        ("obfs-password", obfs_password),
        ("sni", sni),
        ("insecure", "1"),
        ("pinSHA256", pin),
    ],
    quote_via=urllib.parse.quote,
)
link = "hysteria2://{}@{}:{}/?{}#{}".format(
    quote(auth), host, port_range, query, quote("Hysteria2-direct")
)
parsed = urllib.parse.urlsplit(link)
if parsed.scheme != "hysteria2" or parsed.hostname != host.strip("[]"):
    raise SystemExit("URI validation failed")
if not parsed.netloc.endswith(":" + port_range):
    raise SystemExit("URI port range validation failed")
parsed_query = urllib.parse.parse_qs(parsed.query, strict_parsing=True)
if parsed_query.get("obfs") != ["salamander"]:
    raise SystemExit("URI query validation failed")
print(link)
PY
  (( link_status == 0 )) || die "Unable to validate the Hysteria2 sharing link"
}

main() {
  set -Eeuo pipefail
  reset_options
  parse_args "$@"
  [[ "$(id -u)" -eq 0 ]] || die "Please run as root: sudo bash v2ray-onekey.sh"
  prepare_configuration
  preflight_environment
  prepare_fresh_inputs
  activate_transaction_traps
  acquire_deployment_lock
  deploy_services 1
}

if [[ "${V2RAY_ONEKEY_SOURCE_ONLY:-0}" != "1" ]]; then
  case "$INSTALLER_VARIANT" in
    new) main "$@" ;;
    upgrade-cf) main_upgrade_cf "$@" ;;
    *) die "Unknown installer variant: $INSTALLER_VARIANT" ;;
  esac
fi
