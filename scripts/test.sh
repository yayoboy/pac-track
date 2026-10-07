#!/bin/sh
# Runs Swift Testing with Command Line Tools only (no Xcode).
# Without these paths `swift test` builds but runs zero tests.
set -e
if [ -d /Applications/Xcode.app ]; then exec swift test "$@"; fi
DEV=/Library/Developer/CommandLineTools/Library/Developer
exec swift test \
  -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/usr/lib" \
  "$@"
