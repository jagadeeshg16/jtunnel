# jtunnel — Technical Architecture

Built by Jagadeesh.

---

## The Problem

Corporate networks typically block all outbound ports except **443 (HTTPS)**. Standard tunneling tools (ngrok, cloudflared) rely on custom protocols or non-standard ports — they don't work inside such networks.

jtunnel solves this by building the entire tunnel over **WSS (WebSocket Secure)** — which is just an upgraded HTTPS connection on port 443. Corporate firewalls allow it through without any special configuration.

---

## Core Concept

```
Your laptop opens an outbound WSS connection to the relay on port 443.
The relay accepts inbound HTTP requests from the internet on port 443.
Every browser request travels over the WebSocket as JSON — your laptop
forwards it to localhost, sends the response back, relay returns it to the browser.
```

One port. Both directions. No firewall issues.

---

## Components

### `jtunnel` (client — runs on your laptop)

- Connects to the relay via WSS
- Keeps the WebSocket open and idle, waiting for requests
- On each incoming request: forwards to `localhost:<port>`, sends response back
- Auto-reconnects on disconnect

### `relay` (server — runs on VPS/EC2)

- Accepts WebSocket connections from jtunnel clients
- Stores each connection in `_tunnels = { tunnel-id: websocket }`
- Accepts HTTP requests from browsers
- Routes each request to the correct WebSocket based on tunnel ID
- Returns the response to the browser

### Nginx (on VPS)

- Terminates TLS on port 443
- Extracts subdomain from `Host` header → sets `X-Tunnel-Name`
- Proxies to relay on port 8080

---

## Full Request Flow

### Step 1 — Start tunnel

```bash
jtunnel 3000 myapp
```

Client computes tunnel ID: `<your-hostname>-myapp`

Opens WSS connection to relay:
```
wss://jtunnel.yourdomain.com/_jtunnel
X-Token: <token>
X-Tunnel-Name: <hostname>-myapp
```

This is outbound port 443 — same as normal HTTPS browsing.

---

### Step 2 — Relay registers the tunnel

Relay accepts the WebSocket upgrade, stores it:

```python
_tunnels['<hostname>-myapp'] = ws
```

Sends welcome message back to client:
```json
{
  "type": "welcome",
  "url": "https://<hostname>-myapp.jtunnel.yourdomain.com"
}
```

Client prints the public URL. WebSocket stays open and idle.

---

### Step 3 — Let's Encrypt cert issued in background

Relay fires certbot for `<hostname>-myapp.jtunnel.yourdomain.com`:

```
relay
  → certbot places challenge file in /var/www/html/
  → Let's Encrypt fetches http://<hostname>-myapp.jtunnel.yourdomain.com/.well-known/acme-challenge/xyz
  → verified (HTTP-01 challenge)
  → cert issued to /etc/letsencrypt/live/<hostname>-myapp.jtunnel.yourdomain.com/
  → relay writes nginx server block for this subdomain
  → nginx -s reload
```

Takes ~10 seconds. Tunnel works during this time with self-signed fallback.

---

### Step 4 — Browser makes a request

```
GET https://<hostname>-myapp.jtunnel.yourdomain.com/api/users
```

**DNS:** Wildcard A record `*.jtunnel.yourdomain.com → <VPS IP>` resolves the subdomain.

**Nginx:**
- Matches the per-tunnel server block
- Presents the Let's Encrypt cert → browser trusts it → no warning
- Extracts `<hostname>-myapp` from subdomain
- Sets `X-Tunnel-Name: <hostname>-myapp`
- Proxies HTTP request to relay on port 8080

---

### Step 5 — Relay forwards over WebSocket

Relay looks up `_tunnels['<hostname>-myapp']` — finds the open WebSocket.

Serializes the request as JSON:
```json
{
  "id": "abc-123",
  "method": "GET",
  "path": "/api/users",
  "headers": { "Cookie": "...", "Accept": "application/json" },
  "body": ""
}
```

Sends it over the WebSocket to your laptop. Stores a `Future` in `_pending['abc-123']` — waits for response.

---

### Step 6 — Client forwards to localhost

Client receives the JSON. Makes a real HTTP request:

```
GET http://localhost:3000/api/users
```

Your dev server responds. Client serializes the response:
```json
{
  "id": "abc-123",
  "status": 200,
  "headers": { "Content-Type": "application/json" },
  "body": "<base64 encoded body>"
}
```

