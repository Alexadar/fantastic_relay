#!/bin/sh
# Relay entrypoint — bind 0.0.0.0:$RELAY_PORT and exec relayd as the
# (tini-supervised) daemon. The relay is encryption-agnostic and always boots;
# it carries no workdir/state (peers are in-memory, identity is the connection).
#
#   RELAY_PORT             in-container listen port (default 9443); the host maps it
#   FANTASTIC_GROUP_TOKEN  the group password the `password` ingress rule checks
#                          (REQUIRED for the password rule; supply with -e at run)
#   RELAY_INGRESS_RULE     auth rule by name (default password)
#
# RELAY_LISTEN_ADDR is derived here as 0.0.0.0:$RELAY_PORT so a host-published port
# (`-p host:RELAY_PORT`) actually reaches the daemon — a loopback bind inside the
# container would be unreachable from the host. An explicit RELAY_LISTEN_ADDR
# passed by the operator wins.
set -eu

BIN="${RELAY_BIN:-/opt/relay/bin/relayd}"
PORT="${RELAY_PORT:-9443}"
export RELAY_LISTEN_ADDR="${RELAY_LISTEN_ADDR:-0.0.0.0:$PORT}"

if [ "${RELAY_INGRESS_RULE:-password}" = "password" ] && [ -z "${FANTASTIC_GROUP_TOKEN:-}" ]; then
  echo "entrypoint: WARNING — RELAY_INGRESS_RULE=password but FANTASTIC_GROUP_TOKEN is empty;" >&2
  echo "  every connection will be rejected. Supply it: -e FANTASTIC_GROUP_TOKEN=<password>" >&2
fi

echo "entrypoint: exec relayd — listen $RELAY_LISTEN_ADDR, ingress=${RELAY_INGRESS_RULE:-password}"
# exec → relayd becomes the process tini supervises; SIGTERM reaches it.
exec "$BIN"
