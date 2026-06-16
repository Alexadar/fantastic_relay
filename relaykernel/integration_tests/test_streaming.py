"""Binary pure-stream routing through the relay — the io_bridge codec
(`[4B len | JSON header | raw body]`, no base64) traversing real relay instances,
run interchangeably via `RELAY_TARGET=local|container`.

Proves the relay forwards BINARY WS frames (routing on the header `target`) so a
raw `read_stream` chunk rides the wire verbatim — and that binary routing obeys the
SAME per-instance isolation as text (a colliding GUID across relays does not leak).
"""

from __future__ import annotations

import pytest

from helpers.ws import connect, decode_stream, encode_stream

pytestmark = pytest.mark.asyncio

# Deliberately non-UTF8 bytes → proves verbatim transport (no base64 / text coercion).
RAW = bytes([0x00, 0xFF, 0xFE, 0xDE, 0xAD, 0xBE, 0xEF, 0x80, 0x01, 0x7F])


async def test_binary_stream_routing(relays):
    """A → B over one relay: the binary frame arrives as a binary `event` from A
    with the body bytes intact."""
    (r,) = relays(1)

    async with connect(r.port, "A", cred=r.token) as a, connect(r.port, "B", cred=r.token) as b:
        await a.send_bytes(encode_stream("B", RAW))

        header, body = decode_stream(await b.recv_bytes(3))
        assert header["type"] == "event"
        assert header["source"] == "A"
        assert header["_binary_path"] == "payload.chunk"
        assert body == RAW  # byte-for-byte


async def test_binary_no_leak_on_guid_collision(relays):
    """GUID "TARGET" connected to relay 1 AND relay 2; a binary send on relay 1
    reaches only relay 1's TARGET. Relay 2's identically-named TARGET stays silent —
    binary routing is per-instance isolated, same as text."""
    r1, r2 = relays(2)

    async with connect(r1.port, "SENDER", cred=r1.token) as sender1, connect(
        r1.port, "TARGET", cred=r1.token
    ) as target1, connect(r2.port, "TARGET", cred=r2.token) as target2:
        await sender1.send_bytes(encode_stream("TARGET", RAW))

        header, body = decode_stream(await target1.recv_bytes(3))
        assert header["source"] == "SENDER"
        assert body == RAW

        assert await target2.expect_silence(1.5), "relay 2's TARGET must not receive binary traffic"