Sends it back over the WebSocket.

---

### Step 7 — Relay returns response to browser

Relay resolves `_pending['abc-123']`. Reconstructs the HTTP response. Returns it to nginx → nginx to browser.

```
YOUR LAPTOP                      VPS                          INTERNET
───────────                      ───                          ────────

jtunnel client ══ WSS :443 ══▶ Nginx :443
                                  │ TLS terminated
                                  │ subdomain → X-Tunnel-Name
                                  ▼
                               relay :8080
                               _tunnels = {
                                 "<hostname>-myapp": ws ←────── WebSocket
                               }
                                  │ serialize request as JSON
                                  ▼
localhost:3000 ◀── HTTP ─────── ws ◀─────────────────── GET /api/users
               ──── 200 OK ───▶ ws ──────────────────▶  200 OK ──▶ Browser
```

---

## Multi-tunnel Routing

Each tunnel gets a unique ID: `<hostname>-<name>`.

Nginx extracts the subdomain from the `Host` header and sets it as `X-Tunnel-Name`. The relay uses this to look up the correct WebSocket in `_tunnels`.

Multiple people can connect simultaneously — each gets their own subdomain, no conflicts:

```
hostname-a-api.jtunnel.yourdomain.com  →  ws[hostname-a-api]  →  laptop-A:3000
hostname-a-ui.jtunnel.yourdomain.com   →  ws[hostname-a-ui]   →  laptop-A:5173
hostname-b-app.jtunnel.yourdomain.com  →  ws[hostname-b-app]  →  laptop-B:8080
```

---

## SSL / TLS Design

### Why not a wildcard cert?

A wildcard cert (`*.jtunnel.yourdomain.com`) would cover all subdomains with one cert. But Let's Encrypt requires **DNS-01 challenge** for wildcards — you must add a TXT record to your DNS to prove ownership of the whole domain.

### What we do instead — per-subdomain HTTP-01

For a specific subdomain (`<hostname>-myapp.jtunnel.yourdomain.com`), Let's Encrypt accepts **HTTP-01 challenge** — just serve a file at a known URL. No DNS changes needed.

When a named tunnel connects, the relay:
1. Runs certbot for that specific subdomain
2. Nginx serves the challenge file on port 80
3. Let's Encrypt verifies and issues the cert
4. Relay writes a dedicated nginx server block using that cert
5. Nginx reloads

Result: each subdomain gets its own trusted cert. No browser warning.

### Cert lifecycle

| Event | Action |
|-------|--------|
| Tunnel connects | Cert issued in background (~10s first time) |
| Tunnel disconnects | Nginx conf removed immediately |
| Reconnect within TTL | Cert reused — instant |
| Named tunnel TTL | 7 days after disconnect |
| Random tunnel TTL | 1 day after disconnect |
| After TTL | Cert deleted, re-issued on next connect |

A background task on the relay checks every hour and cleans up expired certs.

---

## Stale Connection Handling

If a client crashes and reconnects with the same tunnel name, the relay detects the stale WebSocket and replaces it automatically — no manual intervention needed.

On new connection with an existing tunnel ID: relay closes the old WebSocket and accepts the new one.

---

## Cert Cleanup — Rate Limits

Let's Encrypt allows **50 certificates per registered domain per week**. To stay within this:

- Named tunnels keep certs for 7 days — reused on reconnect, minimal issuance
- Random tunnels keep certs for 1 day — unlikely to reuse same ID anyway
- Cert files are only deleted after TTL, not immediately on disconnect

---

## Config Files

| File | Location | Purpose |
|------|----------|---------|
| `~/.jtunnelrc` | Laptop | VPS hostname + token |
| `~/.relayrc` | VPS | Token, port, domain |
| `~/.jtunnel-certs.json` | VPS | Disconnect timestamps per tunnel for TTL tracking |
| `/etc/nginx/sites-available/jtunnel` | VPS | Main nginx config (wildcard fallback, self-signed) |
| `/etc/nginx/sites-available/jtunnel-<id>` | VPS | Per-tunnel nginx config with real LE cert |
| `/etc/letsencrypt/live/<fqdn>/` | VPS | Let's Encrypt cert per tunnel |
| `/etc/nginx/conf.d/jtunnel.conf` | VPS | `server_names_hash_bucket_size 128` — needed for long subdomain names |
