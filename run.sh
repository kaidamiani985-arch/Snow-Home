#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

# Replace a running copy so the new build is what you see.
pkill -f "Snow On Mac.app/Contents/MacOS/SnowOnMac" 2>/dev/null || true
sleep 0.3

open "Snow On Mac.app"
echo "Running. Look for the snowflake in the menu bar."
