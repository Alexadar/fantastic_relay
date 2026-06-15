"""Launcher abstraction — run `relayd` (the headless relay-kernel) either as a
LOCAL binary subprocess or inside the relay CONTAINER image (podman/docker),
selected by the `RELAY_TARGET` env var (`local` default, or `container`).

Both launchers expose the SAME operation so the suite is target-agnostic:

  - `start(port, *, token, label)` → a live `RelayProc` reachable at
        `127.0.0.1:<port>`, speaking the relay WS protocol.

This is the relay's mirror of the canvas integration harness: the SAME isolation
tests validate the locally-built binary AND the shipped container ("standalone and
container interchangeable"). A relay instance is just a `relayd` at host:port —
there is no workdir/state to seed (peers are in-memory, identity is the connection).
"""

from __future__ import annotations

import os
import socket
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from shutil import which


def resolve_engine() -> str | None:
    """First available container engine (podman preferred), or None."""
    for engine in ("podman", "docker"):
        if which(engine) is not None:
            return engine
    return None


def free_port() -> int:
    """An OS-assigned ephemeral port (released immediately; racy-but-fine in tests)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _wait_tcp(host: str, port: int, timeout: float = 20.0) -> bool:
    """Block until host:port accepts a TCP connection (the relay is listening)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.1)
    return False


@dataclass
class RelayProc:
    """A live relay reachable at 127.0.0.1:<port>. Either a local subprocess
    (`proc` set) or a container (`container`/`engine` set). `stop()` tears down
    whichever it is."""

    port: int
    token: str
    label: str = ""
    proc: subprocess.Popen | None = None
    container: str | None = None
    engine: str | None = None

    @property
    def url(self) -> str:
        return f"ws://127.0.0.1:{self.port}"

    def stop(self) -> None:
        if self.container and self.engine:
            subprocess.run(
                [self.engine, "rm", "-f", self.container], capture_output=True, text=True
            )
            self.container = None
        if self.proc is not None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.proc = None


class LocalLauncher:
    """Run relayd from a locally-built binary (the standalone path)."""

    kind = "local"

    def __init__(self, binary: Path) -> None:
        self.binary = Path(binary)

    def start(self, port: int, *, token: str, label: str = "") -> RelayProc:
        env = dict(os.environ)
        env["RELAY_LISTEN_ADDR"] = f"127.0.0.1:{port}"
        env["FANTASTIC_GROUP_TOKEN"] = token
        env["RELAY_INGRESS_RULE"] = "password"
        proc = subprocess.Popen(
            [str(self.binary)],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        if not _wait_tcp("127.0.0.1", port):
            out = proc.stdout.read().decode() if proc.stdout else ""
            proc.kill()
            raise RuntimeError(f"relayd (local) did not bind :{port}\n{out}")
        return RelayProc(port=port, token=token, label=label or "local", proc=proc)


class ContainerLauncher:
    """Run relayd inside the relay container image via podman/docker."""

    kind = "container"

    def __init__(self, image: str, engine: str) -> None:
        self.image = image
        self.engine = engine

    def start(self, port: int, *, token: str, label: str = "") -> RelayProc:
        name = f"relit-{port}-{os.getpid()}"
        subprocess.run([self.engine, "rm", "-f", name], capture_output=True, text=True)
        cmd = [
            self.engine,
            "run",
            "-d",
            "--name",
            name,
            # Publish loopback-only (host reaches it at 127.0.0.1:port). The
            # in-container entrypoint binds 0.0.0.0:$RELAY_PORT so the mapping lands.
            "-p",
            f"127.0.0.1:{port}:{port}",
            "-e",
            f"RELAY_PORT={port}",
            "-e",
            f"FANTASTIC_GROUP_TOKEN={token}",
            self.image,
        ]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"container start failed (:{port}): {r.stderr or r.stdout}")
        if not _wait_tcp("127.0.0.1", port):
            logs = subprocess.run(
                [self.engine, "logs", name], capture_output=True, text=True
            )
            subprocess.run([self.engine, "rm", "-f", name], capture_output=True, text=True)
            raise RuntimeError(f"relayd (container) did not bind :{port}\n{logs.stdout}{logs.stderr}")
        return RelayProc(
            port=port, token=token, label=label or "container", container=name, engine=self.engine
        )
