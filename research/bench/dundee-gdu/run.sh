#!/usr/bin/env bash
# Runs the macontrol probes against gdu's own packages without touching the clone.
# go test -overlay swaps badger storage and the modernc SQLite driver for stubs
# (keeps the build light) and injects the probe tests. Scratch fixtures only.
# Usage: bash research/bench/dundee-gdu/run.sh   (clone at research/sources/dundee-gdu)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC:-$HERE/../../sources/dundee-gdu}"
SRC="$(cd "$SRC" && pwd)"
OUT="${TMPDIR:-/tmp}/gdu-probe-overlay.json"

{
  printf '{"Replace":{\n'
  printf '"%s":"%s",\n' "$SRC/pkg/analyze/storage.go" "$HERE/stub_storage.go"
  printf '"%s":"",\n' "$SRC/pkg/analyze/stored.go"
  printf '"%s":"%s",\n' "$SRC/pkg/analyze/sqlite_modernc.go" "$HERE/stub_sqlite_driver.go"
  for f in "$SRC"/pkg/remove/*_test.go; do printf '"%s":"",\n' "$f"; done
  printf '"%s":"%s",\n' "$SRC/pkg/remove/zz_macontrol_probe_test.go" "$HERE/probe_engine_test.go"
  for f in "$SRC"/tui/*_test.go; do printf '"%s":"",\n' "$f"; done
  printf '"%s":"%s"\n' "$SRC/tui/zz_macontrol_probe_test.go" "$HERE/probe_tui_test.go"
  printf '}}\n'
} > "$OUT"

cd "$SRC"
echo "gdu @ $(git rev-parse --short HEAD)"
GOTOOLCHAIN=local nice -n 10 go test -vet=off -overlay "$OUT" -count=1 -v -run 'TestProbe' ./pkg/remove ./tui 2>&1 | grep -E '^(RESULT|--- |ok|FAIL|#|.*\.go:[0-9]+)' || true
