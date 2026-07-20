# Fresh Multi-Protocol Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone native-systemd installer for a clean server with direct, Cloudflare-only, and full modes using Hysteria2, Shadowsocks 2022, and the unchanged VLESS WebSocket Cloudflare path.

**Architecture:** Move the existing tested installer into one generated-source template and render a standalone fresh-server artifact from it. Keep Xray responsible for Cloudflare VLESS and Shadowsocks, run the official Hysteria2 binary as a separate hardened systemd service, and extend the existing transaction/state/firewall machinery to manage both services atomically.

**Tech Stack:** Bash 4+, Python 3 JSON helpers, Xray, Hysteria2, OpenSSL, Nginx, Certbot, systemd, UFW/firewalld, nftables/iptables, shell test doubles, GitHub Actions.

---

## File Map

- Create `src/v2ray-onekey.sh.in`: single source template for generated standalone installers; initially implements the `new` profile.
- Create `tools/build-installers.sh`: deterministic renderer for `outputs/v2ray-onekey-new.sh`.
- Create `outputs/v2ray-onekey-new.sh`: generated, standalone fresh-server deliverable.
- Delete `outputs/v2ray-onekey.sh`: retired REALITY-capable artifact.
- Rename `tests/test_v2ray_onekey.sh` to `tests/test_v2ray_onekey_new.sh`: fresh-installer unit and transaction tests.
- Create `tests/test_build_installers.sh`: verifies generated artifacts are current and standalone.
- Create `.github/workflows/compatibility.yml`: shell/static matrix from the approved compatibility spec.
- Modify `README.md`: new script names, modes, Cloudflare instructions, import links, ports, diagnostics, and limitations.

### Task 1: Create a Deterministic Standalone Build

**Files:**
- Create: `src/v2ray-onekey.sh.in`
- Create: `tools/build-installers.sh`
- Create: `tests/test_build_installers.sh`
- Create: `outputs/v2ray-onekey-new.sh`
- Delete: `outputs/v2ray-onekey.sh`
- Rename: `tests/test_v2ray_onekey.sh` to `tests/test_v2ray_onekey_new.sh`

- [ ] **Step 1: Write the failing artifact-build test**

Create `tests/test_build_installers.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fresh="$ROOT_DIR/outputs/v2ray-onekey-new.sh"

"$ROOT_DIR/tools/build-installers.sh" --check
[[ -x "$fresh" ]]
head -n 1 "$fresh" | grep -Fqx '#!/usr/bin/env bash'
grep -Fq 'INSTALLER_VARIANT="new"' "$fresh"
if grep -Fq '@INSTALLER_VARIANT@' "$fresh"; then
  printf 'unexpanded installer variant\n' >&2
  exit 1
fi
bash -n "$fresh"
printf 'PASS: generated fresh installer is current\n'
```

- [ ] **Step 2: Run the build test and verify it fails**

Run: `bash tests/test_build_installers.sh`

Expected: FAIL because `tools/build-installers.sh` and `outputs/v2ray-onekey-new.sh` do not exist.

- [ ] **Step 3: Move the existing installer into the template and add the variant marker**

Run:

```bash
mkdir -p src tools
git mv outputs/v2ray-onekey.sh src/v2ray-onekey.sh.in
git mv tests/test_v2ray_onekey.sh tests/test_v2ray_onekey_new.sh
```

Insert immediately after the shebang in `src/v2ray-onekey.sh.in`:

```bash
INSTALLER_VARIANT="@INSTALLER_VARIANT@"
```

Change the test script path in `tests/test_v2ray_onekey_new.sh`:

```bash
SCRIPT="$ROOT_DIR/outputs/v2ray-onekey-new.sh"
```

- [ ] **Step 4: Implement the deterministic builder**

