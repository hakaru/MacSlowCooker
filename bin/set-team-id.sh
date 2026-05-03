#!/usr/bin/env bash
# set-team-id.sh — replace the Apple Developer Team ID across every place the
# project pins it. Run this once after forking so the helper tool will accept
# XPC connections from your locally-signed app build.
#
# Usage:
#   bin/set-team-id.sh <NEW_TEAM_ID>
#
# Example:
#   bin/set-team-id.sh ABC1234XYZ
#
# Updates these locations:
#   - Shared/CodeSigningConfig.swift (Swift constant — runtime XPC requirement)
#   - HelperTool/Info.plist          (SMAuthorizedClients — install-time check)
#   - project.yml                    (DEVELOPMENT_TEAM — Xcode build setting)
#   - README.md                      (deploy instructions)
#   - CLAUDE.md                      (developer guide examples)
#
# After running, regenerate the Xcode project: `xcodegen generate`.

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <NEW_TEAM_ID>" >&2
    echo "       Team IDs are 10-character strings — find yours in Xcode →" >&2
    echo "       Settings → Accounts, or in your Apple Developer dashboard." >&2
    exit 64
fi

NEW="$1"

# Fail closed on malformed input. A typo or a string with shell-special
# characters would otherwise corrupt the substitutions below and produce
# a malformed code-signing requirement (Codex security audit, 2026-05-04,
# finding #15).
if [[ ! "$NEW" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "error: '$NEW' is not a valid 10-character uppercase-alphanumeric Team ID" >&2
    echo "       Find yours in Xcode → Settings → Accounts, or your Apple Developer dashboard." >&2
    exit 64
fi

# Find the current Team ID by looking at the Swift constant — that's the
# single source of truth for the runtime requirement.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/Shared/CodeSigningConfig.swift"
CURRENT="$(grep -oE 'teamOU = "[A-Z0-9]+"' "$CONFIG" | head -1 | sed -E 's/teamOU = "([A-Z0-9]+)"/\1/')"

if [ -z "$CURRENT" ]; then
    echo "error: could not find current Team ID in $CONFIG" >&2
    exit 1
fi

if [ "$CURRENT" = "$NEW" ]; then
    echo "Team ID already set to $NEW — nothing to do."
    exit 0
fi

echo "Replacing Team ID: $CURRENT → $NEW"

# Files to update. sed -i '' is BSD sed (macOS); -i alone would write a
# backup file with empty extension and fail.
FILES=(
    "$ROOT/Shared/CodeSigningConfig.swift"
    "$ROOT/HelperTool/Info.plist"
    "$ROOT/project.yml"
    "$ROOT/README.md"
    "$ROOT/CLAUDE.md"
)

for f in "${FILES[@]}"; do
    if [ -f "$f" ]; then
        sed -i '' -e "s/$CURRENT/$NEW/g" "$f"
        echo "  updated $(basename "$f")"
    fi
done

cat <<EOF

Done. Next steps:
  1. xcodegen generate
  2. Open Xcode → Signing & Capabilities → confirm both targets show your team
  3. Build and re-deploy: rm -rf /Applications/MacSlowCooker.app and re-install
     so SMAppService picks up the new authorized-clients requirement
EOF
