#!/bin/bash
# Assemble a standalone VentoyMac.app from the SwiftPM release binaries.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/VentoyMac.app"

find_binary() {
    local name="$1"
    local candidate
    for candidate in \
        "$ROOT/.build/out/Products/Release/$name" \
        "$ROOT/.build/arm64-apple-macosx/release/$name" \
        "$ROOT/.build/release/$name"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    echo "错误：找不到 $name，请先运行 make build" >&2
    return 1
}

BIN="$(find_binary VentoyMac)"
CLI="$(find_binary ventoymac-cli)"

echo "==> 使用可执行文件: $BIN"
echo "==> 使用 CLI 工具  : $CLI"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/VentoyMac"
cp "$CLI" "$APP/Contents/MacOS/ventoymac-cli"
chmod 755 "$APP/Contents/MacOS/VentoyMac" "$APP/Contents/MacOS/ventoymac-cli"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>VentoyMac</string>
    <key>CFBundleExecutable</key>
    <string>VentoyMac</string>
    <key>CFBundleIdentifier</key>
    <string>cn.ventoymac.VentoyMac</string>
    <key>CFBundleIconFile</key>
    <string>VentoyMac.icns</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>VentoyMac</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSArchitecturePriority</key>
    <array><string>arm64</string></array>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
</dict>
</plist>
PLIST

# Single source of truth for the build stamp. The running binary compares its
# compiled id with this file; if they differ, the GUI shows a "restart me"
# banner instead of silently executing an obsolete install script.
BUILD_ID="$(/usr/bin/sed -n 's/.*public static let id = "\([^"]*\)".*/\1/p' \
    "$ROOT/Sources/VentoyCore/VentoyBuild.swift" | /usr/bin/head -1)"
[ -n "$BUILD_ID" ] || BUILD_ID="unknown"
printf '%s\n' "$BUILD_ID" > "$APP/Contents/Resources/BuildID.txt"

# Generate a lightweight app icon without external dependencies.
TMP="$(mktemp -d -t vtoymac-icon)"
trap 'rm -rf "$TMP"' EXIT
ICONSET="$TMP/VentoyMac.iconset"
mkdir -p "$ICONSET"

/usr/bin/python3 - "$TMP/base.png" <<'PY'
import sys, math, struct, zlib
W = H = 1024
out = bytearray()

def seg_dist(px, py, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    t = max(0.0, min(1.0, (wx * vx + wy * vy) / (vx * vx + vy * vy)))
    return math.hypot(px - (ax + t * vx), py - (ay + t * vy))

margin, radius = 0.055 * W, 0.225 * W
x0, y0, x1, y1 = margin, margin, W - margin, H - margin

for y in range(H):
    out.append(0)
    for x in range(W):
        dx = max(x0 + radius - x, 0, x - (x1 - radius))
        dy = max(y0 + radius - y, 0, y - (y1 - radius))
        inside = x0 <= x <= x1 and y0 <= y <= y1 and dx * dx + dy * dy <= radius * radius
        if not inside:
            out.extend((0, 0, 0, 0))
            continue
        t = (x / W * 0.45 + y / H * 0.55)
        r = int(255 * (0.16 + 0.20 * t))
        g = int(255 * (0.42 - 0.12 * t))
        b = int(255 * (0.92 - 0.10 * t))
        width = 0.052 * W
        d1 = seg_dist(x, y, 0.29 * W, 0.34 * H, 0.50 * W, 0.70 * H)
        d2 = seg_dist(x, y, 0.50 * W, 0.70 * H, 0.71 * W, 0.34 * H)
        if min(d1, d2) <= width:
            r, g, b = 250, 252, 255
        out.extend((r, g, b, 255))

def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(bytes(out), 9))
       + chunk(b"IEND", b""))
open(sys.argv[1], "wb").write(png)
PY

for s in 16 32 128 256 512; do
    /usr/bin/sips -z "$s" "$s" "$TMP/base.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
done
for s in 32 64 256 512 1024; do
    base=$((s / 2))
    /usr/bin/sips -z "$s" "$s" "$TMP/base.png" --out "$ICONSET/icon_${base}x${base}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/VentoyMac.icns"

# The elevated writer helper must be a real .app bundle. A bare Mach-O has
# no Info.plist, so it can never satisfy `info[CFBundleVersion] >= "1"` in the
# designated requirement (codesign: "does not satisfy its Designated
# Requirement"). A nested bundle with its own Info.plist does satisfy it, which
# makes the user's Full Disk Access grant match the root process that spawns
# `dd` / `gpt` instead of security_authtrampoline.
WRITER="$APP/Contents/Resources/VentoyWriter.app"
mkdir -p "$WRITER/Contents/MacOS"
cp "$CLI" "$WRITER/Contents/MacOS/VentoyWriter"
chmod 755 "$WRITER/Contents/MacOS/VentoyWriter"
/usr/libexec/PlistBuddy \
    -c "Add :CFBundleIdentifier string cn.ventoymac.VentoyMac" \
    -c "Add :CFBundleVersion string 1" \
    -c "Add :CFBundleShortVersionString string 1.0.0" \
    -c "Add :CFBundleExecutable string VentoyWriter" \
    -c "Add :CFBundlePackageType string APPL" \
    -c "Add :CFBundleName string VentoyMacWriter" \
    -c "Add :LSMinimumSystemVersion string 13.0" \
    "$WRITER/Contents/Info.plist" >/dev/null

# A stable designated requirement keeps the user's "Full Disk Access" grant
# valid across rebuilds. Plain ad-hoc signing keys TCC identity to the cdhash,
# which changes on every rebuild and silently revokes an existing grant.
VTOY_REQ='=designated => identifier "cn.ventoymac.VentoyMac" and info[CFBundleVersion] >= "1"'
/usr/bin/codesign --force --sign - "$APP/Contents/MacOS/VentoyMac" >/dev/null 2>&1 || true
/usr/bin/codesign --force --sign - "$APP/Contents/MacOS/ventoymac-cli" >/dev/null 2>&1 || true
/usr/bin/codesign --force --sign - --requirements "$VTOY_REQ" "$WRITER" >/dev/null 2>&1 || \
    echo "警告：helper 签名失败，提权通道可能无法继承完全磁盘访问。"
/usr/bin/codesign --force --sign - --requirements "$VTOY_REQ" "$APP" >/dev/null 2>&1 || \
    echo "警告：ad-hoc 签名失败，应用仍可本地运行。"
/usr/bin/codesign --verify --strict "$APP" >/dev/null 2>&1 || \
    echo "警告：签名校验未通过，完全磁盘访问授权可能不稳定。"
/usr/bin/codesign --verify --strict "$WRITER" >/dev/null 2>&1 || \
    echo "警告：helper 签名校验未通过。"

/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null
echo "==> 已生成: $APP"
echo "==> 构建标识: $BUILD_ID"
echo "==> 架构: $(/usr/bin/lipo -archs "$APP/Contents/MacOS/VentoyMac")"
echo "==> 签名标识: $(/usr/bin/codesign -d -r- "$APP" 2>&1 | /usr/bin/grep designated || echo 'cdhash（重编译会使 FDA 授权失效）')"
echo "==> helper 标识: $(/usr/bin/codesign -d -r- "$WRITER" 2>&1 | /usr/bin/grep designated || echo 'cdhash')"