Create `tools/build-installers.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT_DIR/src/v2ray-onekey.sh.in"
OUTPUT="$ROOT_DIR/outputs/v2ray-onekey-new.sh"

render() {
  local destination="$1" temp
  temp="$(mktemp)"
  sed 's/@INSTALLER_VARIANT@/new/g' "$TEMPLATE" >"$temp"
  chmod 755 "$temp"
  if [[ "${2:-write}" == "check" ]]; then
    cmp -s "$temp" "$destination" || {
      rm -f "$temp"
      printf 'generated artifact is stale: %s\n' "$destination" >&2
      return 1
    }
    rm -f "$temp"
  else
    mv "$temp" "$destination"
  fi
}

mkdir -p "$ROOT_DIR/outputs"
case "${1:-}" in
  --check) render "$OUTPUT" check ;;
  "") render "$OUTPUT" write ;;
  *) printf 'usage: %s [--check]\n' "$0" >&2; exit 2 ;;
esac
```

Run `chmod +x tools/build-installers.sh tests/test_build_installers.sh` and `tools/build-installers.sh`.

- [ ] **Step 5: Run baseline syntax and behavior tests**

Run:

```bash
bash tests/test_build_installers.sh
bash tests/test_v2ray_onekey_new.sh
```

Expected: both PASS with the existing behavior before protocol changes.

- [ ] **Step 6: Commit the build boundary**

```bash
git add src/v2ray-onekey.sh.in tools/build-installers.sh outputs/v2ray-onekey-new.sh tests/test_build_installers.sh tests/test_v2ray_onekey_new.sh
git commit -m "build: generate standalone installer artifacts"
```

### Task 2: Replace REALITY Modes and State With Direct/Full Modes

**Files:**
- Modify: `src/v2ray-onekey.sh.in`
- Modify: `outputs/v2ray-onekey-new.sh`
- Modify: `tests/test_v2ray_onekey_new.sh`

- [ ] **Step 1: Replace mode tests with the approved menu contract**

In `tests/test_v2ray_onekey_new.sh`, replace REALITY mode assertions with:

```bash
reset_options
MODE="direct"
resolve_default_ports
mode_has_hysteria || fail "direct mode lacks Hysteria2"
mode_has_shadowsocks || fail "direct mode lacks Shadowsocks"
mode_has_cloudflare && fail "direct mode unexpectedly includes Cloudflare"
mode_needs_domain && fail "direct mode unexpectedly requires a domain"
assert_eq "20000-20100" "$HY2_PORT_RANGE" "default Hysteria2 range"
assert_eq "8388" "$SS_PORT" "default Shadowsocks port"

reset_options
MODE="cloudflare"
resolve_default_ports
mode_has_hysteria && fail "cloudflare mode unexpectedly includes Hysteria2"
mode_has_shadowsocks && fail "cloudflare mode unexpectedly includes Shadowsocks"
mode_has_cloudflare || fail "cloudflare mode lacks Cloudflare"
mode_needs_domain || fail "cloudflare mode must require a domain"

reset_options
MODE="full"
resolve_default_ports
mode_has_hysteria || fail "full mode lacks Hysteria2"
mode_has_shadowsocks || fail "full mode lacks Shadowsocks"
mode_has_cloudflare || fail "full mode lacks Cloudflare"
mode_needs_domain || fail "full mode must require a domain"
```

Add CLI assertions for `--mode direct|cloudflare|full`, `--hy2-port-range`, `--ss-port`, `--server-address`, `--allow-mail`, and the absence of all `--reality-*` options.

- [ ] **Step 2: Run the focused mode test and verify it fails**

Run: `bash tests/test_v2ray_onekey_new.sh`

Expected: FAIL at `mode_has_hysteria: command not found` or the first old mode assertion.

- [ ] **Step 3: Implement the new mode predicates and defaults**

Replace the old mode predicates with:

