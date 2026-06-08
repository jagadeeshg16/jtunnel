# jtunnel

Lightweight HTTPS tunnel — expose your local dev server to the internet over port 443 only.
Built to work inside corporate networks that block all outbound ports except 443.

---

## Architecture

```
  YOUR LAPTOP                        EC2 / VPS                        INTERNET
  ──────────                         ─────────                        ────────

  jtunnel client  ══ WSS :443 ══▶  Nginx (port 443)
  (your terminal)                      │  SSL termination
                                       │  SNI routing
                                       ▼
                                   relay (port 8080)
                                       │
                                  _tunnels dict
                               {tunnel-id: websocket}
                                       │
  localhost:3000  ◀── forward ────────┘◀─── HTTP request ──── Browser / curl
```

### Request flow

1. Browser hits `https://<hostname>-myapp.jtunnel.yourdomain.com`
2. Nginx matches subdomain, sets `X-Tunnel-Name` header, proxies to relay on `:8080`
3. Relay looks up the websocket for that tunnel ID in `_tunnels`
4. Serializes the HTTP request as JSON, sends over WebSocket to jtunnel client on your laptop
5. jtunnel forwards to `localhost:3000`, gets response, sends back over WebSocket
6. Relay reconstructs HTTP response and returns it to the browser

### Multi-tunnel routing

```
  hostname-api.jtunnel.yourdomain.com  ──▶  relay  ──▶  ws[hostname-api]  ──▶  :3000
  hostname-ui.jtunnel.yourdomain.com   ──▶  relay  ──▶  ws[hostname-ui]   ──▶  :5173
  other-app.jtunnel.yourdomain.com     ──▶  relay  ──▶  ws[other-app]     ──▶  :8080
```

Each tunnel is a separate WebSocket connection. Nginx extracts the subdomain and passes it as
`X-Tunnel-Name`; the relay routes to the right client.

---

## Setup

### Requirements

- EC2 / VPS with Ubuntu 22.04+
- A domain with a wildcard A record pointing to your VPS: `*.jtunnel.yourdomain.com → <VPS IP>`
- Python 3.10+ on both VPS and laptop

### VPS one-time setup

```bash
git clone https://github.com/jagadeeshg16/jtunnel.git
cd jtunnel
sudo python3 relay --setup --nginx --domain jtunnel.yourdomain.com
```

This will:
- Install nginx + certbot
- Generate a self-signed wildcard cert (fallback for uncertified tunnels)
- Get a real Let's Encrypt cert for the base domain via HTTP-01
- Configure nginx with ACME challenge support + subdomain routing
- Create and start a systemd service (`jtunnel-relay`)

Copy the token printed during setup — you'll need it on your laptop.

### Laptop setup

```bash
# Clone and install
git clone https://github.com/jagadeeshg16/jtunnel.git
cd jtunnel
sudo ./install   # installs jtunnel to /usr/local/bin + aiohttp dependency

# First run — asks for VPS hostname and token once, saves to ~/.jtunnelrc
jtunnel 3000
```

---

## Usage

```bash
# Expose localhost:3000
jtunnel 3000

# Named tunnel — gets a trusted Let's Encrypt cert automatically
jtunnel 3000 myapp

# Local HTTPS server
jtunnel 7443 myapp --https

# Skip SSL verification (self-signed VPS cert)
jtunnel 3000 myapp --insecure
```

---

## Features

### Named tunnels + automatic HTTPS certs
```
jtunnel 3000 myapp
```
- Tunnel ID: `<your-hostname>-myapp`
- Public URL: `https://<your-hostname>-myapp.jtunnel.yourdomain.com`
- On first connect, relay requests a Let's Encrypt cert for that subdomain via HTTP-01
- ~10s on first connect, instant on reconnect (cert reused within TTL)
- No browser warning

### Random tunnels (quick testing)
```
jtunnel 3000
```
- Auto-generates a random 4-char suffix: `<hostname>-x7k2`
- Uses self-signed fallback cert (browser warning, but works)

### Multiple simultaneous tunnels
Each person/port gets their own subdomain — no conflicts.

### Stale connection handling
If your client crashes and reconnects with the same tunnel name, the relay automatically replaces the stale WebSocket. No manual disconnect needed.

### Automatic cert cleanup
A background task runs every hour on the relay:

| Tunnel type | Cert TTL after disconnect |
|-------------|--------------------------|
| Named (`jtunnel 3000 myapp`) | 7 days |
| Random (`jtunnel 3000`) | 1 day |

Nginx conf is removed immediately on disconnect. Cert files are kept for reuse within TTL.

### Cloud deployment (Render / Railway)
Deploy the relay as a Docker container — no SSL cert needed, the platform handles it.

```bash
# Set TOKEN env variable in the Render/Railway dashboard
# Relay auto-starts in cloud mode
```

---

## Relay commands

```bash
# First-time VPS setup with nginx
sudo python3 relay --setup --nginx --domain jtunnel.yourdomain.com

# Start relay manually
python3 relay --cloud    # cloud mode (no SSL, for Render/Railway)
python3 relay            # VPS mode (SSL with cert.pem)

# Check active tunnels
curl https://jtunnel.yourdomain.com/_health
```

---

## Learn more

See [docs/architecture.md](docs/architecture.md) for a full technical walkthrough — request flow, SSL design, cert lifecycle, and multi-tunnel routing.

---

## Config files

| File | Location | Purpose |
|------|----------|---------|
| `~/.jtunnelrc` | Laptop | Saves VPS hostname + token |
| `~/.relayrc` | VPS | Saves token, port, domain |
| `~/.jtunnel-certs.json` | VPS | Tracks cert TTL per tunnel |
| `/etc/nginx/sites-available/jtunnel` | VPS | Main nginx config (wildcard fallback) |
| `/etc/nginx/sites-available/jtunnel-<id>` | VPS | Per-tunnel nginx config with real cert |
| `/etc/letsencrypt/live/<fqdn>/` | VPS | Let's Encrypt cert per tunnel |
