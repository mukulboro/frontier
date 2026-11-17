#!/bin/zsh
# Rebuilds Resources/Video/campfire.mp4 from its source clip. Only needed if you want to change the
# fire; the processed file is checked in. Requires ffmpeg.
#
# Source: "Fire of a bonfire against black" (Mixkit #45676), Mixkit Stock Video Free License.
#   https://mixkit.co/free-stock-video/fire-of-a-bonfire-against-black-45676/
set -euo pipefail
cd "$(dirname "$0")/.."
src=${1:-build/fire-source.mp4}
out=Sources/Frontier/Resources/Video/campfire.mp4
mkdir -p build "$(dirname "$out")"
[[ -f "$src" ]] || curl -fL -A "Mozilla/5.0" -o "$src" "https://assets.mixkit.co/videos/45676/45676-720.mp4"

fade=1.5
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src")
offset=$(( dur - 2 * fade ))
# 1. crop to the fire  2. crush the near-black background to true black so it composites cleanly
# 3. dissolve the last 1.5 s into the first 1.5 s, so the clip loops without a visible seam
ffmpeg -v error -y -i "$src" -filter_complex "
  [0:v]crop=600:720:290:0,colorlevels=rimin=0.035:gimin=0.035:bimin=0.035,split[a][b];
  [a]trim=${fade}:${dur},setpts=PTS-STARTPTS[body];
  [b]trim=0:${fade},setpts=PTS-STARTPTS[head];
  [body][head]xfade=transition=fade:duration=${fade}:offset=${offset}[v]" \
  -map "[v]" -an -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -movflags +faststart "$out"
ffprobe -v error -show_entries stream=width,height,r_frame_rate:format=duration,size -of csv=p=0 "$out"