```bash
mode_has_cloudflare() { [[ "$MODE" == "cloudflare" || "$MODE" == "full" ]]; }
mode_has_hysteria() { [[ "$MODE" == "direct" || "$MODE" == "full" ]]; }
mode_has_shadowsocks() { [[ "$MODE" == "direct" || "$MODE" == "full" ]]; }
mode_needs_domain() { mode_has_cloudflare; }

resolve_default_ports() {
  mode_has_cloudflare && CLOUDFLARE_PORT="${CLOUDFLARE_PORT:-443}" || CLOUDFLARE_PORT=""
  mode_has_hysteria && HY2_PORT_RANGE="${HY2_PORT_RANGE:-20000-20100}" || HY2_PORT_RANGE=""
  mode_has_shadowsocks && SS_PORT="${SS_PORT:-8388}" || SS_PORT=""
}
```

Set the interactive menu and parser to these exact values:

```bash
printf '%s\n' \
  '1) Direct: Hysteria2 + Shadowsocks 2022 (no domain)' \
  '2) Cloudflare: VLESS + WebSocket + TLS' \
  '3) Full: Cloudflare + Hysteria2 + Shadowsocks 2022 (recommended)'
read -r -p 'Select mode [3]: ' selection
case "${selection:-3}" in
  1) MODE="direct" ;;
  2) MODE="cloudflare" ;;
  3) MODE="full" ;;
  *) die "Invalid mode selection: $selection" ;;
esac
```

Delete REALITY variables, key parsing, target probing, argument branches, validation, rendering, URI output, and service-summary labels from the template.

- [ ] **Step 4: Add versioned state fields and safe legacy loading**

Define the active state keys:

```bash
STATE_KEYS=(
  STATE_SCHEMA MODE DOMAIN EMAIL CLOUDFLARE_PORT INTERNAL_WS_PORT
  CLOUDFLARE_UUID WS_PATH HY2_PORT_RANGE HY2_AUTH HY2_OBFS_PASSWORD
  HY2_SNI HY2_CERT_PIN SS_PORT SS_METHOD SS_KEY SERVER_ADDRESS
  ALLOW_BITTORRENT ALLOW_MAIL
)
```

Set `STATE_SCHEMA=2`. Keep the parser non-executing and allow old known REALITY keys only while reading schema 1; never write those keys back. `--rotate` clears Cloudflare, Hysteria2, and Shadowsocks credentials but retains mode, selected ports, domain, email, and server address.

- [ ] **Step 5: Rebuild and run mode/state tests**

Run:

```bash
tools/build-installers.sh
bash tests/test_build_installers.sh
bash tests/test_v2ray_onekey_new.sh
```

Expected: mode, argument, interactive prompt, state round-trip, and source-only sections PASS; protocol rendering sections may still fail until Tasks 3 and 4.

- [ ] **Step 6: Commit the mode/state migration**

```bash
git add src/v2ray-onekey.sh.in outputs/v2ray-onekey-new.sh tests/test_v2ray_onekey_new.sh
git commit -m "feat: replace reality modes with direct bundles"
```

### Task 3: Add Shadowsocks 2022 to Xray

**Files:**
- Modify: `src/v2ray-onekey.sh.in`
- Modify: `outputs/v2ray-onekey-new.sh`
- Modify: `tests/test_v2ray_onekey_new.sh`

- [ ] **Step 1: Add failing Shadowsocks config and URI tests**

Render a direct-mode Xray config and assert with Python:

```python
ss = next(item for item in config["inbounds"] if item["tag"] == "shadowsocks-2022-in")
assert ss["protocol"] == "shadowsocks"
assert ss["port"] == 8388
assert ss["settings"]["method"] == "2022-blake3-aes-128-gcm"
assert ss["settings"]["password"] == expected_key
assert ss["settings"]["network"] == "tcp,udp"
assert all(item["tag"] != "reality-in" for item in config["inbounds"])
```

Parse `make_shadowsocks_link` with Python `urllib.parse` and assert the decoded userinfo is `2022-blake3-aes-128-gcm:<key>`, host is the public address, port is `8388`, and fragment is `Shadowsocks-2022-direct`.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `tools/build-installers.sh && bash tests/test_v2ray_onekey_new.sh`

