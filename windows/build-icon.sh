#!/usr/bin/env bash
# Rebuild novacore.ico, the tray icon app's own icon (for NovacoreTray.exe,
# its notifications and windows), from novacore.svg: Novacore's project icon
# from jonbp.github.io/project-icons/novacore.svg, without its animation.
#
# Each size is rendered straight from the SVG by headless Chrome, which
# antialiases far better than drawing it with GDI+ on Windows, and stored in
# the .ico as a PNG. Run it after changing novacore.svg, and commit both.
set -euo pipefail

cd "$(dirname "$0")"
chrome=$(command -v google-chrome || command -v chromium || command -v chromium-browser) ||
    { echo "Needs Chrome or Chromium to render the SVG" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp novacore.svg "$tmp/"

sizes=(16 20 24 32 40 48 64 256)
for n in "${sizes[@]}"; do
    cat > "$tmp/$n.html" <<EOF
<!doctype html><style>html,body{margin:0;background:transparent;overflow:hidden}img{display:block;width:${n}px;height:${n}px}</style><img src="novacore.svg">
EOF
    "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
        --default-background-color=00000000 --window-size="$n,$n" \
        --screenshot="$tmp/$n.png" "file://$tmp/$n.html" 2>/dev/null
done

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
open("novacore.ico", "wb").write(out + b"".join(images))
EOF
echo "Wrote $(pwd)/novacore.ico"
