# Existing Cloudflare Upgrade Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a second standalone installer that safely preserves a project-managed working Cloudflare node, removes its REALITY inbound, and adds Hysteria2 plus Shadowsocks 2022.

**Architecture:** Render the upgrade artifact from the same source template used by the fresh installer, selected by an embedded `INSTALLER_VARIANT="upgrade-cf"` constant. Give the upgrade profile a strict read-only ownership preflight and a dedicated migration entrypoint; reuse the tested configuration, state, service, firewall, and rollback primitives while never invoking the fresh Cloudflare certificate or Nginx installation path.

**Tech Stack:** Bash 4+, Python 3 JSON inspection, Xray, Hysteria2, OpenSSL, existing Nginx/Certbot, systemd, UFW/firewalld, shell test doubles, GitHub Actions.

---

## Prerequisite and File Map

Execute this plan after `2026-07-20-fresh-multi-protocol-installer.md` is complete and green.

- Modify `src/v2ray-onekey.sh.in`: add the `upgrade-cf` profile, ownership extraction, migration, and selective rotation.
- Modify `tools/build-installers.sh`: render and verify the second artifact.
- Create `outputs/v2ray-onekey-upgrade-cf.sh`: standalone existing-Cloudflare migration deliverable.
- Create `tests/test_v2ray_onekey_upgrade_cf.sh`: profile, ownership, preservation, migration, and rollback tests.
- Modify `tests/test_build_installers.sh`: require both generated outputs and no REALITY implementation.
- Modify `tests/compatibility-entrypoint.sh`: run the new suite across the approved matrix.
- Modify `README.md`: upgrade command, preflight contract, preservation guarantees, backup, and rollback diagnostics.

### Task 1: Generate the Upgrade Artifact From the Shared Template

**Files:**
- Modify: `tools/build-installers.sh`
- Modify: `tests/test_build_installers.sh`
- Create: `outputs/v2ray-onekey-upgrade-cf.sh`

- [ ] **Step 1: Extend the failing build contract**

Add to `tests/test_build_installers.sh`:

```bash
upgrade="$ROOT_DIR/outputs/v2ray-onekey-upgrade-cf.sh"
[[ -x "$upgrade" ]]
head -n 1 "$upgrade" | grep -Fqx '#!/usr/bin/env bash'
grep -Fq 'INSTALLER_VARIANT="upgrade-cf"' "$upgrade"
if grep -Fq '@INSTALLER_VARIANT@' "$upgrade"; then
  printf 'unexpanded upgrade installer variant\n' >&2
  exit 1
fi
bash -n "$upgrade"
```

- [ ] **Step 2: Run the build test and verify it fails**

Run: `bash tests/test_build_installers.sh`

Expected: FAIL because `outputs/v2ray-onekey-upgrade-cf.sh` does not exist.

- [ ] **Step 3: Generalize the renderer**

Replace the single-output render call in `tools/build-installers.sh` with:

```bash
render_variant() {
  local variant="$1" destination="$2" mode="${3:-write}" temp
  temp="$(mktemp)"
  sed "s/@INSTALLER_VARIANT@/$variant/g" "$TEMPLATE" >"$temp"
  chmod 755 "$temp"
  if [[ "$mode" == "check" ]]; then
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

build_all() {
  local mode="$1"
  render_variant new "$ROOT_DIR/outputs/v2ray-onekey-new.sh" "$mode"
  render_variant upgrade-cf "$ROOT_DIR/outputs/v2ray-onekey-upgrade-cf.sh" "$mode"
}
```

Map no argument to `build_all write` and `--check` to `build_all check`, then run `tools/build-installers.sh`.

- [ ] **Step 4: Run build checks**

Run:

```bash
bash tests/test_build_installers.sh
bash -n outputs/v2ray-onekey-upgrade-cf.sh
```

Expected: PASS.

- [ ] **Step 5: Commit the second artifact boundary**

```bash
git add tools/build-installers.sh tests/test_build_installers.sh outputs/v2ray-onekey-upgrade-cf.sh
git commit -m "build: generate cloudflare upgrade installer"
```