Expected: FAIL because the Shadowsocks inbound and link function do not exist.

- [ ] **Step 3: Generate and validate the Shadowsocks key**

Add:

```bash
generate_ss_key() { openssl rand -base64 16 | tr -d '\r\n'; }

valid_ss_key() {
  [[ "$1" =~ ^[A-Za-z0-9+/]{22}==$ ]] || return 1
  [[ "$(printf '%s' "$1" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ')" == "16" ]]
}
```

Set `SS_METHOD=2022-blake3-aes-128-gcm`; generate `SS_KEY` only when Shadowsocks is enabled and the saved key is absent; reject invalid loaded keys.

- [ ] **Step 4: Render the inbound and SIP002 link**

Add this inbound in the existing Python JSON renderer when `mode in ("direct", "full")`:

```python
inbounds.append({
    "tag": "shadowsocks-2022-in",
    "listen": "0.0.0.0",
    "port": int(ss_port),
    "protocol": "shadowsocks",
    "settings": {
        "method": ss_method,
        "password": ss_key,
        "network": "tcp,udp"
    }
})
```

Add:

```bash
make_shadowsocks_link() {
  local authority
  authority="$(printf '%s' "$SS_METHOD:$SS_KEY" | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
  printf 'ss://%s@%s:%s#%s\n' "$authority" "$(format_uri_host "$SERVER_ADDRESS")" \
    "$SS_PORT" "$(urlencode 'Shadowsocks-2022-direct')"
}
```

- [ ] **Step 5: Run Xray rendering/link tests**

Run: `tools/build-installers.sh && bash tests/test_v2ray_onekey_new.sh`

Expected: all Shadowsocks rendering, key, routing, IPv4/IPv6 URI, and rotation assertions PASS.

- [ ] **Step 6: Commit Shadowsocks support**

```bash
git add src/v2ray-onekey.sh.in outputs/v2ray-onekey-new.sh tests/test_v2ray_onekey_new.sh
git commit -m "feat: add shadowsocks 2022 direct entry"
```

### Task 4: Add the Native Hysteria2 Service

**Files:**
- Modify: `src/v2ray-onekey.sh.in`
- Modify: `outputs/v2ray-onekey-new.sh`
- Modify: `tests/test_v2ray_onekey_new.sh`

- [ ] **Step 1: Add failing Hysteria2 renderer, certificate, unit, and URI tests**

Use test doubles for `openssl`, `curl`, `install`, and `systemctl`. Assert the staged YAML contains:

```yaml
listen: :20000-20100
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
  sniGuard: strict
auth:
  type: password
  password: test-auth
obfs:
  type: salamander
  salamander:
    password: test-obfs
acl:
  file: /etc/hysteria/acl.txt
```

Assert the unit executes `/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml`, runs as `hysteria`, and grants only `CAP_NET_ADMIN` and `CAP_NET_BIND_SERVICE`. Assert the URI contains `obfs=salamander`, `obfs-password`, `sni`, `pinSHA256`, and `20000-20100`, without `insecure` or `allowInsecure`.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `tools/build-installers.sh && bash tests/test_v2ray_onekey_new.sh`

Expected: FAIL because `render_hysteria_config`, `render_hysteria_unit`, and `make_hysteria_link` are undefined.

- [ ] **Step 3: Implement official binary installation and credential generation**

Add constants and helpers:

```bash
HYSTERIA_DOWNLOAD_URL="https://download.hysteria.network/app/latest/hysteria-linux-amd64"
HYSTERIA_BIN="${HYSTERIA_BIN:-/usr/local/bin/hysteria}"
HYSTERIA_CONFIG="${HYSTERIA_CONFIG:-/etc/hysteria/config.yaml}"
HYSTERIA_ACL="${HYSTERIA_ACL:-/etc/hysteria/acl.txt}"
HYSTERIA_CERT="${HYSTERIA_CERT:-/etc/hysteria/server.crt}"
HYSTERIA_KEY="${HYSTERIA_KEY:-/etc/hysteria/server.key}"

random_urlsafe_secret() { openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\r\n'; }
```

