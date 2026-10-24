# Infrastructure

A single Docker Compose stack that runs the whole **meizuno** ecosystem behind
**Traefik** and a **Cloudflare Tunnel**: zero-downtime deploys at one replica
per service, a nightly backup that is restored and checked before it counts,
and Grafana watching all of it.

<p align="center">
  <img src="docs/architecture.svg" alt="meizuno infrastructure — Cloudflare → cloudflared → Traefik → seven apps → Postgres and Redis, with observability, backups, delivery, secrets and the Access-gated tooling" width="100%">
</p>

## In action

<sub>Recorded against the running stack.</sub>

#### 📊 Status page — Uptime Kuma, all systems operational

<a href="https://status.meizuno.com/status/meizuno"><img src="preview/status.gif" alt="Meizuno status page — live heartbeats for every service, all systems operational" width="100%"></a>

<sub>Every service checked on a 20s interval. Live page: <a href="https://status.meizuno.com/status/meizuno">status.meizuno.com ↗</a></sub>

#### 💾 Backups — nightly pg_dumpall → age-encrypted → R2, restore auto-verified

<img src="preview/backup.gif" alt="Backup and restore-verification pipeline" width="100%">

> <sub>Full-resolution MP4s: <a href="preview/status.mp4">status</a> · <a href="preview/backup.mp4">backup</a>.</sub>

## What runs here

**Applications** — deployed with `docker rollout`, no fixed container names:

| Service | Host | What it is | Database |
|---|---|---|---|
| `authentication` | `auth.meizuno.com` | Go SSO: JWT access + refresh tokens, Google OAuth | `authentication` |
| `ai-chat` | `chat.meizuno.com` | Nuxt chat over OpenAI, MCP hub, runs code in `sandbox` | `chat`, plus files in `meizuno_ai-chat-data` |
| `money-manager` | `money.meizuno.com` | Nuxt + Prisma, signs in through `authentication` | `money_manager` |
| `recipes-book` | `recipes.meizuno.com` | Nuxt + Prisma, signs in through `authentication` | `recipes_book` |
| `notes` | `notes.meizuno.com` | Nuxt + Prisma, signs in through `authentication` | `notes` |
| `forma` | `forma.meizuno.com` | FastAPI + Vue: food and body diary with an assistant; its own Google OAuth | `forma` |
| `english` | `english.meizuno.com` | FastAPI + Vue: daily English practice over OpenAI; its own Google OAuth | `english` |
| `sandbox` | — | Python runner for ai-chat's `run_code`, built from `./sandbox`, no network | — |

**Infrastructure and monitoring** — single instances with fixed names, applied
with `docker compose up -d <service>`:

