# V2Ray One-Key Installer

## Installers

The repository provides two native systemd installers. Docker is only used for
local tests and is not installed on the VPS.

```bash
sudo bash outputs/v2ray-onekey-new.sh
sudo bash outputs/v2ray-onekey-upgrade-cf.sh
```

The first command installs a new direct/full deployment. The second command
accepts only a Cloudflare deployment previously managed by this repository. It
reads the existing domain, email, port, UUID, WebSocket path, Nginx site,
renewal hook, and certificate paths. By default it preserves the Cloudflare
link and those files byte-for-byte, removes the old REALITY inbound from active
Xray state, and adds Hysteria2 plus Shadowsocks 2022. Use `--rotate` only for
the new direct credentials. The old Xray/state files are backed up before any
package, service, firewall, or configuration mutation; failures restore the
previous deployment automatically.

面向 Linux 服务器的原生 Xray 一键部署脚本，支持三种安装模式：

- `reality`：直连 `VLESS + REALITY + XTLS Vision`，不需要域名。
- `cloudflare`：可选的 `VLESS + WebSocket + TLS`，需要已托管到 Cloudflare 的域名。
- `dual`：同时安装上述两套入口。直连不可用时，可切换 Cloudflare 入口。

> [!WARNING]
> 没有任何协议或脚本能保证 IP、域名永远不会被封锁。本方案通过减少直连入口的明显特征并提供备用路径来改善稳定性，但不能消除网络封锁、机房故障或服务商限制。

## 系统要求

- `root` 权限，以及使用 `systemd` 的 Linux 服务器。
- 系统提供 `apt`、`dnf` 或 `yum` 包管理器。
- `reality` 和 `dual` 模式需要可从客户端访问的公网 IPv4；当前脚本使用仅支持 IPv4 的地址发现服务生成 REALITY 导入链接。
- `cloudflare` 模式可以使用工作正常的源站公网 IPv4 或 IPv6，并配置对应的 `A` 或 `AAAA` 记录。
- 云服务商安全组和服务器防火墙允许所选 TCP 端口。
- Cloudflare 模式还需要域名、有效邮箱，以及指向本机的 DNS 记录。

脚本直接安装 Xray、Nginx、Certbot 并创建 systemd 服务。部署服务器不需要 Docker；Docker 仅供维护者运行测试。

## 快速部署

在新 VPS 上先克隆项目。仓库名末尾确实包含一个点，以下 HTTPS 地址和目录名中的两个点及末尾点都不能省略：

```bash
git clone https://github.com/zhangzhimiao1994/v2ray-onekey..git
cd 'v2ray-onekey.'
```

如果系统尚未安装 `git`，请先使用系统的 `apt`、`dnf` 或 `yum` 安装。进入项目目录后再运行以下命令。

交互式选择模式：

```bash
sudo bash outputs/v2ray-onekey.sh
```

选择 `2) Cloudflare only` 或 `3) Dual entry` 后，脚本会继续询问已开启 Cloudflare 代理的完整域名（例如 `vpn.example.com`）和 Let's Encrypt 证书通知邮箱。选择 `1) Direct only` 不需要域名。

只安装无域名的 REALITY 入口：

```bash
sudo bash outputs/v2ray-onekey.sh --mode reality
```

只安装 Cloudflare 域名入口：

```bash
sudo bash outputs/v2ray-onekey.sh --mode cloudflare --domain vpn.example.com --email admin@example.com
```

同时安装两套入口：

```bash
sudo bash outputs/v2ray-onekey.sh --mode dual --domain vpn.example.com --email admin@example.com
```

安装完成后，脚本会输出每个入口对应的 `vless://` 导入链接。请妥善保管，其中包含客户端凭据。

## 端口规划

| 模式 | 默认公网 TCP 端口 | 用途 |
| --- | --- | --- |
| `reality` | `443` | VLESS REALITY 直连 |
| `cloudflare` | `80`、`443` | Let's Encrypt HTTP-01、Cloudflare TLS 回源 |
| `dual` | `80`、`443`、`8443` | HTTP-01、REALITY 直连、Cloudflare TLS 回源 |

可使用 `--reality-port` 修改 REALITY 端口，使用 `--cloudflare-port` 修改 Cloudflare TLS 公网端口。例如：

```bash
sudo bash outputs/v2ray-onekey.sh --mode dual --domain vpn.example.com --email admin@example.com --reality-port 10443 --cloudflare-port 8443
```

Cloudflare 代理支持的 HTTPS 公网端口仅限 `443`、`2053`、`2083`、`2087`、`2096`、`8443`。端口冲突处理规则如下：

- 交互式运行时，脚本会提示输入替代端口。
- 非交互式运行时，脚本会显示完整的 `ss -lntp` 监听信息和准确的重试参数。
- Xray 使用的内部 WebSocket 端口若被占用，会自动重新选择，不需要在安全组中开放。
- 无关 Nginx 站点可以共享 `80` 或 Cloudflare TLS 端口，前提是域名不同。
- 相同域名与端口的 Nginx 配置会被拒绝，避免证书签发或流量路由到错误站点。
- REALITY 是独立 TCP 入口，不能与 Nginx 共享同一个端口。

## REALITY 目标站点

`--reality-target HOST:PORT` 用于设置 REALITY 握手的目标 HTTPS 站点，默认值是 `www.microsoft.com:443`。安装器会从 VPS 探测该目标是否可达。