Download to the private runtime directory with finite `curl --connect-timeout` and `--max-time`, run `hysteria version`, then install mode `0755` only after validation. Generate the self-signed certificate and official colon-separated SHA-256 fingerprint with:

```bash
HY2_SNI="$(openssl rand -hex 8).invalid"
openssl ecparam -genkey -name prime256v1 -noout -out "$staged_key"
openssl req -new -x509 -sha256 -days 3650 -key "$staged_key" -out "$staged_cert" \
  -subj "/CN=$HY2_SNI" -addext "subjectAltName=DNS:$HY2_SNI"
HY2_CERT_PIN="$(openssl x509 -noout -fingerprint -sha256 -in "$staged_cert" | cut -d= -f2 | tr -d '\r\n')"
```

Reject an empty pin or any value outside `^([0-9A-F]{2}:){31}[0-9A-F]{2}$`.

- [ ] **Step 4: Render YAML, ACL, and the hardened systemd unit**

Render YAML with quoted generated values and `listen: :$HY2_PORT_RANGE`. Render ACL rules in this exact order:

```text
reject(0.0.0.0/8)
reject(10.0.0.0/8)
reject(100.64.0.0/10)
reject(127.0.0.0/8)
reject(169.254.0.0/16)
reject(172.16.0.0/12)
reject(192.168.0.0/16)
reject(224.0.0.0/4)
reject(::1/128)
reject(fc00::/7)
reject(fe80::/10)
reject(all, tcp/25)
reject(all, tcp/465)
reject(all, tcp/587)
direct(all)
```

Omit the three mail rules only with `--allow-mail`. Do not add a BitTorrent ACL keyword to Hysteria2: its documented sniffer does not identify BitTorrent. Document that Xray protocol sniffing blocks BitTorrent on Xray entries while the independent Hysteria2 path enforces private-address and mail-port restrictions only.

Render a unit compatible with Ubuntu 18.04 systemd:

```ini
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
```

Render one validation YAML with staged certificate, key, and ACL paths. Validate it on the selected free range before installing files:

```bash
validate_hysteria_staged() {
  local binary="$1" config="$2" log="$3" status
  set +e
  timeout --signal=TERM 4s "$binary" server -c "$config" >"$log" 2>&1
  status=$?
  set -e
  [[ "$status" == "124" || "$status" == "143" ]] || return 1
  grep -Fq 'server up and running' "$log"
}
```

After this smoke process exits and cleans its temporary hopping rules, render the install YAML with `/etc/hysteria/` paths. Tests stub `timeout`; disposable-VPS acceptance exercises the real bind and cleanup behavior.

- [ ] **Step 5: Render and validate the Hysteria2 URI**

Add:

```bash
make_hysteria_link() {
  printf 'hysteria2://%s@%s:%s/?obfs=salamander&obfs-password=%s&sni=%s&pinSHA256=%s#%s\n' \
    "$(urlencode "$HY2_AUTH")" "$(format_uri_host "$SERVER_ADDRESS")" "$HY2_PORT_RANGE" \
    "$(urlencode "$HY2_OBFS_PASSWORD")" "$(urlencode "$HY2_SNI")" \
    "$(urlencode "$HY2_CERT_PIN")" "$(urlencode 'Hysteria2-direct')"
}
```

Validate the resulting URI with Python before printing it.

- [ ] **Step 6: Run the Hysteria2 tests**

Run: `tools/build-installers.sh && bash tests/test_v2ray_onekey_new.sh`

Expected: Hysteria2 YAML, ACL, certificate pin, unit, URI, credential reuse, and permissions tests PASS.

