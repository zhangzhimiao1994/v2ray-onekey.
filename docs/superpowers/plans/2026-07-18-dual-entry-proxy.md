# Dual-Entry Proxy Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the plain VMess installer with a self-contained Xray installer offering direct VLESS/REALITY, Cloudflare VLESS/WebSocket/TLS, or both.

**Architecture:** Keep the distributable as one Bash script so users can download and run it directly. Separate pure rendering and validation functions from privileged installation functions, which allows a dependency-free Bash test harness to source the script safely. Xray owns the proxy inbounds, while Nginx and Certbot are installed only for the optional Cloudflare path.

**Tech Stack:** Bash 4+, Xray-core, Nginx, Certbot, Python 3 standard library, systemd, UFW/firewalld, Docker-based Bash and ShellCheck verification.

---

## File Map

- Modify `outputs/v2ray-onekey.sh`: argument parsing, interactive menu, state, Xray configuration, Nginx/ACME setup, migration, rollback, firewall, and import links.
- Create `tests/test_v2ray_onekey.sh`: source-level tests for mode selection, validation, configuration rendering, state reuse, and URI generation.
- Modify `README.md`: installation modes, Cloudflare prerequisites, client import, diagnostics, and limitations.
- Keep `docs/superpowers/specs/2026-07-18-dual-entry-proxy-design.md` unchanged as the approved behavior contract.

### Task 1: Make the Installer Safely Sourceable

**Files:**
- Create: `tests/test_v2ray_onekey.sh`
- Modify: `outputs/v2ray-onekey.sh`

- [ ] **Step 1: Write a failing source-guard test**

