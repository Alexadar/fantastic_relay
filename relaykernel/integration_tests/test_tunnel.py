"""Live end-to-end through a real cloudflared named tunnel.

CONDITIONAL: runs only when `RELAY_TUNNEL_URL` is exported (with `RELAY_TUNNEL_TOKEN`)
— otherwise skipped. The tunnel hostname is therefore NEVER stored in the repo / CI;
the operator supplies it locally:

    RELAY_TUNNEL_URL=wss://relay.example.com RELAY_TUNNEL_TOKEN=<pw> \
      uv run --project integration_tests pytest integration_tests/test_tunnel.py -v

Requires `relayd` running on its listen port AND `cloudflared tunnel run <name>` up.
"""

from __future__ import annotations

import pytest

from helpers.ws import connect_url

pytestmark = pytest.mark.asyncio


async def test_tunnel_directory_and_routing(tunnel):
    """Through the public wss:// tunnel: a peer authenticates + appears green in the
    directory, and A→B routing works end-to-end over the real edge."""
    url, token = tunnel

    # Auth + directory through the tunnel.
    async with connect_url(url, "TUNNEL_A", cred=token) as a:
        peers = await a.list_peers(timeout=8.0)
        guids = [p["guid"] for p in peers]
        assert "TUNNEL_A" in guids
        assert next(p["status"] for p in peers if p["guid"] == "TUNNEL_A") == "green"

        # A→B routing across the edge.
        async with connect_url(url, "TUNNEL_B", cred=token) as b:
            await a.send({"type": "send", "target": "TUNNEL_B", "payload": {"hi": "via-tunnel"}})
            ev = await b.recv(8.0)
            assert ev["type"] == "event"
            assert ev["source"] == "TUNNEL_A"
            assert ev["payload"]["hi"] == "via-tunnel"


async def test_tunnel_rejects_bad_credential(tunnel):
    """A wrong group password is refused at the upgrade, even through the tunnel."""
    from helpers.ws import RelayWSError

    url, _ = tunnel
    with pytest.raises(RelayWSError):
        async with connect_url(url, "TUNNEL_X", cred="definitely-wrong"):
            pass
