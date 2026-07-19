# Multi-Protocol Native Installers Design

Date: 2026-07-20
Status: Approved for specification review

## Goal

Replace the unusable VLESS REALITY entry with two independent direct entries while preserving the Cloudflare entry that is already working. The project will publish two native systemd installers:

- A fresh-server installer that can install direct entries, the existing Cloudflare entry, or all three entries.
- An upgrade installer for servers already deployed by this project that preserves the working Cloudflare configuration, removes REALITY, and adds the two new direct entries.

The resulting full deployment provides:

- VLESS + WebSocket + TLS through Cloudflare as the stable domain path.
- Hysteria2 over UDP with Salamander obfuscation and port hopping as the preferred direct path.
- Shadowsocks 2022 over TCP and UDP as a compatible direct fallback.

No protocol or script can guarantee that an IP address will never be blocked. The Cloudflare path reduces origin exposure to clients using that hostname, while both direct paths necessarily reveal the server IP to the network path.

## Deliverables

The repository will contain two standalone executable scripts under `outputs/`:

- `v2ray-onekey-new.sh`: fresh installation and intentional replacement on a new or repurposed server.
- `v2ray-onekey-upgrade-cf.sh`: conservative migration of an existing project-managed Cloudflare deployment.

They may share generated implementation during development, but each published script must run independently after download. Production deployment is native systemd only. Docker is not installed or required.

The standalone cleanup or uninstall script remains outside the GitHub deliverables, as previously requested.

## Fresh-Server Installer

Running `v2ray-onekey-new.sh` without a mode presents:

1. Direct bundle: Hysteria2 + Shadowsocks 2022; no domain required.
2. Cloudflare only: preserve the current VLESS + WebSocket + TLS design.
3. Full bundle: Cloudflare + Hysteria2 + Shadowsocks 2022; recommended.

Equivalent non-interactive modes are `--mode direct`, `--mode cloudflare`, and `--mode full`.

Domain and ACME email prompts appear only for modes containing Cloudflare. Selecting full mode must prompt for both values before validation rather than failing immediately. Direct mode never asks for a domain or email.

The fresh installer owns the complete generated Xray configuration. It may replace a project-managed configuration after creating a backup, but it must refuse to overwrite an unrelated Xray, Nginx, Hysteria2, or Shadowsocks deployment whose ownership cannot be proven.

## Existing-Cloudflare Upgrade Installer

`v2ray-onekey-upgrade-cf.sh` has one purpose and no protocol menu. It migrates the current project-managed Cloudflare deployment to the full three-entry deployment.

Before making changes it must identify and validate all of the following:

- `/etc/v2ray-onekey/state.env` is a regular, root-owned state file in the format produced by this project.
- The saved domain, email, Cloudflare UUID, WebSocket path, internal Xray port, and public Cloudflare port are valid.
- The active Xray JSON contains the matching localhost VLESS WebSocket inbound.
- The Nginx site has the project's ownership markers and routes the saved domain and WebSocket path to that inbound.
- The referenced Let's Encrypt certificate files exist.
- Xray and Nginx are active and their current configuration tests pass.

If any identity check fails, the upgrade stops before package, configuration, firewall, or service changes. It reports which check failed and points to the manual diagnostic commands. It never attempts to adopt an arbitrary third-party Nginx or Xray configuration.

On a valid deployment, the migration preserves these values exactly:

- Cloudflare domain and public port.
- ACME email and certificate paths.
- Cloudflare UUID.
- WebSocket path and internal localhost port.
- Project-owned Nginx site and renewal hook.

The Nginx site, certificates, and Cloudflare sharing link should therefore remain unchanged. The Xray configuration is re-rendered with the preserved Cloudflare inbound plus the new Shadowsocks 2022 inbound. The REALITY inbound and all REALITY sharing output are removed. The new active state omits REALITY private keys, public keys, short IDs, targets, and ports; the timestamped pre-migration backup remains available for rollback.

## Cloudflare Entry

The existing working design is intentionally unchanged:

- Protocol: VLESS.
- Transport: WebSocket.
- Public security: TLS.
- Edge: Cloudflare proxied hostname.
- Origin: Nginx using the existing Let's Encrypt certificate.
- Xray listener: generated localhost-only TCP port.
- Client output: the existing `vless://` field layout and node name.

The fresh installer retains the current Cloudflare DNS, proxy, supported HTTPS port, Nginx, Certbot, renewal-hook, edge-probe, and `Full (strict)` guidance. The implementation does not migrate this path to XHTTP or Cloudflare Tunnel in this change.

The upgrade installer never runs Certbot. A missing or invalid existing certificate is a preflight failure rather than a reason to reissue automatically. It does not rewrite a valid Nginx file merely for formatting.

## Hysteria2 Entry

Hysteria2 runs as the official standalone server binary under its own systemd service. It does not run inside Xray or Docker.

Defaults:

- Transport: UDP/QUIC.
- Authentication: a cryptographically random password.
- Obfuscation: Salamander with a separate cryptographically random password.
- Listen and hopping range: UDP `20000-20100`.
- Client hopping interval: randomized within a conservative supported range.
- TLS: a generated self-signed certificate with a generated DNS SAN.
- Client verification: `insecure=1` together with `pinSHA256`; the pin is mandatory in generated output.