Create `tests/test_v2ray_onekey.sh` with this initial content:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/outputs/v2ray-onekey.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -Fq 'V2RAY_ONEKEY_SOURCE_ONLY' "$SCRIPT" || fail "source-only guard is missing"
printf 'PASS: source-only guard exists\n'
```

- [ ] **Step 2: Run the test and confirm the expected failure**

Run:

```powershell
docker run --rm -v "${PWD}:/work" -w /work bash:5.2 bash tests/test_v2ray_onekey.sh
```

Expected: exit 1 with `FAIL: source-only guard is missing`.

- [ ] **Step 3: Add the source-only guard**

Replace the unconditional final call in `outputs/v2ray-onekey.sh` with:

```bash
if [[ "${V2RAY_ONEKEY_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Run the test and Bash syntax check**

Run:

```powershell
docker run --rm -v "${PWD}:/work" -w /work bash:5.2 bash tests/test_v2ray_onekey.sh
docker run --rm -v "${PWD}:/work" -w /work bash:5.2 bash -n outputs/v2ray-onekey.sh
```

Expected: both commands exit 0.

- [ ] **Step 5: Commit the source guard and test harness**

```bash
git add outputs/v2ray-onekey.sh tests/test_v2ray_onekey.sh
git commit -m "test: add installer shell harness"
```

### Task 2: Add Modes, Menu, Arguments, and Validation

**Files:**
- Modify: `tests/test_v2ray_onekey.sh`
- Modify: `outputs/v2ray-onekey.sh`

- [ ] **Step 1: Add failing tests for the three modes**

Replace the final `printf` in `tests/test_v2ray_onekey.sh` with the following test body:

```bash
export V2RAY_ONEKEY_SOURCE_ONLY=1
# shellcheck source=../outputs/v2ray-onekey.sh
source "$SCRIPT"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "$actual" == "$expected" ]] || fail "$message: expected '$expected', got '$actual'"
}

reset_options
MODE="reality"
resolve_default_ports
assert_eq "443" "$REALITY_PORT" "reality port"
assert_eq "" "$CLOUDFLARE_PORT" "reality cloudflare port"
mode_needs_domain && fail "reality mode must not require a domain"

reset_options
MODE="cloudflare"
resolve_default_ports
assert_eq "" "$REALITY_PORT" "cloudflare reality port"
assert_eq "443" "$CLOUDFLARE_PORT" "cloudflare port"
mode_needs_domain || fail "cloudflare mode must require a domain"

reset_options
MODE="dual"
resolve_default_ports
assert_eq "443" "$REALITY_PORT" "dual reality port"
assert_eq "8443" "$CLOUDFLARE_PORT" "dual cloudflare port"
mode_needs_domain || fail "dual mode must require a domain"

reset_options
choose_mode <<<"3" >/dev/null
assert_eq "dual" "$MODE" "menu choice 3"

valid_domain "vpn.example.com" || fail "valid domain rejected"
valid_domain "bad_domain" && fail "invalid domain accepted"
valid_port "65535" || fail "valid port rejected"
valid_port "65536" && fail "invalid port accepted"

printf 'PASS: mode and validation tests\n'
```

- [ ] **Step 2: Run the test and confirm functions are missing**

Run:

```powershell
docker run --rm -v "${PWD}:/work" -w /work bash:5.2 bash tests/test_v2ray_onekey.sh
```

Expected: exit 1 because `reset_options` is not defined.

- [ ] **Step 3: Replace the old VMess option model with the new mode model**

Add these globals and pure functions near the top of `outputs/v2ray-onekey.sh`, removing the old `FORCE_TCP` and VMess-only defaults:

```bash
APP_NAME="v2ray-onekey"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
STATE_FILE="${STATE_FILE:-/etc/v2ray-onekey/state.env}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/v2ray-onekey}"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
DEFAULT_REALITY_TARGET="www.microsoft.com:443"

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

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
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
```

Implement `usage` and `parse_args` with these exact public options:

```text
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
```

After parsing, call `choose_mode` only when `MODE` is empty and stdin is a terminal. In non-interactive execution with no `--mode`, fail with a command example. Require `DOMAIN` and `EMAIL` only when `mode_needs_domain` succeeds. Validate both resolved public ports and reject equal ports in dual mode.

- [ ] **Step 4: Run mode tests and syntax validation**

Run:

```powershell
docker run --rm -v "${PWD}:/work" -w /work bash:5.2 bash tests/test_v2ray_onekey.sh
docker run --rm -v "${PWD}:/work" -w /work bash:5.2 bash -n outputs/v2ray-onekey.sh
```

Expected: both commands exit 0 and tests print `PASS: mode and validation tests`.

- [ ] **Step 5: Commit mode handling**

```bash
git add outputs/v2ray-onekey.sh tests/test_v2ray_onekey.sh
git commit -m "feat: add direct and Cloudflare install modes"
```

### Task 3: Render Xray Configurations and Import Links

**Files:**
- Modify: `tests/test_v2ray_onekey.sh`
- Modify: `outputs/v2ray-onekey.sh`

- [ ] **Step 1: Add failing renderer tests**

Append this test function and call it before the final PASS line:

```bash
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

  render_xray_config "$temp_dir/config.json"
  python3 - "$temp_dir/config.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)

assert [item["tag"] for item in config["inbounds"]] == ["reality-in", "cloudflare-ws-in"]
reality, cloudflare = config["inbounds"]
assert reality["streamSettings"]["security"] == "reality"
assert reality["settings"]["clients"][0]["flow"] == "xtls-rprx-vision"
assert cloudflare["listen"] == "127.0.0.1"
assert cloudflare["streamSettings"]["network"] == "ws"
assert config["routing"]["rules"][0]["ip"] == ["geoip:private"]
assert config["routing"]["rules"][1]["protocol"] == ["bittorrent"]
assert all(item["protocol"] != "vmess" for item in config["inbounds"])
PY

  local reality_link cloudflare_link
  reality_link="$(make_reality_link "203.0.113.10")"
  cloudflare_link="$(make_cloudflare_link)"
  [[ "$reality_link" == vless://11111111-1111-4111-8111-111111111111@203.0.113.10:443* ]] || fail "bad REALITY URI"
  [[ "$reality_link" == *"security=reality"* ]] || fail "REALITY URI security missing"
  [[ "$reality_link" == *"flow=xtls-rprx-vision"* ]] || fail "REALITY URI flow missing"
  [[ "$reality_link" == *"pbk=public-key"* ]] || fail "REALITY URI public key missing"
  [[ "$cloudflare_link" == vless://22222222-2222-4222-8222-222222222222@vpn.example.com:8443* ]] || fail "bad Cloudflare URI"
  [[ "$cloudflare_link" == *"security=tls"*"type=ws"*"host=vpn.example.com"* ]] || fail "Cloudflare URI fields missing"
}

test_renderers
```

- [ ] **Step 2: Run tests and confirm `render_xray_config` is missing**

Run the Bash test container. Expected: exit 1 naming `render_xray_config`.

- [ ] **Step 3: Implement structured Xray JSON rendering**

Implement `render_xray_config OUTPUT_PATH` using a Python standard-library heredoc. Pass values as positional arguments instead of interpolating them into Python source. The generated object must have this exact shape:

```json
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "reality-in",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "REALITY_UUID", "flow": "xtls-rprx-vision", "email": "reality"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "www.microsoft.com:443",
          "serverNames": ["www.microsoft.com"],
          "privateKey": "PRIVATE_KEY",
          "shortIds": ["SHORT_ID"],
          "limitFallbackUpload": {"afterBytes": 1048576, "bytesPerSec": 102400, "burstBytesPerSec": 1048576},
          "limitFallbackDownload": {"afterBytes": 1048576, "bytesPerSec": 102400, "burstBytesPerSec": 1048576}
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
    },
    {
      "tag": "cloudflare-ws-in",
      "listen": "127.0.0.1",
      "port": 31001,
      "protocol": "vless",
      "settings": {"clients": [{"id": "CLOUDFLARE_UUID", "email": "cloudflare"}], "decryption": "none"},
      "streamSettings": {"network": "ws", "security": "none", "wsSettings": {"path": "/RANDOM_PATH"}},
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
    ]
  }
}
```

Build the `inbounds` array conditionally from `MODE`. Omit the BitTorrent rule when `ALLOW_BITTORRENT=1`. Derive the REALITY `serverNames` value by removing the port from `REALITY_TARGET`.

- [ ] **Step 4: Implement URI generation**

Add these helpers, using `urllib.parse.quote` for every query value and label:

```bash
urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

make_reality_link() {
  local address="$1"
  local server_name="${REALITY_TARGET%:*}"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s\n' \
    "$REALITY_UUID" "$address" "$REALITY_PORT" \
    "$(urlencode "$server_name")" "$(urlencode "$REALITY_PUBLIC_KEY")" \
    "$(urlencode "$REALITY_SHORT_ID")" "$(urlencode "VLESS-REALITY-direct")"
}

make_cloudflare_link() {
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%s#%s\n' \
    "$CLOUDFLARE_UUID" "$DOMAIN" "$CLOUDFLARE_PORT" \
    "$(urlencode "$DOMAIN")" "$(urlencode "$DOMAIN")" \
    "$(urlencode "$WS_PATH")" "$(urlencode "VLESS-Cloudflare-fallback")"
}
```

- [ ] **Step 5: Run renderer tests and validate JSON parsing**

Run:

```powershell
docker run --rm -v "${PWD}:/work" -w /work bash:5.2 bash tests/test_v2ray_onekey.sh
```

Expected: all tests pass.

- [ ] **Step 6: Commit renderers**

```bash
git add outputs/v2ray-onekey.sh tests/test_v2ray_onekey.sh
git commit -m "feat: render Xray modes and VLESS links"
```

### Task 4: Add Persistent State, Key Generation, and Preflight Checks

**Files:**
- Modify: `tests/test_v2ray_onekey.sh`
- Modify: `outputs/v2ray-onekey.sh`

- [ ] **Step 1: Add failing state-reuse tests**

Append this test and invoke it:

```bash
test_state_round_trip() {
  local temp_dir
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  reset_options
  STATE_FILE="$temp_dir/state.env"
  MODE="dual"
  DOMAIN="vpn.example.com"
  EMAIL="admin@example.com"
  REALITY_PORT="443"
  CLOUDFLARE_PORT="8443"
  INTERNAL_WS_PORT="31001"
  REALITY_UUID="11111111-1111-4111-8111-111111111111"
  CLOUDFLARE_UUID="22222222-2222-4222-8222-222222222222"
  REALITY_PRIVATE_KEY="private-key"
  REALITY_PUBLIC_KEY="public-key"
  REALITY_SHORT_ID="0123456789abcdef"
  REALITY_TARGET="www.microsoft.com:443"
  WS_PATH="/saved-path"
  save_state

  reset_options
  STATE_FILE="$temp_dir/state.env"
  load_state
  assert_eq "dual" "$MODE" "saved mode"
  assert_eq "/saved-path" "$WS_PATH" "saved WebSocket path"
  assert_eq "600" "$(stat -c '%a' "$STATE_FILE")" "state permissions"
}

test_state_round_trip
```

- [ ] **Step 2: Run tests and confirm `save_state` is missing**

Run the Bash test container. Expected: exit 1 naming `save_state`.

- [ ] **Step 3: Implement root-only state persistence**

Implement `save_state` using `install -d -m 700 "$(dirname "$STATE_FILE")"`, a temporary file in the same directory, and `printf '%q'` for each value. Persist exactly these keys: `MODE`, `DOMAIN`, `EMAIL`, `REALITY_PORT`, `CLOUDFLARE_PORT`, `INTERNAL_WS_PORT`, `REALITY_UUID`, `CLOUDFLARE_UUID`, `REALITY_PRIVATE_KEY`, `REALITY_PUBLIC_KEY`, `REALITY_SHORT_ID`, `REALITY_TARGET`, `WS_PATH`, and `ALLOW_BITTORRENT`. Install the completed file with mode 600 and atomically rename it over `STATE_FILE`.

Implement `load_state` only when the file is owned by root and not group/world-writable. In tests, allow the current test user when `V2RAY_ONEKEY_SOURCE_ONLY=1`. Source the shell-escaped assignments, then re-run domain, mode, and port validation.

- [ ] **Step 4: Implement generated credentials**

Add:

```bash
generate_runtime_values() {
  if mode_has_cloudflare; then
    [[ -n "$INTERNAL_WS_PORT" ]] || INTERNAL_WS_PORT="$(shuf -i 20000-50000 -n 1)"
    [[ -n "$CLOUDFLARE_UUID" ]] || CLOUDFLARE_UUID="$(xray uuid)"
    [[ -n "$WS_PATH" ]] || WS_PATH="/$(openssl rand -hex 12)"
  fi

  if mode_has_reality; then
    [[ -n "$REALITY_UUID" ]] || REALITY_UUID="$(xray uuid)"
    [[ -n "$REALITY_SHORT_ID" ]] || REALITY_SHORT_ID="$(openssl rand -hex 8)"
    if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
      local key_output
      key_output="$(xray x25519)"
      REALITY_PRIVATE_KEY="$(awk -F': ' '/Private key:/ {print $2}' <<<"$key_output")"
      REALITY_PUBLIC_KEY="$(awk -F': ' '/Password:/ {print $2}' <<<"$key_output")"
      [[ -n "$REALITY_PUBLIC_KEY" ]] || REALITY_PUBLIC_KEY="$(awk -F': ' '/Public key:/ {print $2}' <<<"$key_output")"
    fi
    [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die "Unable to parse xray x25519 output"
  fi
}
```

When `--rotate` is absent, load existing state before generation and keep saved credentials. When `--rotate` is present, retain the selected mode/domain/ports but clear both UUIDs, both REALITY keys, the short ID, and the WebSocket path before calling `generate_runtime_values`.

- [ ] **Step 5: Implement preflight checks**

Add checks for Linux, root, systemd, supported package manager, unique public ports, port availability, and domain proxy status. Download Cloudflare's current ranges from `https://www.cloudflare.com/ips-v4` and `https://www.cloudflare.com/ips-v6` into the run's temporary directory. Use Python `ipaddress.ip_address` and `ipaddress.ip_network` to determine whether at least one resolved domain address is in those ranges.

For the REALITY target:

```bash
validate_reality_target() {
  local host="${REALITY_TARGET%:*}"
  timeout 15 xray tls ping "$host" >/dev/null 2>&1 || die "REALITY target failed TLS probe: $host"
  target_resolves_to_cloudflare "$host" && die "REALITY target resolves to Cloudflare; use --reality-target with a non-Cloudflare HTTPS host"
}
```

Do not treat Xray or V2Ray as unrelated port users. For Nginx, treat a legacy file matching `/etc/nginx/conf.d/v2ray-*.conf` as project-owned only when it contains all three signatures from the previous installer: `proxy_set_header Upgrade`, `proxy_pass http://127.0.0.1:`, and `return 200 "ok`. Back up and temporarily disable those matched files before checking port 443. If `nginx -T` still shows an unrelated server listening on a port required by REALITY, fail and leave that site enabled. Print `ss -lntp` output for every unresolved conflict.

- [ ] **Step 6: Run tests and commit state/preflight work**

```powershell
docker run --rm -v "${PWD}:/work" -w /work bash:5.2 bash tests/test_v2ray_onekey.sh
```

Expected: all tests pass.

```bash
git add outputs/v2ray-onekey.sh tests/test_v2ray_onekey.sh
git commit -m "feat: persist credentials and validate endpoints"
```

### Task 5: Add Nginx, ACME, and Cloudflare Origin Configuration

**Files:**
- Modify: `tests/test_v2ray_onekey.sh`
- Modify: `outputs/v2ray-onekey.sh`

- [ ] **Step 1: Add a failing Nginx renderer test**

Append and invoke:

```bash
test_nginx_renderer() {
  local temp_dir
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN

  DOMAIN="vpn.example.com"
  CLOUDFLARE_PORT="8443"
  INTERNAL_WS_PORT="31001"
  WS_PATH="/6f4f5304d2e84dc8"
  ACME_WEBROOT="/var/www/v2ray-onekey"
  render_nginx_site "$temp_dir/site.conf" "final"

  grep -Fq 'listen 8443 ssl;' "$temp_dir/site.conf" || fail "Nginx TLS port missing"
  grep -Fq 'location = /6f4f5304d2e84dc8 {' "$temp_dir/site.conf" || fail "WebSocket location missing"
  grep -Fq 'proxy_pass http://127.0.0.1:31001;' "$temp_dir/site.conf" || fail "Xray upstream missing"
  grep -Fq 'proxy_buffering off;' "$temp_dir/site.conf" || fail "WebSocket buffering not disabled"
  grep -Fq "ssl_certificate /etc/letsencrypt/live/vpn.example.com/fullchain.pem;" "$temp_dir/site.conf" || fail "certificate path missing"
}

test_nginx_renderer
```

- [ ] **Step 2: Run tests and confirm `render_nginx_site` is missing**

Run the Bash test container. Expected: exit 1 naming `render_nginx_site`.

- [ ] **Step 3: Implement initial and final Nginx site rendering**

`render_nginx_site PATH initial` must create an HTTP server on port 80 with an ACME webroot location and an ordinary `ok` response. `render_nginx_site PATH final` must retain the ACME location and add this TLS server:

```nginx
server {
    listen CLOUDFLARE_PORT ssl;
    listen [::]:CLOUDFLARE_PORT ssl;
    server_name DOMAIN;

    ssl_certificate /etc/letsencrypt/live/DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location = WS_PATH {
        proxy_pass http://127.0.0.1:INTERNAL_WS_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }

    location / {
        default_type text/plain;
        return 200 "ok\n";
    }
}
```

Escape Nginx runtime variables in the Bash heredoc so `$http_upgrade`, `$host`, and `$proxy_add_x_forwarded_for` remain literal in the generated file.

- [ ] **Step 4: Implement certificate issuance and renewal reload**

Use a webroot challenge rather than giving Certbot permission to rewrite Nginx:

```bash
certbot certonly \
  --webroot -w "$ACME_WEBROOT" \
  --non-interactive --agree-tos \
  --email "$EMAIL" \
  --keep-until-expiring \
  -d "$DOMAIN"
```

Create `/etc/letsencrypt/renewal-hooks/deploy/v2ray-onekey-nginx.sh` with mode 755 and this content:

```bash
#!/usr/bin/env bash
set -e
nginx -t
systemctl reload nginx
```

After the final site is active, request `https://$DOMAIN:$CLOUDFLARE_PORT/` with curl and require either a `CF-Ray` response header or a resolved Cloudflare edge address. Warn, but do not remove a working origin configuration, if this post-install edge check fails.

- [ ] **Step 5: Run renderer tests and commit Cloudflare origin support**

```powershell
docker run --rm -v "${PWD}:/work" -w /work bash:5.2 bash tests/test_v2ray_onekey.sh
```

Expected: all tests pass.

```bash
git add outputs/v2ray-onekey.sh tests/test_v2ray_onekey.sh
git commit -m "feat: configure Cloudflare WebSocket origin"
```

### Task 6: Implement Transactional Installation, Migration, and Rollback

**Files:**
- Modify: `outputs/v2ray-onekey.sh`
- Modify: `tests/test_v2ray_onekey.sh`

- [ ] **Step 1: Add a failing backup test using temporary paths**

Append and invoke:

```bash
test_backup_file() {
  local temp_dir
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  printf 'old-config\n' >"$temp_dir/config.json"
  BACKUP_DIR="$temp_dir/backup"
  backup_file "$temp_dir/config.json"
  [[ -f "$BACKUP_DIR$tmp_dir/config.json" ]] || fail "backup path missing"
  assert_eq "old-config" "$(cat "$BACKUP_DIR$tmp_dir/config.json")" "backup content"
}

test_backup_file
```

- [ ] **Step 2: Run tests and confirm `backup_file` is missing**

Run the Bash test container. Expected: exit 1 naming `backup_file`.

- [ ] **Step 3: Implement scoped backups and rollback metadata**

Create a run-specific directory with:

```bash
BACKUP_DIR="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 700 "$BACKUP_DIR"
```

`backup_file ABSOLUTE_PATH` must copy an existing regular file to `$BACKUP_DIR$ABSOLUTE_PATH`, preserving mode and parents. Track every backed-up path in `$BACKUP_DIR/manifest`. Back up only:

```text
/usr/local/etc/v2ray/config.json
/usr/local/etc/xray/config.json
/etc/v2ray-onekey/state.env
/etc/nginx/conf.d/v2ray-onekey.conf
/etc/letsencrypt/renewal-hooks/deploy/v2ray-onekey-nginx.sh
```

Also back up every legacy Nginx file that passed the three-signature ownership check from Task 4. Rename each matched legacy file with a `.v2ray-onekey-disabled-RUN_TIMESTAMP` suffix while the new site is active so Nginx no longer includes it. Rollback removes the suffix and restores its original path.

Record whether `v2ray`, `xray`, and `nginx` were active before the run. `rollback_current_run` restores only manifest paths, removes only newly created project-owned files, reloads systemd, and returns services to their recorded active/inactive state.

- [ ] **Step 4: Implement package and Xray installation**

Retain apt, dnf, and yum support. Install `curl`, `ca-certificates`, `openssl`, `python3`, `coreutils`, and `iproute2`. For Cloudflare modes also install `nginx`, `certbot`, and the distribution's Nginx Certbot package when available.

Install or update Xray using the official installer:

```bash
bash -c "$(curl -LfsS "$XRAY_INSTALL_URL")" @ install
```

Do not uninstall V2Ray. Disable it only after Xray and any required Nginx configuration have both validated and started successfully.

- [ ] **Step 5: Implement staged configuration and service cutover**

Use the following order in `deploy_services`:

```text
1. Create the backup directory and back up managed files.
2. Install packages and Xray.
3. Generate or reuse credentials.
4. Validate the REALITY target and Cloudflare DNS prerequisites.
5. Render Xray JSON to a temporary file.
6. Run `xray run -test -config TEMP_FILE`.
7. In Cloudflare modes, render the initial Nginx site, run `nginx -t`, reload Nginx, and obtain the certificate.
8. Render and validate the final Nginx site.
9. Install the validated Xray and Nginx files atomically.
10. Run `systemctl daemon-reload`, enable/restart Xray, and reload Nginx when used.
11. Require `systemctl is-active --quiet xray` and the expected `ss -lnt` listeners.
12. Disable V2Ray.
13. Save state and print links.
```

Install an `ERR` trap only around the transactional deployment phase:

```bash
deployment_failed() {
  local status=$?
  warn "Deployment failed; restoring files from $BACKUP_DIR"
  rollback_current_run || warn "Automatic rollback was incomplete"
  exit "$status"
}

trap deployment_failed ERR
deploy_services
trap - ERR
```

- [ ] **Step 6: Implement firewall and final status output**

Open TCP 80 only for Cloudflare modes, `REALITY_PORT` only when enabled, and `CLOUDFLARE_PORT` only when enabled. Modify UFW or firewalld only when already active. Print a separate cloud-security-group reminder listing the same ports.

Final output must include:

```text
Primary direct entry: VLESS + REALITY + XTLS Vision
Fallback entry: VLESS + WebSocket + TLS + Cloudflare
State file: /etc/v2ray-onekey/state.env
Backup: /var/backups/v2ray-onekey/TIMESTAMP
Diagnostics: systemctl status xray; journalctl -u xray -e; nginx -t
```

Print only the entries enabled by the selected mode.

- [ ] **Step 7: Run tests and commit transactional deployment**

```powershell
docker run --rm -v "${PWD}:/work" -w /work bash:5.2 bash tests/test_v2ray_onekey.sh
docker run --rm -v "${PWD}:/work" -w /work bash:5.2 bash -n outputs/v2ray-onekey.sh
```

Expected: both commands exit 0.

```bash
git add outputs/v2ray-onekey.sh tests/test_v2ray_onekey.sh
git commit -m "feat: migrate to transactional Xray deployment"
```

### Task 7: Rewrite User Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add documentation acceptance checks**

Run these before editing and expect at least one command to fail:

```powershell
rg -F "VLESS + REALITY" README.md
rg -F "--mode dual" README.md
rg -F "Full (strict)" README.md
rg -F "8443" README.md
```

- [ ] **Step 2: Replace the VMess-only README**

Document these exact command paths:

```bash
# Interactive menu; option 3 installs both entries
sudo bash outputs/v2ray-onekey.sh

# Direct entry only, no domain
sudo bash outputs/v2ray-onekey.sh --mode reality

# Cloudflare entry only
sudo bash outputs/v2ray-onekey.sh \
  --mode cloudflare \
  --domain vpn.example.com \
  --email admin@example.com

# Both entries
sudo bash outputs/v2ray-onekey.sh \
  --mode dual \
  --domain vpn.example.com \
  --email admin@example.com
```

Add Cloudflare prerequisites: proxied A/AAAA record, WebSockets enabled, `Full (strict)`, TCP 80 and 8443 reachable in dual mode, and TCP 80 and 443 reachable in Cloudflare-only mode. Explain that REALITY uses TCP 443 in direct/dual mode.

Add v2rayN instructions: keep the Xray core selected, copy each printed `vless://` link, and import from clipboard. State that V2Fly core does not implement REALITY.

Add diagnostics, certificate renewal test (`certbot renew --dry-run`), credential rotation, backup location, Cloudflare TLS-termination trust note, and the same-server redundancy limitation.

- [ ] **Step 3: Run documentation checks and commit**

Run the four `rg` checks again. Expected: all exit 0.

```bash
git add README.md
git commit -m "docs: explain dual-entry deployment"
```

### Task 8: Full Verification and Publication

**Files:**
- Verify: `outputs/v2ray-onekey.sh`
- Verify: `tests/test_v2ray_onekey.sh`
- Verify: `README.md`

- [ ] **Step 1: Run ShellCheck**

```powershell
docker run --rm -v "${PWD}:/mnt" koalaman/shellcheck:stable /mnt/outputs/v2ray-onekey.sh /mnt/tests/test_v2ray_onekey.sh
```

Expected: exit 0 with no diagnostics. Fix every finding or add a narrowly scoped `shellcheck disable` comment that explains why sourcing is intentional.

- [ ] **Step 2: Run the complete shell test suite**

```powershell
docker run --rm -v "${PWD}:/work" -w /work bash:5.2 bash tests/test_v2ray_onekey.sh
docker run --rm -v "${PWD}:/work" -w /work bash:5.2 bash -n outputs/v2ray-onekey.sh
```

Expected: tests print all PASS lines and both commands exit 0.

- [ ] **Step 3: Verify repository hygiene**

```powershell
git diff --check
git status --short
git log --oneline --decorate -8
```

Expected: no whitespace errors; `.codex-remote-attachments/` remains untracked and is not staged; only intended project files appear in commits.

- [ ] **Step 4: Perform a disposable Linux smoke test when Docker supports systemd**

If a systemd-capable disposable Linux VM/container is available, run `--mode reality` against a non-public test port and verify `xray run -test`, service startup, state permissions, and the generated URI. Do not claim an end-to-end network deployment was tested when only static/container tests were possible.

- [ ] **Step 5: Create a final fixup commit only if verification changed files**

```bash
git add README.md outputs/v2ray-onekey.sh tests/test_v2ray_onekey.sh
git commit -m "fix: address dual-entry verification findings"
```

Skip this commit when the worktree has no tracked changes.

- [ ] **Step 6: Push the completed branch**

```bash
git push origin main
```

Expected: `main` and `origin/main` point to the same final commit. Report the commit ID, tests run, and the limitation that a real VPS/Cloudflare hostname is still required for an end-to-end connectivity test.
