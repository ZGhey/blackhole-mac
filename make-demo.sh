#!/bin/sh
# Regenerate docs/demo.gif — every style in turn, over a still of a real screen.
#
#   screencapture -x docs/backdrop.png     # tidy the desktop first; it goes public
#   ./make-demo.sh
#
# The backdrop is not committed, only the gif that comes out of it. Rerun when
# the styles change or the look moves; the result is committed.
set -e
cd "$(dirname "$0")"

BACKDROP="${1:-docs/backdrop.png}"
if [ ! -f "$BACKDROP" ]; then
    echo "no backdrop at $BACKDROP" >&2
    echo "take one with:  screencapture -x $BACKDROP" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p docs

swift run render-demo Sources/BlackHoleApp/BlackHole.metal "$BACKDROP" "$TMP/frames"

# Two passes. One palette for the whole animation, or the styles flicker as
# each frame picks its own colours; stats_mode=diff spends that palette on what
# actually moves rather than on the still backdrop.
#
# The dither is what decides the file size here, not the resolution. Nearly
# every pixel changes every frame — the lensed background shifts with the drift
# and the disk churns — so GIF's between-frame compression has almost nothing to
# work with, and error-diffused dithering (sierra2_4a) fills what is left with
# high-entropy noise. An ordered dither repeats a fixed pattern instead, which
# compresses: measured on this animation, 6.0 MB against 2.9 MB for a difference
# the disk's gradients do not show.
FPS="${DEMO_FPS:-12}"
COLORS="${DEMO_COLORS:-128}"
ffmpeg -v error -framerate "$FPS" -i "$TMP/frames/frame-%04d.png" \
    -vf "palettegen=stats_mode=diff:max_colors=$COLORS" -y "$TMP/palette.png"
ffmpeg -v error -framerate "$FPS" -i "$TMP/frames/frame-%04d.png" -i "$TMP/palette.png" \
    -lavfi "paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
    -loop 0 -y docs/demo.gif

echo "wrote $PWD/docs/demo.gif ($(du -h docs/demo.gif | cut -f1))"