Salamander is selected instead of an HTTP/3 masquerade because the official Hysteria2 documentation states that enabling obfuscation makes the endpoint incompatible with ordinary QUIC. The installer must not claim both behaviors simultaneously.

The port range is configurable through `--hy2-port-range START-END`. Interactive mode detects occupied UDP ports and asks for a replacement range. Non-interactive mode fails with the exact listener details and retry option. The range is capped at a reasonable size to avoid accidental exposure of thousands of ports.

Hysteria2's Linux port-range listener requires nftables or iptables and network-administration capability. The service runs as a dedicated unprivileged account with only the capabilities needed for low-port binding and port-hopping rules. If neither firewall backend is available, port hopping is rejected before activation rather than silently falling back to a single port.

The generated `hysteria2://` URI includes the server IP, multi-port range, authentication password, Salamander password, SNI, certificate pin, and an explicit node name. The server address can be supplied with `--server-address`; otherwise the installer discovers and validates a public IPv4 address.

## Shadowsocks 2022 Entry

Shadowsocks is implemented as an additional Xray inbound so the working Cloudflare and Shadowsocks paths share one managed Xray service without another proxy daemon.

Defaults:

- Method: `2022-blake3-aes-128-gcm`.
- Network: TCP and UDP.
- Public port: `8388`.
- Credential: a cryptographically random method-appropriate key.

The port is configurable with `--ss-port PORT`. Interactive mode offers a replacement when either TCP or UDP is occupied. Non-interactive mode reports the conflicting listener and exits before cutover.

The generated SIP002 `ss://` link includes the method, key, server IP, selected port, and node name. The installer validates the encoded link fields without printing raw credentials in test logs.

Shadowsocks 2022 adds replay protection and modern AEAD methods, but it does not look like ordinary HTTPS and must not be described as impossible to classify. It is a compatibility fallback, not an origin-hiding replacement for Cloudflare.

## Port and Firewall Behavior

Default public listeners are:

| Entry | Protocol | Default port |
| --- | --- | --- |
| Cloudflare | TCP | Existing value, or `443` on fresh install |
| Hysteria2 hopping | UDP | `20000-20100` |
| Shadowsocks 2022 | TCP and UDP | `8388` |
| ACME HTTP-01 | TCP | `80`, Cloudflare fresh install only |

TCP and UDP listeners are checked independently. A TCP service on a numeric port does not conflict with a UDP service on the same number.

When UFW or firewalld is already active, the installer adds only the selected TCP/UDP ports and ranges. It does not install a new firewall manager or replace existing policies. Cloud-provider security groups cannot be changed without provider credentials, so final output lists every external rule the user must add.

Upgrade rollback restores firewall changes made by the current run where the firewall backend supports deterministic removal. Existing rules are never removed.

## Abuse and Origin Protection

All Xray entries use a direct outbound and a blocking outbound. The generated routing policy blocks:

- Private, loopback, link-local, and metadata address ranges.
- BitTorrent by default.
- Outbound SMTP submission and relay ports `25`, `465`, and `587` by default.

Hysteria2 receives equivalent private-address and mail-port ACL rules. Its official protocol sniffer does not identify BitTorrent, so the installer must document that BitTorrent blocking is enforceable on the Xray entries but cannot be guaranteed on the independent Hysteria2 path. Generated Hysteria2 credentials therefore remain root-readable and intended for the server owner only. Explicit opt-in flags may relax Xray BitTorrent or cross-protocol mail restrictions, but defaults favor IP reputation and VPS-provider compliance.

Credentials are stored only in root-readable files. Configuration and state files use restrictive permissions, and diagnostics redact UUIDs, passwords, keys, certificate pins, and WebSocket paths. `--rotate` generates new Hysteria2 and Shadowsocks credentials. On the fresh installer it also rotates enabled Cloudflare credentials; on the upgrade installer Cloudflare rotation requires a separate explicit `--rotate-cloudflare` flag so an ordinary migration cannot invalidate the working node.

## Managed Files and Services

The deployment manages:

- `/usr/local/bin/xray` and `/usr/local/etc/xray/config.json`.
- `/usr/local/bin/hysteria` and `/etc/hysteria/config.yaml`.
- `xray.service` and a project-owned `hysteria-server.service` override or unit.
- `/etc/v2ray-onekey/state.env`, extended with a state schema version and the new entry values.
- Existing project-owned Nginx, Certbot, and renewal files when Cloudflare is enabled.
- Timestamped backups under `/var/backups/v2ray-onekey/`.

Services start automatically with systemd and restart after ordinary process failure. The service definitions must remain compatible with the tested systemd version on Ubuntu 18.04 and must not rely on directives newer than the existing cross-distribution support matrix permits.

## Transaction and Failure Handling

Both installers acquire the existing deployment lock and create a unique root-only backup before changing managed files. They stage complete configurations in a private runtime directory.

The activation order is:

