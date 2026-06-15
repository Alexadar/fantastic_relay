"""A minimal relay WS client for the integration suite — the Python mirror of the
Swift `RelayWSClient`. Speaks the relay wire protocol:

  connect:  ws://host:port/<GUID>  subprotocol fantastic.relay.v1
                                   header X-Fantastic-Auth: <group password>
  client→:  {type:call|send|watch|unwatch, id?, target, payload}
  relay→:   {type:reply, id, data} | {type:event, source, payload}
"""

from __future__ import annotations

import asyncio
import json
import struct
from contextlib import asynccontextmanager

import websockets

SUBPROTOCOL = "fantastic.relay.v1"


def encode_stream(target: str, body: bytes, *, path: str = "payload.chunk") -> bytes:
    """Build a `[4B BE len | JSON header | raw body]` codec frame (the canvas
    io_bridge encoding) wrapping a relay `send` to `target`. The bytes value lives
    at `path` (nulled in the header, named by `_binary_path`)."""
    header = {
        "type": "send",
        "target": target,
        "payload": {"chunk": None},
        "_binary_path": path,
    }
    hb = json.dumps(header).encode("utf-8")
    return struct.pack(">I", len(hb)) + hb + body


def decode_stream(data: bytes) -> tuple[dict, bytes]:
    """Parse a `[4B len | header | body]` frame → (header dict, raw body)."""
    head_len = struct.unpack(">I", data[:4])[0]
    header = json.loads(data[4 : 4 + head_len].decode("utf-8"))
    return header, data[4 + head_len :]


class RelayWSError(Exception):
    pass


class RelayWS:
    def __init__(self, ws) -> None:
        self._ws = ws

    async def send(self, obj: dict) -> None:
        await self._ws.send(json.dumps(obj))

    async def recv(self, timeout: float = 3.0) -> dict:
        raw = await asyncio.wait_for(self._ws.recv(), timeout=timeout)
        return json.loads(raw)

    async def call(self, target: str, payload: dict, *, id: str = "1", timeout: float = 3.0) -> dict:
        await self.send({"type": "call", "id": id, "target": target, "payload": payload})
        return await self.recv(timeout)

    async def list_peers(self, *, timeout: float = 3.0) -> list[dict]:
        reply = await self.call("relay", {"type": "list_peers"}, timeout=timeout)
        return (reply.get("data") or {}).get("peers") or []

    async def expect_silence(self, window: float = 1.5) -> bool:
        """True iff NO frame arrives within `window` — the absence-of-frame assertion
        the no-leak tests hinge on (traffic must not cross engines). Works for text
        OR binary frames (it reads the raw WS message, never parses)."""
        try:
            await asyncio.wait_for(self._ws.recv(), timeout=window)
            return False  # received a frame → leak
        except asyncio.TimeoutError:
            return True  # silent → isolated

    async def send_bytes(self, data: bytes) -> None:
        await self._ws.send(data)

    async def recv_bytes(self, timeout: float = 3.0) -> bytes:
        raw = await asyncio.wait_for(self._ws.recv(), timeout=timeout)
        return raw if isinstance(raw, (bytes, bytearray)) else raw.encode("utf-8")


@asynccontextmanager
async def connect(port: int, guid: str, *, cred: str):
    """Connect a peer; raises on a refused upgrade (bad credential / dup GUID)."""
    uri = f"ws://127.0.0.1:{port}/{guid}"
    try:
        ws = await asyncio.wait_for(
            websockets.connect(
                uri,
                subprotocols=[SUBPROTOCOL],
                additional_headers={"X-Fantastic-Auth": cred},
            ),
            timeout=5.0,
        )
    except Exception as e:  # noqa: BLE001 — surface any handshake failure uniformly
        raise RelayWSError(str(e)) from e
    try:
        yield RelayWS(ws)
    finally:
        await ws.close()


async def try_connect_fails(port: int, guid: str, *, cred: str) -> bool:
    """True iff the connection is REFUSED (the relay rejected the upgrade). Used to
    assert credential isolation + duplicate-GUID rejection."""
    try:
        async with connect(port, guid, cred=cred):
            return False  # connected → not refused
    except RelayWSError:
        return True
