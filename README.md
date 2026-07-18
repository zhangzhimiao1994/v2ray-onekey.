# V2Ray One-Key Installer

面向 Linux 服务器的原生 Xray 一键部署脚本，支持三种安装模式：

- `reality`：直连 `VLESS + REALITY + XTLS Vision`，不需要域名。
- `cloudflare`：可选的 `VLESS + WebSocket + TLS`，需要已托管到 Cloudflare 的域名。
- `dual`：同时安装上述两套入口。直连不可用时，可切换 Cloudflare 入口。

> [!WARNING]
> 没有任何协议或脚本能保证 IP、域名永远不会被封锁。本方案通过减少直连入口的明显特征并提供备用路径来改善稳定性，但不能消除网络封锁、机房故障或服务商限制。

## 系统要求

- `root` 权限，以及使用 `systemd` 的 Linux 服务器。
- 系统提供 `apt`、`dnf` 或 `yum` 包管理器。
- 服务器至少有一个可从客户端访问的公网 IPv4 或 IPv6 地址。
- 云服务商安全组和服务器防火墙允许所选 TCP 端口。
- Cloudflare 模式还需要域名、有效邮箱，以及指向本机的 DNS 记录。

脚本直接安装 Xray、Nginx、Certbot 并创建 systemd 服务。部署服务器不需要 Docker；Docker 仅供维护者运行测试。

## 快速部署

交互式选择模式：

```bash
sudo bash outputs/v2ray-onekey.sh
```

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

## Cloudflare 配置

域名不是必需项。只使用 REALITY 时跳过本节；选择 `cloudflare` 或 `dual` 时，按以下步骤配置。

1. 在 Cloudflare DNS 中添加 `A` 记录，例如 `vpn.example.com` 指向 VPS 公网 IPv4。只有源站确实具备可用公网 IPv6 时才添加 `AAAA` 记录。
2. 将该主机名的 Proxy status 设置为橙色云朵，即 **Proxied**。
3. 在 **Network > WebSockets** 中开启 WebSockets。
4. 在 **SSL/TLS** 中将加密模式设为 **Full (strict)**。
5. 在云安全组和服务器防火墙放行源站端口：`cloudflare` 模式放行 TCP `80`、`443`；`dual` 模式放行 TCP `80`、`443`、`8443`。使用自定义端口时按实际值放行。
6. 双入口模式中，REALITY 默认通过服务器 IP 和 `443` 直连，不能放到 Cloudflare 代理后面；Cloudflare 仅代理域名对应的 WebSocket + TLS 入口。

Let's Encrypt 使用 HTTP-01 验证，因此 TCP `80` 必须能从公网访问。如果域名开启代理后证书签发失败，可先将该 DNS 记录临时切换为 **DNS only**，重新运行脚本；签发成功后再恢复橙色云朵。

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
- [Cloudflare WebSockets](https://developers.cloudflare.com/network/websockets/)
- [Cloudflare Full (strict)](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)
