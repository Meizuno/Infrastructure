# Infrastructure

A single Docker Compose stack that runs the whole **meizuno** ecosystem behind
**Traefik** and a **Cloudflare Tunnel**, with **zero-downtime deploys** at one
replica per service.

```
Internet ─→ Cloudflare edge (TLS) ─→ cloudflared (token) ─→ traefik:80 ─┬─→ ai-chat
                                                                        ├─→ money-manager
            (everything over the docker network — nothing on the host)  ├─→ recipes-book
                                                                        ├─→ notes
                                                                        └─→ authentication
                                                          internal only: postgres
```

## How it works

- **Two files, one project.** `compose.yaml` is a thin `include:` of
  `compose.infra.yaml` (ingress, data, monitoring, logs) and
  `compose.apps.yaml` (the application services). They merge into a single
  `meizuno` project, so `docker compose` / `docker rollout` / `deploy.sh` all
  operate on the whole stack — the split is for readability, not isolation.
- **No host ports.** `cloudflared` reaches Traefik over the `edge` docker
  network, so nothing is published on the VM. The only way in is the tunnel.
- **Traefik** is the single reverse proxy. Each app declares its hostname in
  labels (`Host(\`chat.meizuno.com\`)`), so routing lives in this repo — not in
  the Cloudflare dashboard.
- **TLS** is terminated by Cloudflare. Traefik speaks plain HTTP on `:80`; there
  is no ACME/Let's Encrypt to manage.
- **Three networks:** `edge` (cloudflared ↔ traefik ↔ apps), `internal`
  (apps ↔ postgres, never reachable from edge), and `logs` (vector ↔
  victoria-logs).
- **Centralized logs.** Vector tails every container via the Docker socket and
  ships to VictoriaLogs (30-day retention). The log UI is at
  `logs.meizuno.com` behind the same basic-auth as the Traefik dashboard.
- **One Postgres, one role per app.** Each app owns ONLY its own database and
  can CONNECT only to it (`auth_user`→`authentication`, `money_user`→
  `money_manager`, `recipes_user`→`recipes_book`, `notes_user`→`notes`), each
  with its own password. A leaked app password is confined to that app's data —
  it can't read, write, or drop another app's schema. ai-chat is stateless and
  owns no database.

## Zero-downtime with one replica