1. Validate arguments, platform, ownership, addresses, and port availability.
2. Install or update required official binaries and distribution packages.
3. Generate credentials and staged configurations.
4. Validate Xray JSON, Nginx configuration when applicable, Hysteria2 configuration, state serialization, and sharing-link structure.
5. Record service enabled/active states and all managed files in the backup manifest.
6. Stop only services whose listeners must change.
7. Install staged files atomically and start or reload services.
8. Wait for expected TCP and UDP listeners and perform local protocol readiness checks.
9. For Cloudflare deployments, verify that the preserved or new edge endpoint still responds through Cloudflare.
10. Save the new state and commit the transaction.

Any failure before commit restores managed files, service enablement and activity, and current-run firewall additions. For the upgrade installer, rollback must restore the original REALITY plus Cloudflare Xray configuration so the server returns exactly to its pre-migration state.

## Output and Client Use

A successful full deployment prints three labeled import links in this order:

1. `VLESS-Cloudflare` using the preserved domain entry.
2. `Hysteria2-direct` using the public IP and UDP hopping range.
3. `Shadowsocks-2022-direct` using the public IP and TCP/UDP port.

The output also prints service status commands, required security-group rules, and the root-only state path. It does not print secrets a second time in diagnostic summaries.

The README documents import into v2rayN, notes that each client core must support the selected URI and method, and explains that a client update can change core behavior independently of the server. The Cloudflare node remains usable during direct-entry troubleshooting.

## Compatibility and Testing

The existing support matrix remains authoritative: Ubuntu 18.04/20.04/22.04/24.04, Debian 10/11/12, Rocky Linux 8/9, and AlmaLinux 8/9 on amd64 with systemd. The compatibility design and CI are updated to replace REALITY-specific smoke coverage with the new services.

Automated tests cover:

- Shell syntax, ShellCheck, and source-only behavior for both scripts.
- Fresh menu modes, prompts, command-line parsing, and domain-optional behavior.
- Upgrade ownership detection and refusal of incomplete or unmanaged deployments.
- Exact preservation of Cloudflare fields, Nginx content, certificate paths, and sharing link.
- Complete removal of REALITY from new active configurations, options, state, and output.
- Hysteria2 YAML, self-signed certificate pin, Salamander settings, port range, capabilities, and URI fields.
- Shadowsocks 2022 Xray inbound, TCP/UDP behavior, key length, and SIP002 URI fields.
- Independent TCP/UDP port conflict handling and interactive replacement.
- UFW and firewalld rules for single ports and UDP ranges.
- Xray abuse routing, Hysteria2 private-address/mail ACLs, and the documented Hysteria2 BitTorrent-classification limitation.
- Credential reuse, selective rotation, state schema migration, permissions, locking, backup, and rollback.
- Readiness timeouts and useful diagnostics for Xray, Hysteria2, Nginx, certificates, and Cloudflare edge checks.
- Native package and systemd behavior across the existing distribution matrix.

Manual release acceptance uses disposable VPS instances for both paths: one clean server and one server installed by the current Cloudflare-capable release. It imports all generated links into a current v2rayN release, verifies TCP and UDP traffic, restarts the server, exercises certificate renewal without changing the Cloudflare link, and forces a migration failure to confirm rollback.

## Non-Goals

This change does not:

- Modify the working Cloudflare protocol, Nginx topology, certificate model, or sharing-link format.
- Install Docker.
- Retain or offer VLESS REALITY.
- Add VMess, Trojan, WireGuard, public SOCKS, or public HTTP entries.
- Promise uninterrupted access, an unblocked IP, or redundancy against VPS/provider failure.
- Automatically edit cloud-provider security groups.
- Publish the previously excluded standalone cleanup script.

## Acceptance Criteria

- A clean supported server can install direct, Cloudflare-only, or full mode with the fresh installer.
- A valid project-managed Cloudflare server can run the upgrade installer without changing its working Cloudflare link.
- REALITY is absent from both new active deployments and all newly generated client output.
- Full mode produces working VLESS Cloudflare, Hysteria2, and Shadowsocks 2022 links.
- Domain and email remain optional globally and are requested only when installing Cloudflare.
- Port conflicts can be corrected interactively or through explicit flags before service cutover.
- Both installers use native systemd and fit the existing 2-core, 2-GB deployment target without Docker.
- A failed migration restores the original files and service state.
- CI and manual acceptance cover both fresh and existing-Cloudflare paths before release.

## Official References

- [Xray transport compatibility](https://xtls.github.io/en/config/transport.html)
- [Xray Shadowsocks inbound](https://xtls.github.io/en/config/inbounds/shadowsocks.html)
- [Hysteria2 full server configuration](https://v2.hysteria.network/docs/advanced/Full-Server-Config/)
- [Hysteria2 port hopping](https://v2.hysteria.network/docs/advanced/Port-Hopping/)
- [Hysteria2 URI scheme](https://v2.hysteria.network/docs/developers/URI-Scheme/)
- [Cloudflare WebSockets](https://developers.cloudflare.com/network/websockets/)
- [Cloudflare Full strict mode](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)
