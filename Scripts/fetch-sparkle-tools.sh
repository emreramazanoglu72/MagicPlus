#!/bin/bash
#
# Puts Sparkle's command-line tools (generate_appcast, sign_update) in Tools/sparkle/bin.
#
# The SwiftPM checkout carries only their source, so the tools come from the official release
# tarball — at the exact version the app links against, read from Package.resolved rather than
# written down here. A signing tool one version away from the framework is the kind of mismatch
# that is only discovered by shipping an update nobody can install.
#
# Idempotent: does nothing when the right version is already present.

set -euo pipefail
cd "$(dirname "$0")/.."

RESOLVED="tabmenu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
DEST="Tools/sparkle"
STAMP="$DEST/.version"

VERSION=$(python3 -c '
import json, sys
pins = json.load(open(sys.argv[1]))["pins"]
print(next(p["state"]["version"] for p in pins if p["identity"] == "sparkle"))
' "$RESOLVED")

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$VERSION" && -x "$DEST/bin/generate_appcast" ]]; then
  echo "Sparkle tools $VERSION already present."
  exit 0
fi

echo "==> Fetching Sparkle $VERSION tools"
TARBALL=$(mktemp -t sparkle).tar.xz
trap 'rm -f "$TARBALL"' EXIT
curl -fsSL -o "$TARBALL" \
  "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"

rm -rf "$DEST"
mkdir -p "$DEST"
tar -xJf "$TARBALL" -C "$DEST" bin
echo "$VERSION" > "$STAMP"
echo "Sparkle tools $VERSION → $DEST/bin"
