#!/bin/zsh
# Builds and runs the headless VM smoke harness (signed with the
# virtualization entitlement).
# Usage: Support/vm-smoke.sh [wipe|hold|disk-report|clone-smoke]
set -euo pipefail
cd "$(dirname "$0")/.."

PLUGINS=/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins
swift build -c release --product VetroVMSmoke -Xswiftc -plugin-path -Xswiftc "$PLUGINS"
BIN="$(swift build -c release --product VetroVMSmoke --show-bin-path -Xswiftc -plugin-path -Xswiftc "$PLUGINS")/VetroVMSmoke"
codesign --force --sign - --entitlements Support/Vetro.entitlements "$BIN"
exec "$BIN" "$@"
