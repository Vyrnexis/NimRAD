#!/usr/bin/env bash
# Build-time benchmark: generates a small project the way the IDE does (a form
# with a Label, an Edit, a Button and an ImageList) and times
#   - a cold front-end pass (`nim check`),
#   - a warm `nim c` (the C code is already compiled; only the front end and
#     the link step run), and
#   - a cold `nim c` (everything compiled),
# all with --hints:off. Nothing is shown on screen (the app is not run).
# Usage: scripts/bench_build.sh [runs] [nim]      (defaults: 3, nim from PATH)
set -u
cd "$(dirname "$0")/.."
runs=${1:-3}
nim=${2:-nim}
export SDL_VIDEO_DRIVER=offscreen SDL_RENDER_DRIVER=software
work=$(mktemp -d "${TMPDIR:-/tmp}/nimvcl-bench.XXXXXX")
trap 'rm -rf "$work"' EXIT
proj="$work/proj"

# the generator (compiled with the same compiler)
$nim c --hints:off --warnings:off --nimcache:"$work/gencache" --outdir:"$work" \
  -o:"$work/gen" scripts/bench_gen.nim >/dev/null || { echo "generator failed to build"; exit 1; }
"$work/gen" "$proj" || { echo "generator failed"; exit 1; }
# point the project at this checkout of nimvcl
echo "--path:\"$(cd ../nimvcl/src && pwd)\"" > "$proj/nim.cfg"

ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
common=(--hints:off --warnings:off --nimcache:"$proj/cache" --outdir:"$proj/out")

echo "compiler: $($nim --version | head -1)"
declare -a check warm
t=$(date +%s%N)
$nim c "${common[@]}" "$proj/benchapp.nim" >"$work/cold.log" 2>&1 || { cat "$work/cold.log"; exit 1; }
cold=$(ms $t)
for ((i = 0; i < runs; i++)); do
  t=$(date +%s%N)
  $nim check --hints:off --warnings:off --nimcache:"$proj/checkcache" "$proj/benchapp.nim" >"$work/check.log" 2>&1 \
    || { cat "$work/check.log"; exit 1; }
  check+=($(ms $t))
  t=$(date +%s%N)
  $nim c "${common[@]}" "$proj/benchapp.nim" >"$work/warm.log" 2>&1 || { cat "$work/warm.log"; exit 1; }
  warm+=($(ms $t))
done
echo "cold nim c (all C compiled): ${cold} ms"
echo "nim check (front end only):  ${check[*]} ms"
echo "warm nim c (no C recompile): ${warm[*]} ms"
