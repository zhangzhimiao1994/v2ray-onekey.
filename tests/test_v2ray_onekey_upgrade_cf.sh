#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT="$ROOT_DIR/outputs/v2ray-onekey-upgrade-cf.sh"

"$ROOT_DIR/tools/build-installers.sh"
[[ -x "$ARTIFACT" ]]
bash -n "$ARTIFACT"

V2RAY_ONEKEY_SOURCE_ONLY=1 source "$ARTIFACT"

reset_options
MODE="full"
parse_upgrade_args --hy2-port-range 21000-21100 --ss-port 8488 --server-address 203.0.113.10 \
  --rotate --allow-bittorrent --allow-mail
[[ "$HY2_PORT_RANGE" == "21000-21100" ]]
[[ "$SS_PORT" == "8488" ]]
[[ "$SERVER_ADDRESS" == "203.0.113.10" ]]
[[ "$ROTATE" == "1" && "$ALLOW_BITTORRENT" == "1" && "$ALLOW_MAIL" == "1" ]]

for forbidden in '--mode full' '--domain vpn.example.com' '--email admin@example.com' \
  '--cloudflare-port 8443' '--ws-path /old' '--rotate-cloudflare'; do
  set +e
  output="$( (parse_upgrade_args "$forbidden") 2>&1 )"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || { printf 'accepted forbidden option: %s\n' "$forbidden" >&2; exit 1; }
done

grep -Fq 'inspect_existing_cloudflare' "$ARTIFACT"
grep -Fq 'install_upgrade_staged_configurations' "$ARTIFACT"
grep -Fq 'Existing Xray Cloudflare UUID, path, or internal port' "$ARTIFACT"
if grep -Eiq 'security[=:]reality|xtls-rprx-vision|"tag"[[:space:]]*:[[:space:]]*"reality-in"' "$ARTIFACT"; then
  printf 'active upgrade artifact contains retired REALITY implementation\n' >&2
  exit 1
fi

permission_root="$(mktemp -d)"
trap 'rm -rf -- "$permission_root"' EXIT
managed_config="$permission_root/config.json"
printf '{}\n' >"$managed_config"
chmod 0644 "$managed_config"
upgrade_managed_file_is_safe "$managed_config" || {
  printf 'root-owned 0644 managed config was rejected\n' >&2
  exit 1
}
chmod 0664 "$managed_config"
if upgrade_managed_file_is_safe "$managed_config"; then
  printf 'group-writable managed config was accepted\n' >&2
  exit 1
fi

legacy_xray_config="$permission_root/legacy-xray.json"
printf '{}\n' >"$legacy_xray_config"
chown nobody:nogroup "$legacy_xray_config"
chmod 0400 "$legacy_xray_config"
xray_service_identity() { printf 'nobody:nogroup\n'; }
upgrade_xray_config_is_safe "$legacy_xray_config" || {
  printf 'legacy service-owned 0400 Xray config was rejected\n' >&2
  exit 1
}
chmod 0600 "$legacy_xray_config"
if upgrade_xray_config_is_safe "$legacy_xray_config"; then
  printf 'legacy service-owned writable Xray config was accepted\n' >&2
  exit 1
fi

printf '{}\n' >"$permission_root/staged-xray.json"
XRAY_CONFIG="$permission_root/installed-xray.json"
install_validated_xray_config "$permission_root/staged-xray.json"
[[ "$(stat -c '%U:%G:%a' "$XRAY_CONFIG")" == "root:nogroup:440" ]] || {
  printf 'installed Xray config did not use root-owned group-readable permissions\n' >&2
  exit 1
}

NGINX_SITE="$permission_root/v2ray-onekey.conf"
WS_PATH="/legacy-ws-path"
printf '    location = %s {\n' "$WS_PATH" >"$NGINX_SITE"
upgrade_nginx_path_matches || {
  printf 'legacy managed Nginx exact-match WebSocket path was rejected\n' >&2
  exit 1
}
printf '    location = /different-path {\n' >"$NGINX_SITE"
if upgrade_nginx_path_matches; then
  printf 'different Nginx WebSocket path was accepted\n' >&2
  exit 1
fi

DOMAIN="vpn.example.com"
LETSENCRYPT_LIVE_ROOT="$permission_root/letsencrypt/live"
archive_dir="$permission_root/letsencrypt/archive/$DOMAIN"
live_dir="$LETSENCRYPT_LIVE_ROOT/$DOMAIN"
mkdir -p "$archive_dir" "$live_dir"
printf 'certificate\n' >"$archive_dir/fullchain1.pem"
chmod 0644 "$archive_dir/fullchain1.pem"
ln -s "../../archive/$DOMAIN/fullchain1.pem" "$live_dir/fullchain.pem"
upgrade_certificate_is_safe "$live_dir/fullchain.pem" || {
  printf 'standard Certbot live certificate symlink was rejected\n' >&2
  exit 1
}
printf 'external\n' >"$permission_root/external.pem"
ln -sfn "$permission_root/external.pem" "$live_dir/fullchain.pem"
if upgrade_certificate_is_safe "$live_dir/fullchain.pem"; then
  printf 'certificate symlink escaping the Certbot archive was accepted\n' >&2
  exit 1
fi

printf 'PASS: existing Cloudflare upgrade installer tests\n'