Plain `docker compose up` stops the old container before starting the new one.
To get zero downtime while keeping a single steady-state replica, deploys use
[`docker-rollout`](https://github.com/wowu/docker-rollout): it transiently scales
a service to **2**, waits for the new container to become **healthy**, then
removes the old one. Traefik load-balances across both during the swap.

This is why the five app services **must not** set `container_name:` or `ports:`
— both would break transient scaling. Infra services (traefik, cloudflared,
postgres, kuma, victoria-logs, vector) are not rolled and keep their fixed
names — Vector relies on the exact `vector`/`victoria-logs` names to exclude its
own logs.

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
| `logs.meizuno.com`     | `http://traefik:80`  |

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

## Backups (Postgres → Cloudflare R2)

`scripts/backup-db.sh` runs `pg_dumpall` (roles + every database) inside the
running `postgres` container, gzips it, and uploads it off-host to **Cloudflare
R2** via a throwaway `amazon/aws-cli` container — no host packages, no DB
password (local-socket trust inside the container).

**Setup (once):**
1. Create an R2 bucket and an R2 **API token** (Object Read & Write) → it gives
   an Access Key ID / Secret Access Key and an endpoint
   `https://<account-id>.r2.cloudflarestorage.com`.
2. Fill `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`
   (and optional `R2_PREFIX`) in `.env`.
3. Install the daily timer:
   ```bash
   sudo cp systemd/meizuno-db-backup.{service,timer} /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now meizuno-db-backup.timer
   systemctl list-timers meizuno-db-backup.timer     # confirm next run
   ./scripts/backup-db.sh                             # one manual run to verify
   ```
   (Adjust `WorkingDirectory`/`ExecStart` paths in the unit if your stack dir
   differs from `/home/debian/servers/meizuno`.)

**Retention:** set an R2 **lifecycle rule** on the bucket (e.g. delete objects
older than 30 days) — simpler and safer than pruning from the box.

**Restore** (into a fresh/empty Postgres):
```bash
aws s3 cp s3://$R2_BUCKET/postgres/<file>.sql.gz - --endpoint-url $R2_ENDPOINT \
  | gunzip | docker compose exec -T postgres psql -U admin -d postgres
```

**Verify the backup restores** (a backup you've never restored isn't a backup).
`scripts/verify-restore.sh` pulls the newest dump (or a key you pass), restores
it into a **throwaway** Postgres container (never the live DB), and prints the
databases, roles, and per-DB table/row counts so you can eyeball that the data
is really there. The temp container is removed on exit. Run it after first
setup and periodically:
```bash
./scripts/verify-restore.sh
```

## Token signing (EdDSA)

The auth service signs access tokens with **EdDSA** (Ed25519, asymmetric). The
**private** signing key lives only on the host as a file secret mounted into the
`authentication` container — never an env value, never in `docker inspect`, never
in git. The **public** half is published at `auth.meizuno.com/.well-known/jwks.json`.

Consumers (notes, money-manager, recipes-book, ai-chat) **do not hold any signing
key** — they validate every request against the auth service's `/validate`
endpoint. So signing changes are an auth-service-only concern: no app changes, no
app redeploys.

**First-time setup:**
```bash
./scripts/gen-jwt-key.sh             # writes secrets/jwt_private_key.pem
docker compose up -d authentication  # or ./scripts/deploy.sh authentication
curl -s https://auth.meizuno.com/.well-known/jwks.json   # shows the public key
```

> The key file is written `0644` inside a `0700 secrets/` dir on purpose: docker
> bind-mounts it into the authentication container, which runs as a non-root uid,
> and non-Swarm compose does not remap secret ownership — a `0600` file owned by
> the host user gives the container "permission denied". The `0700` directory
> still blocks other host users, so protection is equivalent.

**Cutover from the legacy HS256 secret** (zero downtime; the auth service accepts
both during the window because `JWT_SECRET` is still set):
1. Generate the key and deploy with EdDSA (above). New tokens are EdDSA; the
   in-flight HS256 access tokens (≤15 min TTL) still validate.
2. Wait > 15 minutes — every HS256 access token has now expired. Refresh tokens
   are opaque (DB-hashed), so they are unaffected.
3. **Blank `JWT_SECRET=`** in `.env` and redeploy `authentication`. HS256 is now
   rejected outright; only EdDSA is accepted. This also retires the old shared
   secret (a de-facto signing-key rotation).

**Rotating the signing key (seamless, zero failed validations):** the auth
service can verify against several keys by `kid`, so a rotation overlaps the old
and new key for one access-token TTL:
```bash
./scripts/rotate-jwt-key.sh             # keep old public key, mint a new signer
./scripts/deploy.sh authentication      # signs with the new key; still accepts old
# … wait > 15 min (in-flight old-key tokens expire) …
./scripts/rotate-jwt-key.sh --finalize  # drop the old key
./scripts/deploy.sh authentication
```
During the overlap both public keys are published at `/.well-known/jwks.json`.
The old **private** key is discarded immediately on rotation — only its public
half is kept, and only to verify already-issued tokens.

## Secrets at rest (SOPS + age)

Secrets can be kept **encrypted at rest** with [SOPS](https://github.com/getsops/sops)
+ [age], so the canonical secrets file is safe to commit and safe in host
snapshots/backups — only values are encrypted, keys stay readable for diffs.

- `secrets.enc.env` — canonical, **committed**, values encrypted.
- `.env` — derived, **gitignored**, `0600`, what docker compose actually reads.
  `deploy.sh` regenerates it from `secrets.enc.env` on every deploy.
- The age **private** key (`~/.config/sops/age/keys.txt`) never leaves the host
  and is the only thing that can decrypt. **Back it up** — losing it loses the
  secrets.

```bash
# one-time: install sops + age, then
./scripts/secrets.sh init       # make an age key, write .sops.yaml, encrypt .env
git add secrets.enc.env .sops.yaml && git commit -m "chore: encrypt secrets"

./scripts/secrets.sh edit       # change a secret (re-encrypts on save)
./scripts/secrets.sh decrypt    # materialize .env by hand (deploy does this too)
```

Stronger variant (no plaintext `.env` on disk at all): wrap commands in
`sops exec-env secrets.enc.env 'docker compose up -d'`. This needs the age key
available non-interactively (`SOPS_AGE_KEY_FILE`) for the systemd backup unit,
so the simpler 0600-`.env` flow above is the default.

[age]: https://github.com/FiloSottile/age

## Notes & caveats

- **Hostnames are assumptions** (`chat/money/recipes/notes/auth/status.meizuno.com`).
  Adjust the `Host(...)` labels and the dashboard table to match your real DNS.
- `postgres/init/01-init.sh` (per-app roles + databases) runs **only on a fresh
  volume**. On an **existing** volume it won't run — to move off the old shared
  `web` role to per-app roles, run `scripts/migrate-db-roles.sh` once (after
  `git pull`, before redeploying the apps): it creates each role, transfers
  database + object ownership, and confines CONNECT. Then redeploy the apps and
  `DROP ROLE web`.
- App schema migrations still run from each app's own image/entrypoint
  (e.g. Notes runs `prisma migrate deploy` on start).
- Kuma keeps `container_name:` and is not rolled.
