"""Isolation / no-leak integration tests — the security contract across REAL
relay instances (separate `relayd` processes, or separate containers), run
interchangeably via `RELAY_TARGET=local|container`.

Where the Swift `IsolationTests` prove per-engine isolation inside ONE process,
these prove it across the deployment boundary the supervisor actually uses: N
independent relays, external connectors, NO interkernel routing, no leakage —
even when GUIDs collide across instances.
"""

from __future__ import annotations

import pytest

from helpers.ws import connect, try_connect_fails

pytestmark = pytest.mark.asyncio


async def test_single_relay_directory_and_auth(relays):
    """Smoke (both targets): a peer connects, the directory lists it green, and a
    wrong credential is refused."""
    (r,) = relays(1, tokens=["secret1"])

    async with connect(r.port, "ALPHA", cred="secret1") as a:
        peers = await a.list_peers()
        assert [p["guid"] for p in peers] == ["ALPHA"]
        assert peers[0]["status"] == "green"

    assert await try_connect_fails(r.port, "BADGE", cred="wrong-password")


async def test_directory_isolation(relays):
    """Each relay's directory is private — a peer on one is invisible to the others."""
    r1, r2, r3 = relays(3)

    async with connect(r1.port, "ALPHA", cred=r1.token) as a, connect(
        r2.port, "BETA", cred=r2.token
    ) as b:
        assert [p["guid"] for p in await a.list_peers()] == ["ALPHA"]
        assert [p["guid"] for p in await b.list_peers()] == ["BETA"]

        # r3 has no peers and certainly not the others'.
        async with connect(r3.port, "PROBE", cred=r3.token) as c:
            assert [p["guid"] for p in await c.list_peers()] == ["PROBE"]


async def test_no_cross_engine_routing_on_guid_collision(relays):
    """The core no-leak test. GUID "TARGET" is connected to relay 1 AND relay 2.
    A sender on relay 1 routes to "TARGET" → only relay 1's TARGET receives it;
    relay 2's identically-named TARGET stays SILENT. The collision does not bridge."""
    r1, r2 = relays(2)

    async with connect(r1.port, "SENDER", cred=r1.token) as sender1, connect(
        r1.port, "TARGET", cred=r1.token
    ) as target1, connect(r2.port, "TARGET", cred=r2.token) as target2:
        await sender1.send(
            {"type": "send", "target": "TARGET", "payload": {"ping": "from-relay-1"}}
        )

        ev = await target1.recv(3)
        assert ev["type"] == "event"
        assert ev["source"] == "SENDER"
        assert ev["payload"]["ping"] == "from-relay-1"

        assert await target2.expect_silence(1.5), "relay 2's TARGET must not receive relay 1's traffic"


async def test_credential_isolation(relays):
    """Per-instance credentials: relay 1 rejects relay 2's group password."""
    r1, r2 = relays(2, tokens=["secret-one", "secret-two"])

    assert await try_connect_fails(r1.port, "INTRUDER", cred="secret-two")
    # Sanity: r1's own secret still works (the gate isn't rejecting everything).
    async with connect(r1.port, "MEMBER", cred="secret-one") as m:
        assert [p["guid"] for p in await m.list_peers()] == ["MEMBER"]


async def test_targeted_routing_no_broadcast(relays):
    """Within ONE relay, A→B reaches only B; a third peer C receives nothing."""
    (r,) = relays(1)

    async with connect(r.port, "A", cred=r.token) as a, connect(
        r.port, "B", cred=r.token
    ) as b, connect(r.port, "C", cred=r.token) as c:
        await a.send({"type": "send", "target": "B", "payload": {"msg": "for-b-only"}})

        ev = await b.recv(3)
        assert ev["type"] == "event"
        assert ev["payload"]["msg"] == "for-b-only"

        assert await c.expect_silence(1.5), "peer C must not receive a frame targeted at B"