请选择服务器能够稳定访问的普通 HTTPS 站点，优先考虑与 VPS 位于同一 ASN 或邻近网络、且没有使用 Cloudflare 代理的站点。例如：

```bash
sudo bash outputs/v2ray-onekey.sh --mode reality --reality-target www.apple.com:443
```

目标站点需要按 VPS 所在网络实际测试和选择；它只是 REALITY 配置的一部分，不能保证 IP 或连接不会被封锁。

## Cloudflare 配置

域名不是必需项。只使用 REALITY 时跳过本节；选择 `cloudflare` 或 `dual` 时，按以下步骤配置。

1. 在 Cloudflare DNS 中添加 `A` 记录，例如 `vpn.example.com` 指向 VPS 公网 IPv4。只有源站确实具备可用公网 IPv6 时才添加 `AAAA` 记录。
2. 将该主机名的 Proxy status 设置为橙色云朵，即 **Proxied**。
3. 在 **Network > WebSockets** 中开启 WebSockets。
4. 在 **SSL/TLS** 中将加密模式设为 **Full (strict)**。
5. TCP `80` 必须保持公网可达，供 Let's Encrypt HTTP-01 验证使用。Cloudflare TLS 回源端口（默认 `443` 或 `8443`）在条件允许时，建议在云安全组或服务商防火墙中仅允许 [Cloudflare 官方当前 IP 段](https://www.cloudflare.com/ips/) 访问，降低绕过 Cloudflare 直连源站的风险。
6. `cloudflare` 模式需要开放 TCP `80` 和 `443`；`dual` 模式需要开放 TCP `80`、`443` 和 `8443`。使用自定义端口时按实际值配置。REALITY 端口必须保持公网直连，不能限制为仅 Cloudflare 来源。
7. 双入口模式中，REALITY 默认通过服务器 IP 和 `443` 直连，不能放到 Cloudflare 代理后面；Cloudflare 仅代理域名对应的 WebSocket + TLS 入口。

Let's Encrypt 使用 HTTP-01 验证，因此 TCP `80` 必须能从公网访问。证书签发失败时请保持 **Proxied**，检查 DNS 是否已生效、TCP `80` 是否放行，以及 Cloudflare WAF/重定向规则是否拦截 `/.well-known/acme-challenge/`；修正后再运行脚本。安装器会在签发前验证域名仍通过 Cloudflare 代理，因此不要切到 **DNS only** 后直接重跑。

安装器仅在检测到 UFW 或 firewalld 已处于活动状态时，自动放行所选本机端口。云服务商安全组、服务商防火墙及其来源 IP 限制仍需用户自行配置和维护；Cloudflare IP 段可能更新，防火墙规则应始终以官方当前列表为准。

## 导入客户端

### v2rayN

1. 在 v2rayN 中选择 **Xray core**。
2. 复制脚本输出的一个 `vless://` 链接。
3. 使用“从剪贴板导入批量 URL”导入；双入口模式会输出两条链接，可分别命名并测试延迟。

V2Fly core 不实现 REALITY，不能用于 REALITY 链接。手机端客户端也必须支持 VLESS REALITY；使用 Cloudflare 入口时还需支持 VLESS WebSocket + TLS。

## 重复运行与凭据

重复运行脚本默认复用已有 UUID、REALITY 密钥和路径，避免已导入的链接无故失效。需要主动更换全部凭据时添加 `--rotate`：

```bash
sudo bash outputs/v2ray-onekey.sh --mode dual --domain vpn.example.com --email admin@example.com --rotate
```

`--rotate` 会使旧链接立即失效，需要把新链接重新导入所有客户端。

- 状态文件：`/etc/v2ray-onekey/state.env`，仅 `root` 可读。
- 事务备份：`/var/backups/v2ray-onekey/`。

## BitTorrent

BitTorrent 默认被阻止，以降低服务器被滥用、投诉或封禁的风险。确有授权用途时可添加 `--allow-bittorrent`，但你需要自行承担流量、版权投诉和服务商封禁风险。

## 故障排查

```bash
systemctl status xray
journalctl -u xray -e
nginx -t
certbot renew --dry-run
ss -lntp
```

优先确认 Xray 是否启动、Nginx 配置是否有效、证书能否续期，以及安全组与本机监听端口是否一致。Cloudflare 入口异常时，再检查 DNS 是否指向当前服务器、橙色云朵、WebSockets 和 Full (strict) 是否已启用。

## 信任与可用性边界

- Cloudflare 在边缘终止 TLS，因此能够观察 WebSocket 流量；它不是端到端不可见的中继。
- 双入口部署在同一台 VPS 上，只提供网络路径冗余，不提供主机或云服务商级冗余。
- REALITY 直连模式会向连接方和网络路径暴露源站 IP。
- 协议、IP 信誉、服务器 ASN、流量行为和当地网络策略都会影响实际可用性。

请仅在你有权管理的服务器和网络上使用本项目，并遵守当地法律与服务商条款。

## 官方参考

- [XTLS REALITY 配置](https://xtls.github.io/en/config/transports/reality.html)
- [Xray 官方安装脚本](https://github.com/XTLS/Xray-install)
- [Cloudflare 支持的网络端口](https://developers.cloudflare.com/fundamentals/reference/network-ports/)
- [Cloudflare IP 地址与源站访问控制](https://developers.cloudflare.com/fundamentals/concepts/cloudflare-ip-addresses/)
- [Cloudflare WebSockets](https://developers.cloudflare.com/network/websockets/)
- [Cloudflare Full (strict)](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)
