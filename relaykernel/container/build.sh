#!/bin/sh
# Build the headless relay-kernel image LOCALLY (push deferred).
#
#   sh container/build.sh                  # host-arch build → relay:latest
#   TAG=relay:0.1.0 sh container/build.sh  # custom tag
#   ARCH=amd64 sh container/build.sh       # one arch (emulated on arm host) → relay:amd64
#
# Works with podman OR docker. Swift is compiled FROM SOURCE in the image — both
# this relay package AND the canvas kernel it reuses as a path-dependency library.
# Because the path dep lives OUTSIDE the relay repo (../../fantastic_canvas/swift),
# this script STAGES both package trees into container/.ctx with the path-dep
# layout preserved, then builds with that as the context:
#
#   .ctx/fantastic_relay/relaykernel/   the relay package  → /src/fantastic_relay/relaykernel
#   .ctx/fantastic_canvas/swift/        the canvas kernel  → /src/fantastic_canvas/swift
#
# mirroring the host's two-level layout, so the relative path dep
# `../../fantastic_canvas/swift` (from .../fantastic_relay/relaykernel) resolves
# inside the build stage.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)          # relaykernel/container
RELAY=$(CDPATH= cd -- "$HERE/.." && pwd)                   # relaykernel
CANVAS=$(CDPATH= cd -- "$RELAY/../../fantastic_canvas/swift" && pwd)
TAG="${TAG:-relay:latest}"
ARCH="${ARCH:-}"
PUSH="${PUSH:-0}"
VERSION="${RELAY_VERSION:-dev}"
CTX="$HERE/.ctx"

# ── pick an engine ─────────────────────────────────────────────────────────
if command -v podman >/dev/null 2>&1; then ENGINE=podman
elif command -v docker >/dev/null 2>&1; then ENGINE=docker
else echo "build.sh: need podman or docker" >&2; exit 1; fi

# ── stage the build context (both package trees, no build caches/VCS) ───────
echo "build.sh: staging context at $CTX"
rm -rf "$CTX"
mkdir -p "$CTX/fantastic_relay/relaykernel" "$CTX/fantastic_canvas/swift"
# rsync keeps it fast + lets us prune .build/.git/.ctx; fall back to cp -R.
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude '.build/' --exclude '.git/' --exclude 'container/.ctx/' \
    --exclude '.ctx/' --exclude 'integration_tests/.venv/' \
    "$RELAY/" "$CTX/fantastic_relay/relaykernel/"
  rsync -a --delete --exclude '.build/' --exclude '.git/' \
    "$CANVAS/" "$CTX/fantastic_canvas/swift/"
else
  cp -R "$RELAY/" "$CTX/fantastic_relay/relaykernel/"
  rm -rf "$CTX/fantastic_relay/relaykernel/.build" "$CTX/fantastic_relay/relaykernel/.git" \
    "$CTX/fantastic_relay/relaykernel/container/.ctx"
  cp -R "$CANVAS/" "$CTX/fantastic_canvas/swift/"
  rm -rf "$CTX/fantastic_canvas/swift/.build" "$CTX/fantastic_canvas/swift/.git"
fi

# ── pin host platform (avoid reusing a stale wrong-arch base in the store) ──
case "$(uname -m)" in
  arm64|aarch64) HOSTPLAT=linux/arm64 ;;
  x86_64|amd64)  HOSTPLAT=linux/amd64 ;;
  *) HOSTPLAT="" ;;
esac
[ -n "$ARCH" ] && case "$ARCH" in
  amd64) HOSTPLAT=linux/amd64 ;;
  arm64) HOSTPLAT=linux/arm64 ;;
  *) echo "build.sh: ARCH must be amd64|arm64 (got '$ARCH')" >&2; exit 2 ;;
esac

echo "build.sh: $ENGINE build $TAG (platform='${HOSTPLAT:-default}', version=$VERSION)"
if [ -n "$HOSTPLAT" ]; then
  "$ENGINE" build --platform "$HOSTPLAT" --build-arg "RELAY_VERSION=$VERSION" \
    -f "$HERE/Containerfile" -t "$TAG" "$CTX"
else
  "$ENGINE" build --build-arg "RELAY_VERSION=$VERSION" \
    -f "$HERE/Containerfile" -t "$TAG" "$CTX"
fi

[ "$PUSH" = 1 ] && "$ENGINE" push "$TAG" || echo "build.sh: push skipped (set PUSH=1 to publish)"
echo "build.sh: done -> $TAG"
