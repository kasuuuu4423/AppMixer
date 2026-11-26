#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product AppMixer
bin_dir="$(swift build -c release --show-bin-path)"
app="dist/AppMixer.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/AppMixer" "$app/Contents/MacOS/AppMixer"
cp Packaging/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
