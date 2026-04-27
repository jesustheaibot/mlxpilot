#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Skip the rm -rf .build (permissions issues), just rebuild
swift build -c release 2>&1

APP="dist/MLX Pilot.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" 2>/dev/null || true

# Remove old binary only
rm -f "$APP/Contents/MacOS/MLX Pilot" 2>/dev/null || true

cp ".build/release/MLX Pilot" "$APP/Contents/MacOS/MLX Pilot"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>MLX Pilot</string>
    <key>CFBundleIdentifier</key><string>org.mlxpilot.app</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>MLX Pilot</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
chmod +x "$APP/Contents/MacOS/MLX Pilot"
echo "Built: $ROOT/$APP"