| Service | Host | What it is |
|---|---|---|
| `cloudflared` | — | the tunnel; the only way in |
| `traefik` | `traefik.meizuno.com` (dashboard) | the reverse proxy |
| `postgres` | — | PostgreSQL 18, one role and one database per app |
| `redis` | — | Redis 8, password-protected; no service in these files is wired to it yet |
| `grafana` | `grafana.meizuno.com` | every dashboard — see [Monitoring](#monitoring) |
| `kuma` | `status.meizuno.com` | Uptime Kuma: uptime checks, alerts, the backup's push monitor |
| `victoria-metrics`, `loki`, `alloy`, `pyroscope`, `node-exporter`, `postgres-exporter`, `redis-exporter` | — | what feeds Grafana — see [Monitoring](#monitoring) |

## How it works

- **Files by concern, one project.** `compose.yaml` is a thin `include:` of
  the files below. They merge into a single `meizuno` project, so
  `docker compose` and `docker rollout` see the whole stack — the split is for
  reading, not isolation.

  | File | Holds |
  |---|---|
  | `compose.infra.yaml` | ingress (`traefik`, `cloudflared`) and data (`postgres`, `redis`) |
  | `compose.apps.yaml` | the SSO apps: `authentication`, `money-manager`, `recipes-book`, `notes` |
  | `compose.ai-chat.yaml` | `ai-chat` and its `sandbox` |
  | `compose.forma.yaml` | `forma` |
  | `compose.english.yaml` | `english` |
  | `compose.monitoring.yaml` | Grafana, what feeds it, and Uptime Kuma |

- **No host ports.** `cloudflared` reaches Traefik over a docker network, so
  nothing is published on the VM.
- **Traefik** is the single reverse proxy. Each app declares its hostname in
  labels (`Host(\`chat.meizuno.com\`)`), so routing lives in this repo, not in
  the Cloudflare dashboard.
- **TLS** is terminated by Cloudflare. Traefik speaks plain HTTP on `:80`;
  there is no ACME to manage.
- **Networks**, each joined only by what needs it:

  | Network | Who is on it | For |
  |---|---|---|
  | `edge` | cloudflared, Traefik, the apps, Grafana, Kuma, VictoriaMetrics | ingress, and scraping Traefik, cloudflared and the apps' metrics |
  | `internal` | the apps, Postgres, Redis, the exporters, Pyroscope, VictoriaMetrics | data; never reachable from `edge` alone |
  | `monitoring` | Grafana and everything that feeds it | metrics, logs, profiles |
  | `sandbox` | ai-chat and the sandbox, nothing else | `internal: true` — no internet, no host |
  | `tunnel` | cloudflared and the code-server sandbox | the one hostname that bypasses Traefik |

- **One Postgres, one role per app.** Each app owns only its own database and
  can CONNECT only to it, with its own password: `auth_user` → `authentication`,
  `money_user` → `money_manager`, `recipes_user` → `recipes_book`,
  `notes_user` → `notes`, `forma_user` → `forma`, `chat_user` → `chat`,
  `english_user` → `english`. A leaked app password is confined to that app's
  data. A read-only `monitoring` role (`pg_monitor`) serves postgres-exporter.
- **Two ways of signing in.** The four Nuxt apps delegate to `authentication`
  and validate every request against it (see [Token signing](#token-signing-eddsa)).
  Forma and English are self-contained: their own Google OAuth client, their own
  signed session cookie, their own secrets file.

## Zero-downtime with one replica

Plain `docker compose up` stops the old container before starting the new one.
To get zero downtime while keeping a single steady-state replica, deploys use
[`docker-rollout`](https://github.com/wowu/docker-rollout): it transiently scales
a service to **2**, waits for the new container to become **healthy**, then
removes the old one. Traefik load-balances across both during the swap.

This is why the app services **must not** set `container_name:` or `ports:` —
both would break transient scaling. Infrastructure and monitoring services are
never rolled and keep their fixed names.

Before the old container goes, the `docker-rollout.pre-stop-hook` label touches
`/tmp/drain`; the app's health endpoint then answers 503, Traefik's load-balancer
healthcheck takes it out of the pool, and a short sleep lets in-flight requests
finish. Each app image defines a `HEALTHCHECK`, which is how rollout knows the
new container is ready.

## Setup

On a fresh host:

```bash
# 1. Prereqs (Docker + Compose v2 already installed)
./scripts/install-prereqs.sh        # docker-rollout plugin + UDP buffers for cloudflared QUIC

# 2. Secrets and config
./scripts/secrets.sh decrypt        # .env, forma.env, english.env from the SOPS files
                                    # (or copy each *.env.example and fill it in)
cp monitoring.env.example monitoring.env
cp config/ai-chat.yml.example config/ai-chat.yml

# 3. First boot — --build for the locally built sandbox
docker compose up -d --build
docker compose ps
```

Then, once:

- **Postgres roles** — `postgres/init/01-init.sh` creates every app's role and
  database on a fresh volume, but see the [known issue](#notes--caveats) about
  three of its passwords.
- **The monitoring role** for postgres-exporter — the SQL is in
  `monitoring.env.example`.
- **Uptime Kuma** — open `status.meizuno.com`, create the admin, the monitors,
  and a **push** monitor for the backup; its internal URL goes in `.env` as
  `KUMA_PUSH_URL`.
- **The backup timer** — see [Backups](#backups-postgres--cloudflare-r2).

### Cloudflare dashboard (token-mode tunnel)

In **Zero Trust → Networks → Tunnels → your tunnel → Public Hostnames**, point
every hostname at the proxy — Traefik is reachable from `cloudflared` by its
service name:

| Hostname               | Service                     |
|------------------------|-----------------------------|
| `auth.meizuno.com`     | `http://traefik:80`         |
| `chat.meizuno.com`     | `http://traefik:80`         |
| `money.meizuno.com`    | `http://traefik:80`         |
| `recipes.meizuno.com`  | `http://traefik:80`         |
| `notes.meizuno.com`    | `http://traefik:80`         |
| `forma.meizuno.com`    | `http://traefik:80`         |
| `calories.meizuno.com` | `http://traefik:80`         |
| `english.meizuno.com`  | `http://traefik:80`         |
| `status.meizuno.com`   | `http://traefik:80`         |
| `grafana.meizuno.com`  | `http://traefik:80`         |
| `traefik.meizuno.com`  | `http://traefik:80`         |
| `code.meizuno.com`     | `http://code-server:8080`   |

Put the tunnel token in `CLOUDFLARE_TUNNEL_TOKEN`.

**Cloudflare Access** is the only gate in front of `grafana`, `traefik` and
`code`: Grafana runs with anonymous admin and no login form, the Traefik
dashboard has no auth, and code-server runs `--auth none`. Each of those
hostnames needs an Access policy before it is added to the tunnel. Kuma has a
login of its own.

`code.meizuno.com` is the exception to the routing: it does **not** go through
Traefik. The code-server sandbox is a separate compose project, and cloudflared
reaches it by container name over the `meizuno_tunnel` network, which exists for
that one purpose. `http://localhost:8080` cannot work — cloudflared is itself a
container, so localhost is its own loopback.

`calories.meizuno.com` is Forma's former host. It stays in the tunnel so Traefik
can answer it with a **301** to `forma.meizuno.com` (labels in
`compose.forma.yaml`). Only the canonical host serves the app: Forma signs
host-only cookies and has a single Google OAuth redirect URI.

## Deploy

**Apps.** Each app's CI runs its tests, builds and pushes the image to GHCR,
and then deploys over SSH — Forma's and English's deploy workflows do exactly
this, and a failing test stops the rollout:

```bash
docker compose pull forma && docker rollout forma
```

**This repo is never deployed by CI** — its workflow only validates the compose
files. On the host, `git pull`, then apply each kind of change the way it needs:

| What changed | Apply with |
|---|---|
| a service's definition in `compose*.yaml` | `docker compose up -d <service>` — recreates only what changed |
| a file mounted from `config/` (scrape config, Loki, Alloy, Pyroscope) | `docker compose restart <service>` — compose sees no change in a file it mounts, so `up -d` does nothing |
| `grafana/dashboards/*.json` | nothing — Grafana re-reads them every 30 s |
| `grafana/provisioning/` (datasources) | `docker compose restart grafana` |
| `scripts/` | nothing — the backup timer runs them from this checkout |
| `sandbox/` | `docker compose up -d --build sandbox` |
| a secret | `./scripts/secrets.sh decrypt`, then `up -d` the service that reads it |

## Rollback

Images are tagged by commit SHA in GHCR. To roll back, pin the tag and roll out:

```bash
# pin in .env or override the image, then:
docker compose pull ai-chat && docker rollout ai-chat
```

## Backups (Postgres → Cloudflare R2)

`scripts/backup-db.sh` runs nightly from a systemd timer (03:30 UTC). It runs
`pg_dumpall` (roles + every database) inside the running `postgres` container,
gzips it, **encrypts it client-side with age**, and uploads it to **Cloudflare
R2** through a throwaway `amazon/aws-cli` container. R2 only ever stores
ciphertext, so a leaked R2 token can read neither the data nor the role password
hashes; the plaintext never touches disk. The age recipient defaults to the
host's SOPS age key (override with `BACKUP_AGE_RECIPIENT`).

**A backup counts only once it has been restored.** After the upload the script
checks that the object in R2 is this run's — byte count against the local
file — and then runs `scripts/verify-restore.sh` on it:

- the dump is restored into a **throwaway** Postgres, never the live one,
  created with the live cluster's superuser (`POSTGRES_SUPERUSER`, default
  `admin`) as its first user — exactly as a real restore into a fresh stack
  would be. The dump records who granted each role membership
  (`… GRANTED BY admin`), and under any other first user those grants fail;
- it waits for that server over TCP, not the socket — the image's entrypoint
  runs a temporary socket-only server during init, and a restore started
  against it lands in the gap when it stops;
- it fails if an expected database is missing (`authentication`,
  `money_manager`, `recipes_book`, `notes`, `forma`), if one restored no
  tables, or if psql reported an error other than "already exists";
- the container **and its volume** are removed on exit — without `-v` every
  run left a full copy of the restored databases on the host.

The result goes to the Uptime Kuma push monitor (`KUMA_PUSH_URL`): `ok`, or the
stage, the exit code and the first reason — `verify-failed-1: notes missing
from the restore`. A backup that failed, or never ran, raises an alert, and the
event shows in Grafana's uptime row.

**Setup (once):**
1. Create an R2 bucket and an R2 **API token** (Object Read & Write) → it gives
   an Access Key ID / Secret Access Key and an endpoint
   `https://<account-id>.r2.cloudflarestorage.com`.
2. Fill `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`
   (and optionally `R2_PREFIX`, default `postgres`) in `.env`.
3. Install the daily timer:
   ```bash
   sudo cp systemd/meizuno-db-backup.{service,timer} /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now meizuno-db-backup.timer
   systemctl list-timers meizuno-db-backup.timer     # confirm next run
   sudo systemctl start meizuno-db-backup.service    # one run now; takes a few minutes
   journalctl -u meizuno-db-backup.service -n 25 --no-pager
   ```
   (Adjust `WorkingDirectory`/`ExecStart` in the unit if your stack dir differs
   from `/home/debian/servers/meizuno`.)

**Retention:** an R2 **lifecycle rule** on the bucket (e.g. delete objects older
than 30 days) — simpler and safer than pruning from the box.

**Restore** (into a fresh, empty Postgres) — decrypt with the age key first:
```bash
aws s3 cp s3://$R2_BUCKET/postgres/<file>.sql.gz.age - --endpoint-url $R2_ENDPOINT \
  | age -d -i ~/.config/sops/age/keys.txt | gunzip \
  | docker compose exec -T postgres psql -U admin -d postgres
```
(Losing the age key makes the backups unrecoverable — keep it backed up; it is
the same key that decrypts the SOPS files.)

**Verify by hand** at any time — the newest dump, or a key you pass:
```bash
./scripts/verify-restore.sh
```

## Monitoring

**Grafana** at `grafana.meizuno.com` is the only UI. It runs with no login of
its own — anonymous users are Admin — so the Cloudflare Access policy on that
hostname is load-bearing. Datasources and dashboards are provisioned from
`grafana/`, so a rebuilt Grafana comes back wired up.

| Component | What it does | Kept for |
|---|---|---|
| `victoria-metrics` | metrics store and scraper in one (every 30 s): exporters, Traefik, cloudflared, the apps | 15 days; stops writing under 2 GB free disk |
| `loki` + `alloy` | Alloy tails every container's log (except its own and code-server's) into Loki; Loki tags each line's level (`detected_level`), Alloy reads it for Python's plain `ERROR:` lines, which Loki cannot, and joins English's tracebacks into one entry | 7 days |
| `pyroscope` | CPU and memory profiles the apps push with the Pyroscope SDK | 72 hours — older blocks are deleted |
| `node-exporter` | host CPU, memory, disk, network | — |
| `postgres-exporter` | connections, database sizes, slow queries (`pg_stat_statements`) | — |
| `redis-exporter` | hit rate, memory, keys | — |
| `kuma` | uptime checks, alerts, the backup's push monitor | Kuma's own history |

**Dashboards:**
- **Meizuno — Overview** — stack health; an **uptime row** read from Kuma (its
  quick stats and every status change with Kuma's own message); host; errors and
  warnings from the logs; then, collapsed, Traefik, the databases, and
  monitoring's own footprint.
- **Meizuno — Apps** — per app: requests, p50/p95 and errors by route, the
  server's CPU and memory, its logs (lines by level, then the lines, filtered
  by level and a text search), and CPU and memory flame graphs by function.
- **Node Exporter Full** — the host in detail.

**Instrumented apps.** Forma, English and Money Manager serve Prometheus
metrics on a port of their own (`:9000`, `METRICS_PORT` under each app's
prefix) that no Traefik router points at, and push profiles to Pyroscope
(`PYROSCOPE_SERVER_ADDRESS`, likewise). Forma and English work with several
uvicorn workers: one worker serves the port and reports all of them. Money
Manager is a single Node process; its SDK sends CPU and memory-in-use profiles
under other type names than the Python one, and the Apps dashboard picks the
right ones per app. The other apps are not instrumented yet — they appear
through Traefik's per-router figures and their logs.

**The uptime row** reads Uptime Kuma's SQLite file through the
`frser-sqlite-datasource` plugin, installed on start by
`GF_PLUGINS_PREINSTALL_SYNC`. The Kuma volume is mounted into Grafana
read-only and opened with `mode=ro` — but it is the whole of Kuma's database,
notification settings included, in front of anybody who can open Grafana.

**How fresh:** a figure reaches Grafana up to ~60 s after it happened — the
30 s scrape interval plus the 30 s VictoriaMetrics holds back from queries.
Profiles arrive within ~10–20 s, logs within seconds.

**Kuma is the alerting layer.** Grafana alerting is not set up; Kuma is what
notifies. It lives in `compose.monitoring.yaml`: `docker compose up -d kuma`,
never `docker rollout`.

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
docker compose up -d authentication  # or docker rollout authentication
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
docker rollout authentication           # signs with the new key; still accepts old
# … wait > 15 min (in-flight old-key tokens expire) …
./scripts/rotate-jwt-key.sh --finalize  # drop the old key
docker rollout authentication
```
During the overlap both public keys are published at `/.well-known/jwks.json`.
The old **private** key is discarded immediately on rotation — only its public
half is kept, and only to verify already-issued tokens.

## Secrets at rest (SOPS + age)

Secrets are kept **encrypted at rest** with [SOPS](https://github.com/getsops/sops)
+ [age], so the canonical secrets files are safe to commit and safe in host
snapshots and backups — only values are encrypted, keys stay readable for diffs.

- `secrets.enc.env` — canonical, **committed**, values encrypted.
- `.env` — derived, **gitignored**, `0600`, what docker compose actually reads.
- **Per-app files** for the self-contained apps: `secrets.forma.enc.env` →
  `forma.env` and `secrets.english.enc.env` → `english.env`, each loaded by its
  compose file through `env_file`. Their database passwords stay in the main
  `.env`, because Postgres init reads them too.
- `monitoring.env` — postgres-exporter's connection string (see
  `monitoring.env.example`); plaintext, gitignored.
- `./scripts/secrets.sh decrypt` materializes **all** the SOPS files; edit one
  with `./scripts/secrets.sh edit` (main) or `./scripts/secrets.sh edit forma`.
- The age **private** key (`~/.config/sops/age/keys.txt`) never leaves the host
  and is the only thing that can decrypt — the secrets **and the backups**.
  **Back it up.**

```bash
# one-time: install sops + age, then
./scripts/secrets.sh init       # make an age key, write .sops.yaml, encrypt .env
git add secrets.enc.env .sops.yaml && git commit -m "chore: encrypt secrets"

./scripts/secrets.sh edit       # change a secret (re-encrypts on save)
./scripts/secrets.sh decrypt    # materialize the plaintext env files
```

Stronger variant (no plaintext `.env` on disk at all): wrap commands in
`sops exec-env secrets.enc.env 'docker compose up -d'`. This needs the age key
available non-interactively (`SOPS_AGE_KEY_FILE`) for the systemd backup unit,
so the simpler 0600-`.env` flow above is the default.

[age]: https://github.com/FiloSottile/age

## Notes & caveats

- **Known issue: three app databases on a fresh volume.** `postgres/init/01-init.sh`
  creates every app's role and database, but the `postgres` service passes it
  only `AUTH_DB_PASSWORD`, `MONEY_DB_PASSWORD`, `RECIPES_DB_PASSWORD` and
  `NOTES_DB_PASSWORD`. On a fresh volume the script stops at `forma`
  (`FORMA_DB_PASSWORD: unbound variable`), so `forma`, `chat` and `english` are
  not created. An existing cluster is unaffected. Until the three variables are
  added to the service, create those with the snippet below.
- **Adding an app database to an existing cluster** (the init script only runs
  on a fresh volume). Set the app's `*_DB_PASSWORD` in `.env`, then once, as the
  superuser, before deploying the app:
  ```sh
  docker compose exec -T postgres psql -U "${POSTGRES_SUPERUSER:-admin}" -d "${POSTGRES_SUPERUSER:-admin}" <<SQL
  CREATE ROLE chat_user LOGIN PASSWORD '<CHAT_DB_PASSWORD>';
  CREATE DATABASE chat OWNER chat_user;
  REVOKE CONNECT ON DATABASE chat FROM PUBLIC;
  GRANT CONNECT ON DATABASE chat TO chat_user;
  SQL
  ```
- **Schema migrations run from the apps themselves.** The Prisma apps apply
  theirs from the image's entrypoint (Notes and ai-chat run
  `prisma migrate deploy` on start — no `CREATEDB` needed, unlike `migrate dev`);
  Forma and English apply their SQL migrations on boot under an advisory lock,
  so two replicas starting together during a rollout cannot both migrate.
- **Forma's product catalogue import** is never automatic — the command, and
  why it runs as a separate `docker compose run`, are in `compose.forma.yaml`.

### One-time migrations (existing clusters only)

- **Shared `web` role → a role per app.** Run `scripts/migrate-db-roles.sh` once
  (after `git pull`, before redeploying the apps): it creates each role,
  transfers database and object ownership, and confines CONNECT. Then redeploy
  the apps and `DROP ROLE web`.
- **`calories` → `forma`.** Run `scripts/rename-calories-to-forma.sh` once —
  after `git pull` and `./scripts/secrets.sh decrypt`, **before**
  `docker compose up -d`, with the app stopped (Postgres will not rename a
  database with open connections). It renames the database and role in place,
  resets the role's password to `FORMA_DB_PASSWORD`, and re-applies the CONNECT
  confinement. The secrets go with it:
  ```sh
  mv calories.env forma.env          # plaintext, gitignored — a plain mv, not git mv
  ./scripts/secrets.sh edit          # CALORIES_DB_PASSWORD -> FORMA_DB_PASSWORD
  ./scripts/secrets.sh decrypt       # re-derive .env from secrets.enc.env
  ```
  A host that predates per-app SOPS files has a plaintext `calories.env` and no
  `secrets.calories.enc.env`; rename the plaintext file and encrypt it:
  `sops -e --input-type dotenv --output-type dotenv forma.env > secrets.forma.enc.env`.
  Until it is renamed, `.gitignore` covers `forma.env`, **not** `calories.env`.
- **Retired monitoring.** Beszel, Homepage and Vector → VictoriaLogs were removed
  when Grafana arrived. Their hostnames — `beszel.meizuno.com`,
  `home.meizuno.com`, `logs.meizuno.com` — can go from the tunnel.
