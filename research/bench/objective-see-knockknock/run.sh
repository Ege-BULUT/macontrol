#!/bin/bash
# Probes for the KnockKnock deep dive (T-0038). Read-only on this Mac; prints counts only.
#   ./run.sh btm      build btm_probe.m against the clone's libDumpBTM.a and run it
#   ./run.sh launchd  count launchd plists whose program is missing (KnockKnock drops them)
#   ./run.sh sp       time KnockKnock's app inventory command (system_profiler)
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
SRC=${SRC:-$HERE/../../sources/objective-see-knockknock}
OUT=${OUT:-${TMPDIR:-/tmp}/kk-probe}
mkdir -p "$OUT"
case "${1:-}" in
btm)
  clang -fobjc-arc -fmodules -O1 -I"$SRC/Libraries/BTM" "$HERE/btm_probe.m" "$SRC/Libraries/BTM/libDumpBTM.a" \
    -framework Foundation -framework OpenDirectory -o "$OUT/btm_probe" || { echo "build exit=$?"; exit 1; }
  "$OUT/btm_probe" 2>/dev/null | grep -vE '^(Opened|$)'; echo "exit=${PIPESTATUS[0]}" ;;
launchd)
  python3 "$HERE/launchd_orphans.py"; echo "exit=$?" ;;
sp)
  /usr/bin/time -p /usr/sbin/system_profiler SPApplicationsDataType -xml -detailLevel mini >"$OUT/sp.xml" 2>"$OUT/sp.time"
  echo "exit=$?"; cat "$OUT/sp.time" | grep -E '^(real|user|sys)'
  python3 -c "import plistlib,sys; d=plistlib.load(open('$OUT/sp.xml','rb')); print('apps listed:', len(d[0]['_items']))" ;;
*) echo "usage: $0 btm|launchd|sp"; exit 2 ;;
esac
