"""Minimal Python code-execution sandbox service.

Contract (matches AIChat's SandboxRunner port):
    POST /run  { "language": "python", "source": "<code>" }
      -> { "ok": bool, "stdout": str, "stderr": str }
    GET  /health -> "ok"

Each request runs the code in a fresh, isolated subprocess:
  * python -I -B   (isolated mode, no bytecode, ignore env/user-site)
  * a fresh per-run temp dir as cwd/HOME (runs don't see each other's files)
  * rlimits        (CPU, address space, processes, file size, no core)
  * wall-clock timeout; the whole process GROUP is killed so forks die too
  * stdin closed, restricted env, output capped

Guards against overload: a bounded number of concurrent runs (429 when busy)
and a cap on request body size.

The process-level guards are the inner layer. The OUTER layer is the container:
run it non-root, read-only rootfs, all caps dropped, on a network with no
egress. Code shares the container's network namespace, so network isolation
MUST come from the container/network, not from here.
"""
import json
import os
import resource
import signal
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8000
TIMEOUT_SEC = 10
MEM_BYTES = 256 * 1024 * 1024
MAX_OUTPUT = 64 * 1024
MAX_SOURCE = 256 * 1024
MAX_BODY = 512 * 1024        # request-body ceiling (JSON envelope around source)
MAX_CONCURRENCY = 4          # simultaneous runs; extra requests get 429

# Bounds concurrent executions so a burst can't spawn unbounded subprocesses.
_slots = threading.BoundedSemaphore(MAX_CONCURRENCY)


def _set_limits() -> None:
    # Runs in the child after fork, before exec.
    resource.setrlimit(resource.RLIMIT_CPU, (TIMEOUT_SEC, TIMEOUT_SEC))
    resource.setrlimit(resource.RLIMIT_AS, (MEM_BYTES, MEM_BYTES))
    resource.setrlimit(resource.RLIMIT_NPROC, (64, 64))
    resource.setrlimit(resource.RLIMIT_FSIZE, (10 * 1024 * 1024, 10 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def run_python(source: str) -> dict:
    # A fresh temp dir per run: isolates files written to cwd/HOME/tmp between
    # runs and is cleaned up on exit.
    with tempfile.TemporaryDirectory(dir="/tmp") as workdir:
        script = os.path.join(workdir, "main.py")
        with open(script, "w") as f:
            f.write(source)

        proc = subprocess.Popen(
            [sys.executable, "-I", "-B", script],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            text=True,
            cwd=workdir,
            env={"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": workdir, "TMPDIR": workdir},
            start_new_session=True,   # own process group, so we can kill forks too
            preexec_fn=_set_limits,
        )
        try:
            stdout, stderr = proc.communicate(timeout=TIMEOUT_SEC)
        except subprocess.TimeoutExpired:
            # Kill the whole group, not just the direct child (it may have forked).
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.communicate()
            return {"ok": False, "stdout": "", "stderr": f"timed out after {TIMEOUT_SEC}s"}

        return {
            "ok": proc.returncode == 0,
            "stdout": stdout[:MAX_OUTPUT],
            "stderr": stderr[:MAX_OUTPUT],
        }


def execute(body: dict) -> dict:
    language = body.get("language")
    source = body.get("source") or ""
    if language != "python":
        return {"ok": False, "stdout": "", "stderr": f"unsupported language: {language!r}"}
    if not source:
        return {"ok": False, "stdout": "", "stderr": "empty source"}
    if len(source) > MAX_SOURCE:
        return {"ok": False, "stdout": "", "stderr": "source too large"}
    return run_python(source)


class Handler(BaseHTTPRequestHandler):
    def _json(self, payload: dict, status: int = 200) -> None:
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_response(200)
            self.send_header("content-length", "2")
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_error(404)

    def do_POST(self) -> None:
        if self.path != "/run":
            self.send_error(404)
            return

        length = int(self.headers.get("content-length", 0) or 0)
        if length > MAX_BODY:
            # Drain the oversized body (in fixed chunks, discarded) so the client
            # receives our 413 instead of a connection reset.
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 65536))
                if not chunk:
                    break
                remaining -= len(chunk)
            self._json({"ok": False, "stdout": "", "stderr": "request too large"}, 413)
            return
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self._json({"ok": False, "stdout": "", "stderr": "invalid json"}, 400)
            return

        # Reject rather than queue when all execution slots are busy.
        if not _slots.acquire(blocking=False):
            self._json({"ok": False, "stdout": "", "stderr": "sandbox busy, try again"}, 429)
            return
        try:
            result = execute(body)
        finally:
            _slots.release()

        print(
            f"run language={body.get('language')} ok={str(result['ok']).lower()} "
            f"stdout={len(result['stdout'])} stderr={len(result['stderr'])}",
            flush=True,
        )
        self._json(result)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
