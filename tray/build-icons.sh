#!/usr/bin/env bash
# Rebuild the tray icons' images from their SVGs:
#
#   status status-icons.png, every tray icon's status icon, from status.svg. A
#          sheet of each status and theme at each size (see below).
#
# and their app icons from novacore.svg, Novacore's project icon from
# jonbp.github.io/project-icons/novacore.svg without its animation:
#
#   ico    tray/windows/novacore.ico, for NovacoreTray.exe, its notifications and
#          windows. Each size is stored in it as a PNG.
#   icns   tray/macos/novacore.icns, for Novacore Tray.app. Its images are inset on
#          the canvas like other macOS app icons, rather than filling it.
#
# Each size is rendered straight from the SVG by headless Chrome, which
# antialiases far better than drawing it at runtime. Set CHROME to use a
# particular one. Run it after changing an SVG, and commit the results. With no
# arguments it builds all three.
set -euo pipefail

cd "$(dirname "$0")"
targets=("$@")
(( ${#targets[@]} )) || targets=(status ico icns)

chrome=${CHROME:-}
[[ -n $chrome ]] || chrome=$(command -v google-chrome || command -v chromium || command -v chromium-browser ||
    ls "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" 2>/dev/null) ||
    { echo "Needs Chrome or Chromium to render the SVG" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp novacore.svg "$tmp/"

# shot WIDTH HEIGHT OUT — a screenshot of $tmp/page.html.
shot() {
    "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
        --default-background-color=00000000 --window-size="$1,$2" \
        --screenshot="$3" "file://$tmp/page.html" 2>/dev/null
}

# render SIZE SCALE OUT — the icon on a SIZE px canvas, SCALE of its width.
render() {
    local n=$1 side
    side=$(awk -v n="$1" -v s="$2" 'BEGIN { printf "%d", n * s + 0.5 }')
    cat > "$tmp/page.html" <<EOF
<!doctype html><style>html,body{margin:0;background:transparent;overflow:hidden;width:${n}px;height:${n}px;display:grid;place-items:center}img{display:block;width:${side}px;height:${side}px}</style><img src="novacore.svg">
EOF
    shot "$n" "$n" "$3"
}

for target in "${targets[@]}"; do
    case $target in
        status)
            # The sheet: a 64px square cell per image, with the icon in its top
            # left corner. A row per theme and status, dark then light, each
            # running, stopped, busy then error, and a column per size, 16 20
            # 24 28 32 36 40 48 and 64px: Windows' sizes from 100% to 300%
            # scaling, and the others' 1x and 2x. The tray icons rely on this
            # layout, as STATUS_SIZES and the like.
            python3 - "$tmp" <<'EOF'
import sys
tmp = sys.argv[1]
source = open("status.svg").read()
sizes = [16, 20, 24, 28, 32, 36, 40, 48, 64]
# jonbp.co.uk's palette in its dark and light themes. The globe is the text
# colour: white, or black at 85% like other symbolic icons. Running is
# Novacore's neon teal, stopped the secondary text colour, busy and error neon
# yellow and red.
themes = [
    ("#ffffff", "1", ["#17D4A4", "#768087", "#FEC82C", "#FE2C62"]),
    ("#000000", "0.85", ["#009672", "#58626A", "#C48C00", "#DE184C"]),
]
# Inline, not <img>s, so Chrome doesn't take the screenshot before they load.
# Each needs its own mask id.
cells = []
for t, (globe, opacity, badges) in enumerate(themes):
    for s, badge in enumerate(badges):
        row = t * len(badges) + s
        for col, n in enumerate(sizes):
            svg = (source.replace("{{GLOBE}}", globe).replace("{{GLOBE_OPACITY}}", opacity)
                   .replace("{{BADGE}}", badge)
                   .replace('"cut"', f'"cut{row}-{n}"').replace("#cut)", f"#cut{row}-{n})")
                   .replace('width="24" height="24"', f'width="{n}" height="{n}"'))
            cells.append(f'<div style="left:{col * 64}px;top:{row * 64}px">{svg}</div>')
open(f"{tmp}/page.html", "w").write(
    "<!doctype html><style>html,body{margin:0;background:transparent}"
    "div{position:absolute;line-height:0}svg{display:block}</style>" + "".join(cells))
EOF
            # Headless Chrome only paints what fits its window less the room
            # for its UI, so render it taller, and keep the sheet's rows.
            shot 576 768 "$tmp/sheet.png"
            python3 - "$tmp/sheet.png" status-icons.png 576 512 <<'EOF'
import struct, sys, zlib
src, out, width, height = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
png = open(src, "rb").read()
chunks, at = [], 8
while at < len(png):
    n, kind = struct.unpack(">I4s", png[at:at + 8])
    chunks.append((kind, png[at + 8:at + 8 + n]))
    at += 12 + n
ihdr = chunks[0][1]
w, h, depth, color = struct.unpack(">IIBB", ihdr[:10])
if (w, depth, color) != (width, 8, 6) or h < height:
    sys.exit("Chrome rendered the status icons at the wrong size")
# Each row is a filter byte and RGBA pixels, and depends only on the rows above
# it, so the top rows stand on their own.
rows = zlib.decompress(b"".join(d for k, d in chunks if k == b"IDAT"))[:height * (1 + 4 * width)]
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
open(out, "wb").write(png[:8] + chunk(b"IHDR", struct.pack(">II", width, height) + ihdr[8:])
                      + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))
EOF
            echo "Wrote tray/status-icons.png"
            ;;
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
open("windows/novacore.ico", "wb").write(out + b"".join(images))
EOF
            echo "Wrote tray/windows/novacore.ico"
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
            iconutil -c icns -o macos/novacore.icns "$set"
            echo "Wrote tray/macos/novacore.icns"
            ;;
        *) echo "Unknown target '$target': use status, ico or icns" >&2; exit 1 ;;
    esac
done
