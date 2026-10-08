#!/bin/sh
# End-to-end check without Xcode: drives the real Editor + Simulation, renders the window to PNG.
set -e
cd "$(dirname "$0")/.."
OUT="${1:-build/selftest.png}"
mkdir -p "$(dirname "$OUT")"
swift build --product PacTrack
exec .build/debug/PacTrack --selftest "$OUT"