### Task 2: Add Strict Existing-Deployment Identification

**Files:**
- Modify: `src/v2ray-onekey.sh.in`
- Modify: `outputs/v2ray-onekey-upgrade-cf.sh`
- Create: `tests/test_v2ray_onekey_upgrade_cf.sh`

- [ ] **Step 1: Create the upgrade test harness and failing fixtures**

Source the upgrade artifact with `V2RAY_ONEKEY_SOURCE_ONLY=1`. Build one valid fixture containing:

```text
/etc/v2ray-onekey/state.env
/usr/local/etc/xray/config.json
/etc/nginx/conf.d/v2ray-onekey.conf
/etc/letsencrypt/live/vpn.example.com/fullchain.pem
/etc/letsencrypt/live/vpn.example.com/privkey.pem
```

Use test-root environment overrides for every path. The state fixture must contain a current `dual` deployment with a Cloudflare UUID/path/internal port plus REALITY fields. Assert `inspect_existing_cloudflare` returns success and extracts the Cloudflare values.

Add one failing fixture per condition: missing state, unsafe state permissions, invalid UUID, missing WebSocket inbound, mismatched path, unmanaged Nginx marker, missing certificate, failed `xray run -test`, failed `nginx -t`, inactive Xray, and inactive Nginx. Assert no package, firewall, stop, or file-write event occurs after each rejection.

- [ ] **Step 2: Run the upgrade tests and verify they fail**

Run: `tools/build-installers.sh && bash tests/test_v2ray_onekey_upgrade_cf.sh`

Expected: FAIL because `inspect_existing_cloudflare` is undefined.

- [ ] **Step 3: Implement profile-specific argument parsing**

At entrypoint dispatch use:

```bash
case "$INSTALLER_VARIANT" in
  new) main_new "$@" ;;
  upgrade-cf) main_upgrade_cf "$@" ;;
  *) die "Unknown installer variant: $INSTALLER_VARIANT" ;;
esac
```

The upgrade parser accepts only:

```text
--hy2-port-range START-END
--ss-port PORT
--server-address ADDRESS
--rotate
--rotate-cloudflare
--allow-bittorrent
--allow-mail
--help
```

Reject `--mode`, `--domain`, `--email`, `--cloudflare-port`, and `--ws-path` with `This value is read from the existing managed Cloudflare deployment`.

- [ ] **Step 4: Implement non-executing state and JSON inspection**

Load only allowlisted schema-1/schema-2 keys using the existing state parser. Validate ownership with `stat`, requiring UID 0 and no group/other write bit.

Use Python to inspect Xray JSON and emit tab-separated, non-secret field names and values for exactly one inbound matching:

```python
item["protocol"] == "vless"
item["listen"] in ("127.0.0.1", "::1")
item["streamSettings"]["network"] == "ws"
item["streamSettings"]["security"] == "none"
```

Require its UUID, path, and port to equal the saved values. Reuse `current_nginx_config_is_project_owned` and additionally require the domain/path/upstream tuple to match. Validate certificate files as regular files before service checks.

- [ ] **Step 5: Run ownership tests**

Run: `tools/build-installers.sh && bash tests/test_v2ray_onekey_upgrade_cf.sh`

Expected: every valid fixture passes; every invalid fixture stops before the first mutation event and prints the exact failed check.

- [ ] **Step 6: Commit strict preflight**

```bash
git add src/v2ray-onekey.sh.in outputs/v2ray-onekey-upgrade-cf.sh tests/test_v2ray_onekey_upgrade_cf.sh
git commit -m "feat: validate existing cloudflare ownership"
```

### Task 3: Preserve Cloudflare While Rendering the New Active State

**Files:**
- Modify: `src/v2ray-onekey.sh.in`
- Modify: `outputs/v2ray-onekey-upgrade-cf.sh`
- Modify: `tests/test_v2ray_onekey_upgrade_cf.sh`

