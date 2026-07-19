# Cross-Distribution Compatibility Design

Date: 2026-07-19
Status: Approved for specification review

## Goal

Prevent installer releases from depending accidentally on one recent Bash, awk, Python, package-manager, or service-manager implementation. Compatibility must be demonstrated by repeatable tests before a change is considered releasable.

No project can guarantee compatibility with every Linux distribution and derivative. This design defines an explicit amd64 server support matrix and treats systems outside it as unverified rather than silently claiming support.

## Supported Matrix

The automated userland matrix covers:

| Family | Releases | Package manager | Support class |
| --- | --- | --- | --- |
| Ubuntu | 18.04, 20.04, 22.04, 24.04 | `apt` | Tested; 18.04 is legacy compatibility |
| Debian | 10, 11, 12 | `apt` | Tested; 10 is legacy compatibility |
| Rocky Linux | 8, 9 | `dnf`/`yum` | Tested |
| AlmaLinux | 8, 9 | `dnf`/`yum` | Tested |

Legacy compatibility means the script remains tested against the distribution's original userland, but the project does not recommend a release that no longer receives ordinary vendor security maintenance. Repository retirement, broken third-party mirrors, and unavailable vendor packages are reported clearly and are not hidden by silently substituting unrelated packages.

Alpine, OpenWrt, Arch Linux, NixOS, non-systemd systems, and non-amd64 architectures are outside the first formal matrix. Their use must not be described as supported until a corresponding automated job exists.

## Test Layers

### Per-Commit Userland Matrix

Every push to `main` and every pull request runs the complete shell test suite inside each matrix image. The GitHub job runs Docker on the hosted runner and mounts the checked-out repository into the selected image. GitHub JavaScript actions do not execute inside legacy containers, avoiding Node and old-glibc incompatibilities unrelated to the installer.

Each image uses its native package manager and default command implementations. A small POSIX-shell entrypoint installs only the test dependencies required by that family, then runs:

- `bash -n` on the installer and tests.
- The complete `tests/test_v2ray_onekey.sh` suite.
- Package mapping checks for `apt`, `dnf`, and `yum`.
- Parsing tests for LF and CRLF command output.
- State round-trip, permissions, rollback, mode, port, Nginx ownership, and firewall behavior tests.
- SELinux detection, permission-change, and rollback tests for Cloudflare mode.
- A concise environment report containing distribution, Bash, awk, and Python versions.

The matrix must use the distribution's default awk implementation where practical. This is required to catch differences such as Ubuntu 18.04 `mawk` behavior instead of replacing every environment with GNU awk.

### Static Analysis

A separate current-toolchain job runs ShellCheck at warning severity and `git diff --check`. Static analysis runs once rather than once per distribution because its purpose is source analysis, not userland compatibility.

### Service Smoke Tests

Three representative environments exercise the native service installation path:

- Ubuntu 18.04 for legacy Bash, awk, Python, apt, and systemd behavior.
- Ubuntu 24.04 for the current Ubuntu stack.
- Rocky Linux 9 for the RPM, dnf, and firewalld family.

These jobs run on a schedule and through `workflow_dispatch` because they download upstream packages and exercise privileged service boundaries. They run in disposable environments, install the current official Xray release, render REALITY-only configuration, validate it with the real Xray binary, install service files, and verify expected listeners and permissions. They never modify a persistent host.

If hosted privileged containers cannot reproduce a distribution's systemd behavior reliably, that row remains a required manual disposable-VM test until a dedicated ephemeral runner is available. It must not be reported as an automated pass.

SELinux enforcement is tested separately on an ephemeral Rocky or Alma VM with SELinux genuinely in `Enforcing` mode. Cloudflare mode requires Nginx to connect to the generated localhost Xray port. The installer must detect this condition, make the required SELinux permission change explicitly, record the previous value, and restore it during rollback. A container running with SELinux disabled cannot satisfy this check and must not report it as passed.

### Cloudflare Acceptance

Real Cloudflare and Let's Encrypt validation remains a documented manual release check because it requires a delegated public hostname, public ports, and mutable external account state. Automated tests still validate generated Nginx configuration, WebSocket routing, certificate command construction, Cloudflare port restrictions, and transaction rollback.

The manual acceptance check verifies:

- Proxied A or AAAA resolution.
- HTTP-01 certificate issuance and renewal dry run.
- Cloudflare `Full (strict)` origin connection.
- WebSocket upgrade to the generated path.
- Import and connection through the generated `vless://` link.

## Workflow Structure

The repository adds:

- `.github/workflows/compatibility.yml` for per-commit matrix and static checks.
- `.github/workflows/service-smoke.yml` for scheduled and manually dispatched service tests.
- `tests/compatibility-entrypoint.sh` for native dependency bootstrap and the common matrix test sequence.
- `tests/service-smoke.sh` for disposable native service verification.

The scripts are directly runnable by maintainers outside GitHub Actions. CI YAML remains orchestration only; distro logic belongs in versioned test scripts so local and hosted results use the same behavior.

## Failure Policy

A change is not release-ready when any required per-commit matrix row or static-analysis job fails. A failure caused by a retired distribution repository is still visible and blocks claiming that row as currently tested until the support policy is updated explicitly.

Scheduled service-smoke failures open a maintenance signal and block the next release, but do not retroactively alter already published commits. Cloudflare manual acceptance is required before a tagged release that changes the Cloudflare path, Nginx template, certificate flow, or sharing-link construction.

Tests must not print generated private keys, UUIDs, account email addresses, or Cloudflare credentials. Diagnostic output may include labels, lengths, versions, ports, and redacted configuration structure.

## Documentation

README gains a support table that distinguishes tested, legacy-compatible, and unverified systems. It also explains that successful userland CI does not prove a vendor mirror is still available or that every cloud provider permits the required ports.

When a compatibility defect is fixed, the regression test must preserve the original distribution-specific input or behavior. The Ubuntu 18.04 CRLF/`mawk` key-parsing case is the first required example.

## Acceptance Criteria

- Every supported matrix row runs automatically on pull requests and pushes to `main`.
- Ubuntu 18.04 executes the CRLF X25519 parsing regression with its native awk and Bash.
- Debian-family and RPM-family dependency bootstrap paths are both exercised.
- Static analysis and the full existing suite remain required checks.
- Representative service-smoke scripts are repeatable in disposable environments and never require production credentials.
- Cloudflare mode is verified with SELinux enforcing, including rollback of any persistent permission change.
- README states the exact support scope and does not claim universal Linux compatibility.
- CI logs contain no generated deployment secrets.
