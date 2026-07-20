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

printf 'PASS: existing Cloudflare upgrade installer tests\n'