- [ ] **Step 1: Add failing preservation and migration tests**

Before migration, capture:

```bash
nginx_before="$(sha256sum "$NGINX_SITE" | awk '{print $1}')"
hook_before="$(sha256sum "$RENEWAL_HOOK" | awk '{print $1}')"
cloudflare_link_before="$(make_cloudflare_link)"
```

After migration assert all three are identical. Parse the new Xray JSON and assert it contains exactly the preserved `cloudflare-ws-in` and new `shadowsocks-2022-in` inbounds, with no REALITY inbound. Parse the new state and assert no key name contains `REALITY`, `X25519`, `SHORT_ID`, or `TARGET`.

- [ ] **Step 2: Run tests and verify they fail**

Run: `tools/build-installers.sh && bash tests/test_v2ray_onekey_upgrade_cf.sh`

Expected: FAIL because the upgrade migration path is not implemented.

- [ ] **Step 3: Freeze existing Cloudflare values before generating direct credentials**

Add:

```bash
freeze_existing_cloudflare() {
  MODE="full"
  PRESERVED_DOMAIN="$DOMAIN"
  PRESERVED_EMAIL="$EMAIL"
  PRESERVED_CLOUDFLARE_PORT="$CLOUDFLARE_PORT"
  PRESERVED_CLOUDFLARE_UUID="$CLOUDFLARE_UUID"
  PRESERVED_WS_PATH="$WS_PATH"
  PRESERVED_INTERNAL_WS_PORT="$INTERNAL_WS_PORT"
  PRESERVED_NGINX_SHA256="$(sha256_file "$NGINX_SITE")"
  PRESERVED_HOOK_SHA256="$(sha256_file "$RENEWAL_HOOK")"
}
```

After all generation, call `assert_preserved_cloudflare_values` before staging and again after activation. Any mismatch calls `die` while the transaction trap is active.

- [ ] **Step 4: Render only Xray, Hysteria2, and schema-2 state**

Use the full-mode renderers from the fresh installer, passing the frozen Cloudflare values and new/reused direct credentials. Do not call `render_nginx_site`, `request_certificate`, `create_renewal_hook`, or any package function that installs Nginx/Certbot.

After writing state, explicitly verify:

```bash
! grep -Eiq 'REALITY|X25519|SHORT_ID|REALITY_TARGET' "$STATE_FILE"
[[ "$(sha256_file "$NGINX_SITE")" == "$PRESERVED_NGINX_SHA256" ]]
[[ "$(sha256_file "$RENEWAL_HOOK")" == "$PRESERVED_HOOK_SHA256" ]]
```

- [ ] **Step 5: Run preservation tests**

Run: `tools/build-installers.sh && bash tests/test_v2ray_onekey_upgrade_cf.sh`

Expected: Cloudflare field/link/hash preservation and REALITY-removal tests PASS.

- [ ] **Step 6: Commit migration rendering**

```bash
git add src/v2ray-onekey.sh.in outputs/v2ray-onekey-upgrade-cf.sh tests/test_v2ray_onekey_upgrade_cf.sh
git commit -m "feat: preserve cloudflare during direct upgrade"
```

### Task 4: Make Upgrade Cutover and Rollback Atomic

**Files:**
- Modify: `src/v2ray-onekey.sh.in`
- Modify: `outputs/v2ray-onekey-upgrade-cf.sh`
- Modify: `tests/test_v2ray_onekey_upgrade_cf.sh`

- [ ] **Step 1: Add failing cutover and forced-failure tests**

Build a service log and force failures at: Hysteria binary validation, Xray config test, Hysteria startup, Xray restart, listener readiness, state save, firewall update, and Cloudflare edge verification. For every case assert:

