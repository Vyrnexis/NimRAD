#!/usr/bin/env bash
# Run the whole test suite headless.
# Usage: scripts/test.sh [extra nim flags, e.g. -d:release]
# Each run builds into its own folder (build/tests/run-<pid>) with its own
# compiler cache, so two runs at the same time cannot clash. The folder is
# removed when all tests pass and kept (with logs) when one fails.
set -u
cd "$(dirname "$0")/.."
export SDL_VIDEO_DRIVER=offscreen SDL_RENDER_DRIVER=software
out="build/tests/run-$$"
mkdir -p "$out"
flags=(--hints:off --warnings:off "$@" --outdir:"$out" --nimcache:"$out/cache")
fail=0
for f in tests/t*.nim; do
  name=$(basename "$f" .nim)
  if nim c "${flags[@]}" -r "$f" > "$out/$name.log" 2>&1; then
    echo "ok    $name"
  else
    echo "FAIL  $name  (see $out/$name.log)"; fail=1
  fi
done
if [ $fail = 0 ]; then rm -rf "$out"; fi
exit $fail