- [ ] **Step 7: Commit Hysteria2 support**

```bash
git add src/v2ray-onekey.sh.in outputs/v2ray-onekey-new.sh tests/test_v2ray_onekey_new.sh
git commit -m "feat: add native hysteria2 direct entry"
```

### Task 5: Extend Port, Firewall, Transaction, and Readiness Handling

**Files:**
- Modify: `src/v2ray-onekey.sh.in`
- Modify: `outputs/v2ray-onekey-new.sh`
- Modify: `tests/test_v2ray_onekey_new.sh`

- [ ] **Step 1: Add failing TCP/UDP conflict and rollback tests**

Add test doubles where `ss -H -lntup` reports UDP `20005` and TCP `8388`. Assert interactive input can replace them with `21000-21100` and `8488`; non-interactive output names `--hy2-port-range` and `--ss-port`. Assert a TCP `443` Nginx listener does not conflict with UDP `443` and that Shadowsocks rejects either TCP or UDP occupancy.

Extend the rollback fixture to include the Hysteria config, ACL, cert, key, unit, binary, `hysteria-server` active/enabled state, and current-run UFW/firewalld additions.

- [ ] **Step 2: Run the focused tests and verify they fail**

Run: `tools/build-installers.sh && bash tests/test_v2ray_onekey_new.sh`

Expected: FAIL because range-aware UDP checks and Hysteria rollback entries are absent.

- [ ] **Step 3: Implement strict port/range parsing and conflict detection**

Add:

```bash
parse_port_range() {
  [[ "$1" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || return 1
  HY2_PORT_START="$(normalize_port "${BASH_REMATCH[1]}")"
  HY2_PORT_END="$(normalize_port "${BASH_REMATCH[2]}")"
  valid_port "$HY2_PORT_START" && valid_port "$HY2_PORT_END" || return 1
  (( HY2_PORT_START <= HY2_PORT_END )) || return 1
  (( HY2_PORT_END - HY2_PORT_START <= 1000 ))
}
```

Use `ss -H -lnup` for every UDP port in the selected Hysteria range and `ss -H -lntup` for the Shadowsocks port. Preserve full conflict output for diagnostics.

- [ ] **Step 4: Add firewall range operations and rollback records**

For active UFW use `ufw allow START:END/udp`; for active firewalld use `--add-port=START-END/udp` at runtime and permanently. Record only rules successfully added by this run and remove those exact rules during rollback. Continue to leave inactive or unknown firewalls unchanged.

- [ ] **Step 5: Extend transaction ownership and service-state manifests**

Include every Hysteria-managed path and `hysteria-server` in backup, stop, restore, enablement, and restart order. Reject pre-existing non-project Hysteria files or units by checking exact project markers before mutation.

- [ ] **Step 6: Add readiness checks**

After activation, wait with a bounded timeout for:

```bash
systemctl is-active --quiet xray
systemctl is-active --quiet hysteria-server
ss -H -lntp "sport = :$SS_PORT"
ss -H -lnup "sport = :$SS_PORT"
ss -H -lnup "sport = :$HY2_PORT_START"
```

On timeout print `systemctl status`, the matching journal command, and listener output, then trigger rollback.

- [ ] **Step 7: Run transaction and firewall tests**

Run: `tools/build-installers.sh && bash tests/test_v2ray_onekey_new.sh`

Expected: port, firewall, service readiness, backup permissions, and forced-failure rollback sections PASS.

- [ ] **Step 8: Commit lifecycle support**

```bash
git add src/v2ray-onekey.sh.in outputs/v2ray-onekey-new.sh tests/test_v2ray_onekey_new.sh
git commit -m "feat: manage multi-protocol service lifecycle"
```

### Task 6: Integrate All Fresh Deployment Modes and Output

**Files:**
- Modify: `src/v2ray-onekey.sh.in`
- Modify: `outputs/v2ray-onekey-new.sh`
- Modify: `tests/test_v2ray_onekey_new.sh`