```bash
assert_file_equals "$ORIGINAL_XRAY" "$XRAY_CONFIG"
assert_file_equals "$ORIGINAL_STATE" "$STATE_FILE"
assert_eq "$ORIGINAL_XRAY_ACTIVE" "$(service_active xray)" "Xray activity"
assert_eq "$ORIGINAL_NGINX_ACTIVE" "$(service_active nginx)" "Nginx activity"
assert_eq "$ORIGINAL_XRAY_ENABLED" "$(service_enabled xray)" "Xray enablement"
assert_eq "$ORIGINAL_NGINX_ENABLED" "$(service_enabled nginx)" "Nginx enablement"
```

Also assert Nginx is never stopped or reloaded during a successful migration.

- [ ] **Step 2: Run rollback tests and verify they fail**

Run: `tools/build-installers.sh && bash tests/test_v2ray_onekey_upgrade_cf.sh`

Expected: FAIL because upgrade-specific transaction ordering is absent.

- [ ] **Step 3: Implement the upgrade transaction order**

Add `deploy_upgrade_cf` with these calls:

```bash
inspect_existing_cloudflare
acquire_deployment_lock
begin_transaction
freeze_existing_cloudflare
backup_managed_files_and_services
install_direct_dependencies
generate_direct_credentials
stage_upgrade_configurations
validate_staged_configurations
stop_xray_for_cutover
install_staged_xray_and_hysteria
systemctl daemon-reload
systemctl enable --now hysteria-server
systemctl restart xray
verify_mode_services
assert_preserved_cloudflare_values
save_state
configure_firewall
check_cloudflare_edge
print_upgrade_summary
complete_transaction
```

Do not stop, start, reload, enable, disable, or daemon-reload Nginx. Back it up for evidence and rollback only; its file hashes must remain unchanged.

- [ ] **Step 4: Restore the original REALITY+Cloudflare state on failure**

Before cutover, include the original Xray JSON and schema-1 state in the backup manifest. Rollback stops new Xray/Hysteria listeners, restores files atomically, restores service enablement, restarts the original Xray, and leaves Nginx running. Remove only current-run firewall additions.

- [ ] **Step 5: Run all forced-failure tests**

Run: `tools/build-installers.sh && bash tests/test_v2ray_onekey_upgrade_cf.sh`

Expected: each forced failure restores original hashes and service state; successful migration never records an Nginx service mutation.

- [ ] **Step 6: Commit atomic upgrade lifecycle**

```bash
git add src/v2ray-onekey.sh.in outputs/v2ray-onekey-upgrade-cf.sh tests/test_v2ray_onekey_upgrade_cf.sh
git commit -m "feat: make cloudflare upgrade transactional"
```

### Task 5: Add Selective Rotation, Output, and User Guidance

**Files:**
- Modify: `src/v2ray-onekey.sh.in`
- Modify: `outputs/v2ray-onekey-upgrade-cf.sh`
- Modify: `tests/test_v2ray_onekey_upgrade_cf.sh`
- Modify: `README.md`

- [ ] **Step 1: Add failing rotation and summary tests**

Assert default migration reuses Cloudflare UUID/path and generates missing Hysteria2/Shadowsocks credentials. Assert `--rotate` changes only Hysteria2 auth/obfs/certificate and Shadowsocks key. Assert `--rotate-cloudflare` changes UUID/path only after printing an invalidation warning and requiring `--yes` in non-interactive use.

Assert successful output prints the unchanged Cloudflare link first, then Hysteria2 and Shadowsocks links, backup path, state path, service diagnostics, and exact TCP/UDP security-group rules.

- [ ] **Step 2: Run tests and verify they fail**

Run: `tools/build-installers.sh && bash tests/test_v2ray_onekey_upgrade_cf.sh`

Expected: FAIL in rotation or summary assertions.

- [ ] **Step 3: Implement selective rotation**

Use:

```bash
if [[ "$ROTATE" == "1" ]]; then
  HY2_AUTH=""
  HY2_OBFS_PASSWORD=""
  HY2_SNI=""
  HY2_CERT_PIN=""
  SS_KEY=""
fi

if [[ "$ROTATE_CLOUDFLARE" == "1" ]]; then
  confirm_destructive_rotation
  CLOUDFLARE_UUID=""
  WS_PATH=""
fi
```

