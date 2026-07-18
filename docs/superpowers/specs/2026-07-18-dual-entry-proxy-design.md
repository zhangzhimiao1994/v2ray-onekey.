# Dual-Entry Proxy Installer Design

Date: 2026-07-18
Status: Approved for specification review

## Goal

Replace the current VMess-over-plain-TCP default with a more resilient Xray deployment while keeping domain use optional. The installer must support a direct entry, a Cloudflare-proxied entry, or both on one Linux server.

No transport can guarantee that an IP address or hostname will never be blocked. The design reduces protocol exposure and provides an alternate path when direct access is disrupted.

## User-Facing Modes

Running the script without `--mode` shows this menu:

1. Direct only: VLESS + REALITY + XTLS Vision. No owned domain is required.
2. Cloudflare only: VLESS + WebSocket + TLS through a proxied Cloudflare hostname.
3. Dual entry: install both. This is the default recommendation.

Non-interactive automation remains available through `--mode reality`, `--mode cloudflare`, and `--mode dual`.

The script asks for a domain and ACME email only in Cloudflare and dual modes. Existing command-line values skip the corresponding prompts.

## Port Layout

The modes use the following public TCP ports:

| Mode | Direct REALITY | Cloudflare WebSocket | ACME HTTP |
| --- | ---: | ---: | ---: |
| Direct only | 443 | Disabled | Disabled |
| Cloudflare only | Disabled | 443 | 80 |
| Dual entry | 443 | 8443 | 80 |

Port 8443 is used in dual mode because Cloudflare supports it as an HTTPS proxy port, while port 443 remains available for the direct REALITY entry. The Xray WebSocket inbound listens only on localhost on a generated high port.

Custom public ports are supported with `--reality-port` and `--cloudflare-port`. The installer rejects port collisions before making service changes.

## Architecture

### Direct Entry

Xray listens publicly using:

- Protocol: VLESS
- Transport: RAW/TCP
- Transport security: REALITY
- Flow: `xtls-rprx-vision`
- Default port: 443
- Authentication: a dedicated UUID
- Client fingerprint: Chrome-compatible uTLS

The script generates a REALITY X25519 key pair and a random short ID. Its default camouflage target is `www.microsoft.com:443`. Before using it, the script requires a successful Xray TLS probe and rejects resolved addresses inside Cloudflare's currently published IP ranges. An explicit `--reality-target` overrides the hostname but is subject to the same probe.

After the first 1 MiB in each direction, unauthenticated fallback traffic is limited to 100 KiB/s with a 1 MiB/s burst ceiling to reduce the risk that a scanned endpoint is abused as a relay.

### Cloudflare Entry

Cloudflare terminates the client-facing TLS connection and proxies a WebSocket connection to Nginx. Nginx terminates origin TLS and forwards only the generated WebSocket path to an Xray VLESS inbound bound to `127.0.0.1`.

The public endpoint uses:

- Protocol: VLESS
- Transport: WebSocket
- Edge and origin transport security: TLS
- Public port: 443 in Cloudflare-only mode, 8443 in dual mode
- Authentication: a UUID different from the REALITY UUID
- WebSocket path: a cryptographically random path

Nginx serves a small ordinary health response on all other paths. It applies conservative timeouts and WebSocket upgrade headers. Xray and Nginx use separate configuration files so either entry can be diagnosed independently.

Cloudflare mode requires the user to create an A or AAAA record for the selected hostname, point it to the server, and enable the orange-cloud proxy. Cloudflare SSL mode must be `Full (strict)`. The installer does not require or store a Cloudflare API token.

Cloudflare is a trusted intermediary in this mode because it terminates client TLS and can observe WebSocket metadata and decrypted frames at the edge. The Cloudflare entry is intended as a reachable fallback path; the direct REALITY entry remains the preferred path when end-to-end transport security to the VPS is desired. In dual mode, the direct entry also makes the origin IP public, so Cloudflare is not used to conceal the VPS address.

Let's Encrypt is used for the origin certificate through an HTTP-01 challenge on port 80. If issuance fails while the proxy is enabled, the script leaves the previous service intact and explains that the record can be temporarily changed to DNS-only before retrying. Certificate renewal is handled by the distribution's Certbot timer.

## Installation Components

The script installs and manages:

- Xray from the official XTLS installer.
- Nginx and Certbot only when Cloudflare mode is selected.
- `/usr/local/etc/xray/config.json` for Xray.
- A dedicated Nginx site file for the Cloudflare entry.
- `/etc/v2ray-onekey/state.env` with mode, generated credentials, paths, and ports, readable only by root.
- Timestamped backups under `/var/backups/v2ray-onekey/`.

The existing V2Ray configuration and any Nginx files previously created by this project are backed up before migration. Unrelated Nginx sites and firewall rules are not modified.

Rerunning the installer reuses managed credentials from the state file. A separate `--rotate` flag intentionally generates new credentials and invalidates previous import links.

## Outbound and Routing Policy

The server uses Xray's standard direct outbound and a blackhole outbound. It does not copy client-side geosite DNS routing into the server configuration.

Requests to private and link-local address ranges are blocked to prevent access to server-side metadata and internal networks. BitTorrent traffic is blocked by default to reduce abuse complaints and IP reputation damage. The explicit `--allow-bittorrent` flag disables that block for authorized environments.

## Firewall Behavior

The installer opens only the ports required by the selected mode using UFW or firewalld when either is already active. It does not replace the user's firewall framework.

Cloud-provider security-group changes cannot be automated without provider credentials. The final output lists the exact TCP ports that must be opened externally.

## Output

After a successful deployment, the script prints one import link per enabled entry:

- A `vless://` link containing the REALITY public key, short ID, SNI, fingerprint, and Vision flow.
- A `vless://` link containing the Cloudflare hostname, TLS SNI, WebSocket host, path, and public port.

The output clearly labels the direct entry as primary and the Cloudflare entry as fallback. Secrets are also retained in the root-only state file so an interrupted terminal session does not lose them.

## Failure Handling and Rollback

The installer performs package installation, certificate issuance, configuration generation, and syntax validation before disabling the old V2Ray service.

It validates Xray and Nginx configurations before restart. If validation or startup fails, it restores project-owned configuration files from the current run's backup and attempts to restore the previously active service. It reports the relevant `journalctl` command and backup directory.

Expected preflight failures include:

- Required public port already in use by an unrelated process.
- Domain does not resolve or Cloudflare proxy prerequisites are incomplete.
- ACME certificate issuance fails.
- The selected REALITY target fails TLS probing.
- The Linux distribution does not provide a supported package manager or systemd.

## Verification

Implementation verification covers:

- Shell syntax and static checks.
- Argument parsing and menu choices for all three modes.
- Xray configuration validation with Xray's test command.
- Nginx configuration validation with `nginx -t`.
- Active service checks through systemd.
- Listening-port checks for each selected mode.
- TLS and health-response checks for the Cloudflare hostname.
- Import-link field checks for both VLESS variants.
- Upgrade behavior from the repository's existing VMess configuration, including backup creation.

The README will document both interactive and non-interactive usage, Cloudflare prerequisites, client import steps, diagnostics, renewal checks, and the limitation that two entries on one VPS are path redundancy rather than server redundancy.