- [ ] **Step 1: Add failing deployment-order and output tests**

Assert exact high-level event order for each mode:

```text
preflight backup packages values stage validate stop install start readiness state firewall edge summary commit
```

Direct mode must not install Nginx/Certbot or ask for domain/email. Cloudflare mode must not install Hysteria2 or open UDP/8388. Full mode must preserve the existing Cloudflare renderer and print links in Cloudflare, Hysteria2, Shadowsocks order.

- [ ] **Step 2: Run tests and verify they fail**

Run: `tools/build-installers.sh && bash tests/test_v2ray_onekey_new.sh`

Expected: FAIL in deploy orchestration or mode-specific summary assertions.

- [ ] **Step 3: Implement mode-aware orchestration**

Refactor `deploy_services` to call narrowly named stages:

```bash
prepare_fresh_inputs
begin_transaction
install_mode_dependencies
generate_mode_credentials
stage_mode_configurations
validate_staged_configurations
cut_over_mode_services
verify_mode_services
save_state
configure_firewall
verify_cloudflare_when_enabled
print_deployment_summary
```

Each stage must gate Cloudflare, Hysteria2, and Shadowsocks work through the three mode predicates. Preserve the current Cloudflare Nginx, Certbot, edge-check, and URI functions byte-for-byte unless parameter names must change after REALITY removal.

- [ ] **Step 4: Print exact final guidance**

The summary prints enabled links, then:

```text
State file: /etc/v2ray-onekey/state.env
Diagnostics: systemctl status xray hysteria-server; journalctl -u xray -u hysteria-server -e; nginx -t
Cloud security group: TCP 80,443,8388 and UDP 8388,20000-20100
```

Omit inactive services and ports from those lines. Include the warning that only the Cloudflare path avoids direct client connections to the server IP.

- [ ] **Step 5: Assert REALITY is absent from the built artifact**

Add to `tests/test_build_installers.sh`. Legacy field names may remain for safe state migration and opaque rollback, so reject only executable/public REALITY features:

```bash
if grep -Eiq -- '--reality-|make_reality_link|xtls-rprx-vision|security=reality|"tag"[[:space:]]*:[[:space:]]*"reality-in"' "$fresh"; then
  printf 'retired REALITY implementation remains in fresh installer\n' >&2
  exit 1
fi
```

- [ ] **Step 6: Run the complete local suite**

Run:

```bash
tools/build-installers.sh
bash tests/test_build_installers.sh
bash tests/test_v2ray_onekey_new.sh
git diff --check
```

Expected: all tests PASS and `git diff --check` prints nothing.

- [ ] **Step 7: Commit integrated fresh modes**

```bash
git add src/v2ray-onekey.sh.in outputs/v2ray-onekey-new.sh tests/test_build_installers.sh tests/test_v2ray_onekey_new.sh
git commit -m "feat: complete fresh multi-protocol installer"
```

### Task 7: Document and Matrix-Test the Fresh Installer

**Files:**
- Modify: `README.md`
- Create: `.github/workflows/compatibility.yml`
- Create: `tests/compatibility-entrypoint.sh`
- Modify: `tests/test_build_installers.sh`

- [ ] **Step 1: Add failing documentation and workflow contract checks**

Extend `tests/test_build_installers.sh`:

```bash
grep -Fq 'outputs/v2ray-onekey-new.sh' "$ROOT_DIR/README.md"
grep -Fq 'Hysteria2' "$ROOT_DIR/README.md"
grep -Fq 'Shadowsocks 2022' "$ROOT_DIR/README.md"
grep -Fq 'Cloudflare' "$ROOT_DIR/README.md"
grep -Fq 'ubuntu:18.04' "$ROOT_DIR/.github/workflows/compatibility.yml"
grep -Fq 'rockylinux:9' "$ROOT_DIR/.github/workflows/compatibility.yml"
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `bash tests/test_build_installers.sh`

Expected: FAIL because README and compatibility workflow are not updated.

- [ ] **Step 3: Rewrite README usage and migration guidance**

Document these commands exactly:

```bash
sudo bash outputs/v2ray-onekey-new.sh
sudo bash outputs/v2ray-onekey-new.sh --mode direct
sudo bash outputs/v2ray-onekey-new.sh --mode cloudflare --domain vpn.example.com --email admin@example.com
sudo bash outputs/v2ray-onekey-new.sh --mode full --domain vpn.example.com --email admin@example.com
```

Add the TCP/UDP table, Cloudflare orange-cloud and `Full (strict)` steps, Hysteria security-group range, three import-link types, rotation behavior, service diagnostics, 2-core/2-GB target, no-Docker statement, and explicit no-guarantee language. Remove all REALITY instructions.

- [ ] **Step 4: Add the compatibility entrypoint and workflow**

`tests/compatibility-entrypoint.sh` installs Bash, Python 3, OpenSSL, curl, coreutils, iproute tools, and awk using the container's package manager, then runs:

```bash
bash -n src/v2ray-onekey.sh.in
bash -n outputs/v2ray-onekey-new.sh
bash tests/test_build_installers.sh
bash tests/test_v2ray_onekey_new.sh
```

Create a matrix for `ubuntu:18.04`, `ubuntu:20.04`, `ubuntu:22.04`, `ubuntu:24.04`, `debian:10`, `debian:11`, `debian:12`, `rockylinux:8`, `rockylinux:9`, `almalinux:8`, and `almalinux:9`. Add a current-Ubuntu static job that runs ShellCheck and `git diff --check`.

- [ ] **Step 5: Run local release checks**

Run:

```bash
tools/build-installers.sh --check
bash tests/test_build_installers.sh
bash tests/test_v2ray_onekey_new.sh
shellcheck src/v2ray-onekey.sh.in tools/build-installers.sh tests/*.sh
git diff --check
```

Expected: all available commands PASS. If ShellCheck is unavailable locally, record that fact and require the CI static job before release.

- [ ] **Step 6: Commit fresh documentation and CI**

```bash
git add README.md .github/workflows/compatibility.yml tests/compatibility-entrypoint.sh tests/test_build_installers.sh
git commit -m "docs: document fresh multi-protocol deployment"
```

### Task 8: Fresh-Server Acceptance

**Files:**
- Modify only if acceptance reveals a defect: files named by the failing test

- [ ] **Step 1: Run all repository checks from a clean checkout**

Run:

```bash
tools/build-installers.sh --check
bash tests/test_build_installers.sh
bash tests/test_v2ray_onekey_new.sh
git diff --check
git status --short
```

Expected: all tests PASS; only intentionally untracked local attachment directories may appear.

- [ ] **Step 2: Test direct mode on a disposable supported VPS**

Run the fresh installer with `--mode direct`, open the reported TCP/UDP rules, import both links into current v2rayN, verify TCP and UDP destinations, restart the VPS, and verify both links again. Confirm `journalctl` contains no credential values.

- [ ] **Step 3: Test Cloudflare-only mode on a disposable supported VPS**

Follow the existing DNS/Nginx/Certbot procedure, import the VLESS link, verify the Cloudflare edge address, run `certbot renew --dry-run`, and confirm no Hysteria or Shadowsocks listeners exist.

- [ ] **Step 4: Test full mode on a disposable supported VPS**

Import all three links, verify each independently, stop Hysteria2 and confirm Cloudflare and Shadowsocks still work, then stop Xray and confirm Hysteria2 still works. Restore services and force a staged startup failure to verify rollback.

- [ ] **Step 5: Record acceptance in the release commit**

If no fixes were required, do not create an empty commit. If fixes were required, add a regression test first, implement the minimal correction, run the complete suite, and commit with `fix: correct fresh installer acceptance defect`.