When Cloudflare rotation is selected, regenerate and atomically update Xray plus the project-owned Nginx route; issue no certificate and preserve domain/port/certificate paths. This is the only upgrade path allowed to alter the Cloudflare link.

- [ ] **Step 4: Implement the upgrade summary**

Label the preserved link `Existing Cloudflare entry (unchanged)` and direct links `New Hysteria2 direct entry` and `New Shadowsocks 2022 direct entry`. Never print retired REALITY credentials from the backup or old state.

- [ ] **Step 5: Document the exact upgrade command and safeguards**

Add to README:

```bash
sudo bash outputs/v2ray-onekey-upgrade-cf.sh
sudo bash outputs/v2ray-onekey-upgrade-cf.sh --hy2-port-range 21000-21100 --ss-port 8488
```

Document that this script accepts only deployments managed by this repository, preserves the Cloudflare link by default, never reissues its certificate, backs up the old REALITY+Cloudflare configuration, and restores it if migration fails.

- [ ] **Step 6: Run upgrade and documentation tests**

Run:

```bash
tools/build-installers.sh
bash tests/test_build_installers.sh
bash tests/test_v2ray_onekey_new.sh
bash tests/test_v2ray_onekey_upgrade_cf.sh
git diff --check
```

Expected: all tests PASS and no diff whitespace errors.

- [ ] **Step 7: Commit rotation and guidance**

```bash
git add src/v2ray-onekey.sh.in outputs/v2ray-onekey-upgrade-cf.sh tests/test_v2ray_onekey_upgrade_cf.sh README.md
git commit -m "docs: add safe cloudflare upgrade workflow"
```

### Task 6: Matrix and Disposable-VPS Acceptance

**Files:**
- Modify: `tests/compatibility-entrypoint.sh`
- Modify: `.github/workflows/compatibility.yml`
- Modify only after a failing acceptance check: the file responsible for that defect

- [ ] **Step 1: Add the upgrade suite to every compatibility row**

Append to `tests/compatibility-entrypoint.sh`:

```bash
bash -n outputs/v2ray-onekey-upgrade-cf.sh
bash tests/test_v2ray_onekey_upgrade_cf.sh
```

Keep Ubuntu 18.04 and Rocky/Alma rows required so state parsing, native awk behavior, systemd directives, and package mappings remain covered.

- [ ] **Step 2: Run the complete local suite**

Run:

```bash
tools/build-installers.sh --check
bash tests/test_build_installers.sh
bash tests/test_v2ray_onekey_new.sh
bash tests/test_v2ray_onekey_upgrade_cf.sh
shellcheck src/v2ray-onekey.sh.in tools/build-installers.sh tests/*.sh
git diff --check
```

Expected: all available checks PASS. CI must supply the ShellCheck result if it is unavailable locally.

- [ ] **Step 3: Install the current release on a disposable VPS**

Use the current pre-migration installer to create a working Cloudflare plus REALITY deployment. Import and test the Cloudflare link, save hashes of state/Xray/Nginx/renewal files, and record service states.

- [ ] **Step 4: Run the upgrade artifact on that VPS**

Run `sudo bash outputs/v2ray-onekey-upgrade-cf.sh`, compare the Cloudflare link and Nginx/renewal hashes, import the two new links into current v2rayN, and verify all three entries independently. Confirm the active state and Xray config contain no REALITY fields.

- [ ] **Step 5: Exercise rollback on a second disposable copy**

Occupy the selected Hysteria2 range or force Hysteria startup failure after staging. Verify the old Cloudflare and REALITY links work after rollback, original file hashes match, and no new firewall rules remain.

- [ ] **Step 6: Commit matrix wiring or regression corrections**

```bash
git add tests/compatibility-entrypoint.sh .github/workflows/compatibility.yml
git commit -m "ci: test cloudflare upgrade path"
```

For an acceptance defect, first add a reproducing shell test, implement the minimal fix, run the complete suite, and commit with `fix: correct cloudflare migration acceptance defect`.
