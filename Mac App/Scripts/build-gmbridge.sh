#!/bin/bash
# Builds Gmbridge.xcframework (the Go libgm protocol layer) for the Mac app.
#
# Prerequisites: Go 1.25+ (brew install go) and Xcode command line tools.
# Usage: ./build-gmbridge.sh [--update]
#   --update   re-resolve mautrix-gmessages to latest main instead of the
#              pinned known-working commit (use when Google changes the
#              protocol and upstream has already adapted).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$SCRIPT_DIR/../GmBridge"
BUILD_DIR="$BRIDGE_DIR/build"

# Known-working protocol version (studied 2026-07; mautrix/gmessages main).
PINNED_COMMIT="3433cc07d5ea9522309adad3a8c92ed5b08dc11d"

if ! command -v go >/dev/null; then
  echo "error: Go is not installed. Run: brew install go" >&2
  exit 1
fi

# gomobile needs full Xcode, not the standalone Command Line Tools.
if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  echo "error: xcode-select points to '$(xcode-select -p 2>/dev/null)'." >&2
  echo "gomobile needs full Xcode. Fix with:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

GOBIN="$(go env GOPATH)/bin"
export PATH="$GOBIN:$PATH"

if ! command -v gomobile >/dev/null; then
  echo "==> Installing gomobile"
  go install golang.org/x/mobile/cmd/gomobile@latest
  go install golang.org/x/mobile/cmd/gobind@latest
fi

cd "$BRIDGE_DIR"

REF="$PINNED_COMMIT"
if [[ "${1:-}" == "--update" ]]; then
  REF="main"
fi

echo "==> Resolving dependencies (mautrix-gmessages @ $REF)"
go get "go.mau.fi/mautrix-gmessages@$REF"
# gomobile needs x/mobile in the module graph; the tool directive keeps
# it there across `go mod tidy` (required by Go 1.24+ behavior).
go get -tool golang.org/x/mobile/cmd/gobind@latest
go mod tidy

echo "==> Building Gmbridge.xcframework (this can take a few minutes)"
mkdir -p "$BUILD_DIR"
gomobile init
gomobile bind -target macos -o "$BUILD_DIR/Gmbridge.xcframework" .

echo "==> Done: $BUILD_DIR/Gmbridge.xcframework"
echo "    Open the Xcode project and build; the framework is already referenced."
