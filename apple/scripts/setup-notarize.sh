#!/usr/bin/env bash
# setup-notarize.sh — Store notarytool credentials in the system Keychain under
# profile name `FantasticNotarize` (shared across the Fantastic apps — it's a
# per-Mac credential, not per-app). Run once per Mac. After this, build-pro.sh
# notarizes without prompting.
#
# You need:
#   1. An Apple ID with a paid Developer Program seat.
#   2. An app-specific password generated at:
#        https://appleid.apple.com → Sign-In and Security → App-Specific Passwords
#
# Usage:
#   ./scripts/setup-notarize.sh                      # interactive prompt
#   NOTARY_PASSWORD=abcd-efgh-ijkl-mnop ./scripts/setup-notarize.sh
#
# Override defaults: NOTARY_PROFILE (FantasticNotarize), APPLE_ID, TEAM_ID.
set -euo pipefail

PROFILE="${NOTARY_PROFILE:-FantasticNotarize}"
APPLE_ID="${APPLE_ID:-kvazis@gmail.com}"
TEAM_ID="${TEAM_ID:-LSKNNBG94G}"

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "✓ Notarytool profile '$PROFILE' already configured."
    exit 0
fi

if [[ -n "${NOTARY_PASSWORD:-}" ]]; then
    PASSWORD="$NOTARY_PASSWORD"
else
    echo "App-specific password for $APPLE_ID (input hidden):"
    read -r -s -p "Paste it here: " PASSWORD
    echo
fi

if [[ -z "$PASSWORD" ]]; then
    echo "✗ No password provided. Aborting." >&2
    exit 1
fi

xcrun notarytool store-credentials "$PROFILE" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$PASSWORD"

unset PASSWORD NOTARY_PASSWORD
echo "✓ Stored. build-pro.sh will now notarize without prompting."
