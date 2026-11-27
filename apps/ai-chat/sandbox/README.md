# Python sandbox

A tiny, dependency-free HTTP service that runs Python code in an isolated
subprocess. It implements the contract AIChat's `SandboxRunner` port expects, so
AIChat's `run_code` system tool can execute code without ever running it
in-process.

## API

```
POST /run    { "language": "python", "source": "<code>" }
          -> { "ok": bool, "stdout": str, "stderr": str }
GET  /health -> "ok"
```

Only `language: "python"` is supported today; anything else returns `ok: false`.

## Isolation model

Two layers — both are required.

**In-process (`app.py`), per request:**
- `python -I -B` — isolated mode, no bytecode, ignores env / user site-packages
- rlimits: CPU 10s, address space 256 MB, ≤64 processes, 10 MB file size, no core
- wall-clock timeout (10s), stdin closed, restricted `cwd`/`env`
- output capped at 64 KB, source capped at 256 KB

**Container (`compose.yaml` / run flags) — the outer layer:**
- non-root user, `--read-only` rootfs with a small `tmpfs /tmp`
- `--cap-drop ALL`, `--security-opt no-new-privileges`
- `--pids-limit`, `--memory`, `--cpus`
- **`internal: true` network — the only thing that denies the code egress.**
  The executed process shares the container's network namespace, so network
  isolation cannot be enforced in `app.py`; it must come from the network.

> Verified locally: success, tracebacks, the 10s timeout on `while True: pass`,
> and read-only rootfs blocking `/etc` writes all behave. On a plain bridge
> network the code *can* reach the internet — hence `internal: true` in prod.

## Run locally

```sh
docker build -t meizuno-sandbox:dev .
docker run -d --name sandbox-dev -p 8000:8000 \
  --read-only --tmpfs /tmp:size=64m \
  --security-opt no-new-privileges --cap-drop ALL \
  --pids-limit 128 --memory 512m --cpus 1.0 \
  meizuno-sandbox:dev
```

Point AIChat at it in dev with `NUXT_SANDBOX_URL=http://localhost:8000`.

## Deploy into the meizuno stack

Add an equivalent service to the Infrastructure compose on a dedicated
`sandbox` network (`internal: true`), attach `ai-chat` to that network, and set
`NUXT_SANDBOX_URL=http://sandbox:8000` on ai-chat.

## Next hardening steps (when it matters)

- Per-run ephemeral inner container (Docker-out-of-Docker) or gVisor/Firecracker
  for stronger isolation than one shared container.
- Per-user quotas + rate limiting at the AIChat tool boundary.
- Return artifacts (files/plots the code writes) so charts can flow back into
  chat via AIChat's BlobStorage.
