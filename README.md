# meizuno-stack

A single Docker Compose stack that runs the whole **meizuno** ecosystem behind
**Traefik** and a **Cloudflare Tunnel**, with **zero-downtime deploys** at one
replica per service.

```
Internet ─→ Cloudflare edge (TLS) ─→ cloudflared (token) ─→ traefik:80 ─┬─→ ai-chat
                                                                        ├─→ money-manager
            (everything over the docker network — nothing on the host)  ├─→ recipes-book
                                                                        ├─→ notes
                                                                        └─→ authentication
                                                          internal only: postgres · whisper
```

## How it works

- **No host ports.** `cloudflared` reaches Traefik over the `edge` docker
  network, so nothing is published on the VM. The only way in is the tunnel.
- **Traefik** is the single reverse proxy. Each app declares its hostname in
  labels (`Host(\`chat.meizuno.com\`)`), so routing lives in this repo — not in
  the Cloudflare dashboard.
- **TLS** is terminated by Cloudflare. Traefik speaks plain HTTP on `:80`; there
  is no ACME/Let's Encrypt to manage.
- **Two networks:** `edge` (cloudflared ↔ traefik ↔ apps) and `internal`
  (apps ↔ postgres/whisper). Postgres and Whisper are never reachable from edge.
- **One shared Postgres** with an `admin` superuser and a `web` role that owns
  every app database (`authentication`, `chat`, `money_manager`, `recipes_book`,
  `notes`).

## Zero-downtime with one replica

Plain `docker compose up` stops the old container before starting the new one.
To get zero downtime while keeping a single steady-state replica, deploys use
[`docker-rollout`](https://github.com/wowu/docker-rollout): it transiently scales
a service to **2**, waits for the new container to become **healthy**, then
removes the old one. Traefik load-balances across both during the swap.

This is why the five app services **must not** set `container_name:` or `ports:`
— both would break transient scaling. Infra services (traefik, cloudflared,
postgres, whisper, kuma) are not rolled and keep their fixed names.

> Requires each app image to define a `HEALTHCHECK` (the meizuno images do) so
> rollout knows when the new container is ready.

## Setup

```bash
# 1. Prereqs (Docker + Compose v2 already installed on the host)
./scripts/install-prereqs.sh        # installs the docker-rollout plugin

# 2. Config
cp .env.example .env                 # fill in every value
cp config/ai-chat.yml.example config/ai-chat.yml

# 3. First boot
docker compose up -d                 # infra + apps
docker compose ps
```

Generate the Traefik dashboard credentials for `TRAEFIK_DASHBOARD_AUTH`:

```bash
htpasswd -nb admin 'your-password'   # then double every $  →  $$  in .env
```

### Cloudflare dashboard (token-mode tunnel)

In **Zero Trust → Networks → Tunnels → your tunnel → Public Hostnames**, point
**every** hostname at the proxy (Traefik discovers `cloudflared` on the `edge`
network by service name):

| Hostname               | Service              |
|------------------------|----------------------|
| `chat.meizuno.com`     | `http://traefik:80`  |
| `money.meizuno.com`    | `http://traefik:80`  |
| `recipes.meizuno.com`  | `http://traefik:80`  |
| `notes.meizuno.com`    | `http://traefik:80`  |
| `auth.meizuno.com`     | `http://traefik:80`  |
| `status.meizuno.com`   | `http://traefik:80`  |
| `traefik.meizuno.com`  | `http://traefik:80`  |

Traefik then dispatches each Host to the right container. Put the tunnel token
in `CLOUDFLARE_TUNNEL_TOKEN`.

## Deploy

```bash
./scripts/deploy.sh                  # pull + zero-downtime rollout of all apps
./scripts/deploy.sh ai-chat          # just one service
```

Wire this into each app's CI as the last step (SSH to the host, then
`./scripts/deploy.sh <service>`), replacing the old per-app `compose up -d`.

## Rollback

Images are tagged by commit SHA in GHCR. To roll back, pin the tag and roll out:

```bash
# pin in .env or override the image, then:
docker compose pull ai-chat && docker rollout ai-chat
```

## Notes & caveats

- **Hostnames are assumptions** (`chat/money/recipes/notes/auth/status.meizuno.com`).
  Adjust the `Host(...)` labels and the dashboard table to match your real DNS.
- `postgres/init/01-init.sh` runs **only on a fresh volume**. Migrating an
  existing `postgres` volume? The `web` role and app DBs already exist — the
  script is a no-op (and idempotent if it does run).
- App schema migrations still run from each app's own image/entrypoint
  (e.g. Notes runs `prisma migrate deploy` on start).
- Whisper and Kuma keep `container_name:` and are not rolled; a Whisper restart
  briefly interrupts voice transcription only.
