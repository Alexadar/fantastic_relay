"""Shared fixtures for the relay integration suite.

Target selection mirrors canvas: `RELAY_TARGET=local` (default) runs the
locally-built `relayd` binary; `RELAY_TARGET=container` runs the shipped relay
image — the SAME tests validate both ("standalone and container interchangeable").
`RELAY_IMAGE` overrides the image tag.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from helpers.launcher import (  # noqa: E402
    ContainerLauncher,
    LocalLauncher,
    RelayProc,
    free_port,
    resolve_engine,
)

# relaykernel/ is one level up from integration_tests/.
_PKG_ROOT = _HERE.parent

_TARGET = os.environ.get("RELAY_TARGET", "local").strip().lower()
_IMAGE = os.environ.get("RELAY_IMAGE", "relay:latest")


@pytest.fixture(scope="session")
def launcher():
    """A `LocalLauncher` (default) or `ContainerLauncher` over the relay image.

    Local skips if relayd isn't built; container skips if no engine / image is
    present — so either target run is self-gating, never a hard failure on a box
    that lacks the prerequisite.
    """
    if _TARGET == "container":
        engine = resolve_engine()
        if engine is None:
            pytest.skip("RELAY_TARGET=container but no podman/docker found")
        present = subprocess.run(
            [engine, "image", "inspect", _IMAGE], capture_output=True, text=True
        )
        if present.returncode != 0:
            pytest.skip(
                f"RELAY_TARGET=container but image {_IMAGE!r} not built "
                f"(run `sh container/build.sh`)"
            )
        return ContainerLauncher(_IMAGE, engine)

    candidates = [
        _PKG_ROOT / ".build" / "release" / "relayd",
        _PKG_ROOT / ".build" / "debug" / "relayd",
    ]
    existing = [c for c in candidates if c.exists()]
    if not existing:
        pytest.skip(
            f"relayd not built: tried {[str(c) for c in candidates]} "
            f"(run `cd relaykernel && swift build`)"
        )
    return LocalLauncher(max(existing, key=lambda p: p.stat().st_mtime))


@pytest.fixture
def relays(launcher):
    """Factory: spin up N relay instances (distinct ports + tokens), torn down at
    test end. Returns a callable `make(n, tokens=...) -> list[RelayProc]`."""
    started: list[RelayProc] = []

    def make(n: int, tokens: list[str] | None = None) -> list[RelayProc]:
        toks = tokens or [f"secret{i+1}" for i in range(n)]
        assert len(toks) == n, "tokens must match n"
        for i in range(n):
            r = launcher.start(free_port(), token=toks[i], label=f"relay{i+1}")
            started.append(r)
        return list(started)

    yield make

    for r in reversed(started):
        r.stop()
