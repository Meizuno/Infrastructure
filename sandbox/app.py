"""Minimal Python code-execution sandbox service.

Contract (matches AIChat's SandboxRunner port):
    POST /run  { "language": "python", "source": "<code>" }
      -> { "ok": bool, "stdout": str, "stderr": str }
    GET  /health -> "ok"

Each request runs the code in a fresh, isolated subprocess:
  * python -I -B   (isolated mode, no bytecode, ignore env/user-site)
  * rlimits        (CPU, address space, processes, file size, no core)
  * wall-clock timeout, stdin closed, restricted cwd/env
  * no output larger than MAX_OUTPUT

The process-level guards are the inner layer. The OUTER layer is the container:
run it non-root, read-only rootfs, all caps dropped, on a network with no
egress (see compose.yaml). Code shares the container's network namespace, so
network isolation MUST come from the container/network, not from here.
"""
import json
import resource
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8000
TIMEOUT_SEC = 10
MEM_BYTES = 256 * 1024 * 1024
MAX_OUTPUT = 64 * 1024
MAX_SOURCE = 256 * 1024


def _set_limits() -> None:
    # Runs in the child after fork, before exec.
    resource.setrlimit(resource.RLIMIT_CPU, (TIMEOUT_SEC, TIMEOUT_SEC))
    resource.setrlimit(resource.RLIMIT_AS, (MEM_BYTES, MEM_BYTES))
    resource.setrlimit(resource.RLIMIT_NPROC, (64, 64))
    resource.setrlimit(resource.RLIMIT_FSIZE, (10 * 1024 * 1024, 10 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def run_python(source: str) -> dict:
    with tempfile.NamedTemporaryFile("w", suffix=".py", dir="/tmp", delete=True) as f:
        f.write(source)
        f.flush()
        try:
            proc = subprocess.run(
                [sys.executable, "-I", "-B", f.name],
                capture_output=True,
                text=True,
                timeout=TIMEOUT_SEC,
                stdin=subprocess.DEVNULL,
                preexec_fn=_set_limits,
                cwd="/tmp",
                env={"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": "/tmp"},
            )
        except subprocess.TimeoutExpired:
            return {"ok": False, "stdout": "", "stderr": f"timed out after {TIMEOUT_SEC}s"}
        return {
            "ok": proc.returncode == 0,
            "stdout": proc.stdout[:MAX_OUTPUT],
            "stderr": proc.stderr[:MAX_OUTPUT],
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
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self._json({"ok": False, "stdout": "", "stderr": "invalid json"}, 400)
            return
        result = execute(body)
        print(
            f"run language={body.get('language')} ok={str(result['ok']).lower()} "
            f"stdout={len(result['stdout'])} stderr={len(result['stderr'])}",
            flush=True,
        )
        self._json(result)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
