#!/usr/bin/env bash
set -Eeuo pipefail

# One-key V2Ray server installer.
# Default mode: VMess over TCP, works without a domain name.
# Optional mode: VMess over WebSocket + TLS behind Nginx, requires a domain.

APP_NAME="v2ray-onekey"
V2RAY_CONFIG="/usr/local/etc/v2ray/config.json"
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh"
DEFAULT_WS_PATH="/ray"
DOMAIN=""
EMAIL=""
PORT=""
UUID=""
WS_PATH="$DEFAULT_WS_PATH"
FORCE_TCP="0"

log() { printf '\033[1;32m[%s]\033[0m %s\n' "$APP_NAME" "$*"; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$APP_NAME" "$*"; }
die() { printf '\033[1;31m[%s]\033[0m %s\n' "$APP_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  sudo bash v2ray-onekey.sh [options]

Default, no-domain mode:
  sudo bash v2ray-onekey.sh
  sudo bash v2ray-onekey.sh --port 23456

Optional domain mode:
  sudo bash v2ray-onekey.sh --domain vpn.example.com --email you@example.com
  sudo bash v2ray-onekey.sh --domain vpn.example.com --email you@example.com --ws-path /ray

Options:
  --domain DOMAIN       Enable WebSocket + TLS mode. Domain must already point to this server.
  --email EMAIL         Email used by Let's Encrypt. Required with --domain.
  --port PORT           V2Ray listening port. In TLS mode this is internal localhost port.
  --uuid UUID           Use a fixed VMess UUID instead of generating one.
  --ws-path PATH        WebSocket path for domain mode. Default: /ray
  --tcp                 Force plain VMess TCP mode even if --domain is omitted.
  -h, --help            Show this help.

Notes:
  - TCP mode exposes the selected V2Ray port directly.
  - Domain mode exposes HTTPS 443 through Nginx and proxies WebSocket traffic to V2Ray.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      DOMAIN="${2:-}"
      [[ -n "$DOMAIN" ]] || die "--domain requires a value"
      shift 2
      ;;
    --email)
      EMAIL="${2:-}"
      [[ -n "$EMAIL" ]] || die "--email requires a value"
      shift 2
      ;;
    --port)
      PORT="${2:-}"
      [[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be a number"
      shift 2
      ;;
    --uuid)
      UUID="${2:-}"
      [[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "--uuid must be a valid UUID"
      shift 2
      ;;
    --ws-path)
      WS_PATH="${2:-}"
      [[ "$WS_PATH" == /* ]] || die "--ws-path must start with /"
      shift 2
      ;;
    --tcp)
      FORCE_TCP="1"
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

[[ "$(id -u)" -eq 0 ]] || die "Please run as root: sudo bash v2ray-onekey.sh"
[[ -z "$DOMAIN" || -n "$EMAIL" ]] || die "--email is required when --domain is used"

if [[ -n "$DOMAIN" && "$FORCE_TCP" == "1" ]]; then
  warn "--tcp was supplied with --domain; using TCP mode and ignoring domain settings."
  DOMAIN=""
fi

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

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1])[1:-1])' "$1"
}

b64_one_line() {
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w 0
  else
    base64 | tr -d '\n'
  fi
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

write_tcp_config() {
  install -d -m 755 "$(dirname "$V2RAY_CONFIG")"
  cat > "$V2RAY_CONFIG" <<EOF
{
  "log": {
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "listen": "0.0.0.0",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "tcp"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF
}

write_ws_config() {
  install -d -m 755 "$(dirname "$V2RAY_CONFIG")"
  cat > "$V2RAY_CONFIG" <<EOF
{
  "log": {
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$WS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF
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

make_vmess_link() {
  local add host net tls path ps json
  if [[ -n "$DOMAIN" ]]; then
    add="$DOMAIN"
    host="$DOMAIN"
    net="ws"
    tls="tls"
    path="$WS_PATH"
    ps="v2ray-${DOMAIN}-tls"
    json=$(cat <<EOF
{"v":"2","ps":"$(json_escape "$ps")","add":"$(json_escape "$add")","port":"443","id":"$UUID","aid":"0","scy":"auto","net":"$net","type":"none","host":"$(json_escape "$host")","path":"$(json_escape "$path")","tls":"$tls","sni":"$(json_escape "$DOMAIN")"}
EOF
)
  else
    add="$(public_ip)"
    host=""
    net="tcp"
    tls=""
    path=""
    ps="v2ray-${add:-server}-tcp"
    json=$(cat <<EOF
{"v":"2","ps":"$(json_escape "$ps")","add":"$(json_escape "$add")","port":"$PORT","id":"$UUID","aid":"0","scy":"auto","net":"$net","type":"none","host":"$host","path":"$path","tls":"$tls"}
EOF
)
  fi

  printf 'vmess://%s\n' "$(printf '%s' "$json" | b64_one_line)"
}

print_result() {
  local server_addr mode link
  link="$(make_vmess_link)"

  if [[ -n "$DOMAIN" ]]; then
    mode="VMess + WebSocket + TLS"
    server_addr="$DOMAIN"
    cat <<EOF

================ V2Ray deployed ================
Mode:     $mode
Address:  $server_addr
Port:     443
UUID:     $UUID
Network:  ws
Path:     $WS_PATH
TLS:      enabled

Client import link:
$link

Useful commands:
  systemctl status v2ray --no-pager
  journalctl -u v2ray -e --no-pager
  nginx -t
=================================================
EOF
  else
    mode="VMess TCP"
    server_addr="$(public_ip)"
    cat <<EOF

================ V2Ray deployed ================
Mode:     $mode
Address:  $server_addr
Port:     $PORT
UUID:     $UUID
Network:  tcp
TLS:      none

Client import link:
$link

Useful commands:
  systemctl status v2ray --no-pager
  journalctl -u v2ray -e --no-pager
=================================================
EOF
  fi
}

main() {
  detect_pkg_manager
  install_packages curl ca-certificates python3 coreutils

  [[ -n "$PORT" ]] || PORT="$(random_port)"
  (( PORT >= 1 && PORT <= 65535 )) || die "Port must be between 1 and 65535"
  [[ -n "$UUID" ]] || UUID="$(generate_uuid)"

  install_v2ray

  if [[ -n "$DOMAIN" ]]; then
    write_ws_config
    configure_nginx_tls
    open_firewall_port 80 tcp
    open_firewall_port 443 tcp
  else
    write_tcp_config
    open_firewall_port "$PORT" tcp
  fi

  restart_v2ray
  print_result
}

main "$@"
