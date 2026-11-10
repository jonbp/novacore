#!/usr/bin/env bash
# Rebuild the tray icons' app icons from novacore.svg, Novacore's project icon
# from jonbp.github.io/project-icons/novacore.svg without its animation:
#
#   ico    windows/novacore.ico, for NovacoreTray.exe, its notifications and
#          windows. Each size is stored in it as a PNG.
#   icns   macos/novacore.icns, for Novacore Tray.app. Its images are inset on
#          the canvas like other macOS app icons, rather than filling it.
#
# Each size is rendered straight from the SVG by headless Chrome, which
# antialiases far better than drawing it at runtime. Run it after changing
# novacore.svg, and commit the results. With no arguments it builds both.
set -euo pipefail

cd "$(dirname "$0")"
targets=("$@")
(( ${#targets[@]} )) || targets=(ico icns)

chrome=$(command -v google-chrome || command -v chromium || command -v chromium-browser ||
    ls "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" 2>/dev/null) ||
    { echo "Needs Chrome or Chromium to render the SVG" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp novacore.svg "$tmp/"

# render SIZE SCALE OUT — the icon on a SIZE px canvas, SCALE of its width.
render() {
    local n=$1 side
    side=$(awk -v n="$1" -v s="$2" 'BEGIN { printf "%d", n * s + 0.5 }')
    cat > "$tmp/page.html" <<EOF
<!doctype html><style>html,body{margin:0;background:transparent;overflow:hidden;width:${n}px;height:${n}px;display:grid;place-items:center}img{display:block;width:${side}px;height:${side}px}</style><img src="novacore.svg">
EOF
    "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
        --default-background-color=00000000 --window-size="$n,$n" \
        --screenshot="$3" "file://$tmp/page.html" 2>/dev/null
}

for target in "${targets[@]}"; do
    case $target in
        ico)
            sizes=(16 20 24 32 40 48 64 256)
            for n in "${sizes[@]}"; do render "$n" 1 "$tmp/$n.png"; done
            # An .ico is a 6-byte header, a 16-byte entry per image, then the images.
            python3 - "$tmp" "${sizes[@]}" <<'EOF'
import struct, sys
tmp, sizes = sys.argv[1], [int(n) for n in sys.argv[2:]]
images = [open(f"{tmp}/{n}.png", "rb").read() for n in sizes]
for n, png in zip(sizes, images):
    if struct.unpack(">II", png[16:24]) != (n, n):
        sys.exit(f"Chrome rendered the {n}px icon at the wrong size")
out = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
for n, png in zip(sizes, images):
    # A width and height of 0 stand for 256.
    out += struct.pack("<BBBBHHII", n % 256, n % 256, 0, 0, 1, 32, len(png), offset)
    offset += len(png)
open("../windows/novacore.ico", "wb").write(out + b"".join(images))
EOF
            echo "Wrote windows/novacore.ico"
            ;;
        icns)
            command -v iconutil >/dev/null || { echo "Building the .icns needs macOS's iconutil" >&2; exit 1; }
            set="$tmp/novacore.iconset"
            mkdir -p "$set"
            # Apple's app icon grid: an 824px body on a 1024px canvas.
            for n in 16 32 128 256 512; do
                render "$n" 0.8047 "$set/icon_${n}x${n}.png"
                render $(( n * 2 )) 0.8047 "$set/icon_${n}x${n}@2x.png"
            done
            iconutil -c icns -o ../macos/novacore.icns "$set"
            echo "Wrote macos/novacore.icns"
            ;;
        *) echo "Unknown target '$target': use ico or icns" >&2; exit 1 ;;
    esac
done
