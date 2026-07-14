# V2Ray One-Key Installer

Linux one-key deployment script for V2Ray VMess.

## Usage

No-domain TCP mode:

```bash
sudo bash outputs/v2ray-onekey.sh
```

Custom port:

```bash
sudo bash outputs/v2ray-onekey.sh --port 23456
```

Optional domain mode with TLS/WebSocket:

```bash
sudo bash outputs/v2ray-onekey.sh --domain vpn.example.com --email you@example.com
```

Use only on servers and networks you are authorized to manage.
