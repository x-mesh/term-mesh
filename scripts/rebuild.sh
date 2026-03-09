#!/bin/bash
# Rebuild and restart term-mesh app

set -e

cd "$(dirname "$0")/.."

# Kill existing app if running
pkill -9 -f "term-mesh" 2>/dev/null || true

# Build
swift build

# Copy to app bundle
cp .build/debug/term-mesh .build/debug/term-mesh.app/Contents/MacOS/

# Open the app
open .build/debug/term-mesh.app
