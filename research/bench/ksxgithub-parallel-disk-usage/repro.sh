#!/bin/bash
# Reproduces the pdu (parallel-disk-usage) behaviours cited in
# research/reports/sources/ksxgithub-parallel-disk-usage.md, using the installed
# pdu binary (verified with pdu 0.24.0, Homebrew arm64, macOS 26.6).
#
#   research/bench/ksxgithub-parallel-disk-usage/repro.sh [unreadable|order|alias|quadratic|all]
#
# Everything is created in a mktemp dir and removed at the end. Nothing outside it
# is read except the /System/Volumes/Data alias of that same temp dir.
set -uo pipefail
WHAT="${1:-all}"
command -v pdu >/dev/null || { echo "pdu missing: brew install parallel-disk-usage" >&2; exit 1; }
T="$(cd "$(mktemp -d)" && pwd -P)"; trap  # pwd -P: /var -> /private/var, so the Data alias exists 'chmod -R u+rwx "$T" 2>/dev/null; /bin/rm -rf "$T"' EXIT
echo "pdu: $(pdu --version)   tmp: $T"

unreadable() {  # A folder pdu cannot read is shown as 0 B, like an empty one, and exit is 0.
  local r="$T/unreadable"; mkdir -p "$r/Locked" "$r/Empty"
  head -c 16777216 /dev/urandom > "$r/Locked/big"; chmod 000 "$r/Locked"
  echo "== unreadable: Locked/ holds 16 MiB and is chmod 000; Empty/ is empty"
  pdu --json-output --min-ratio 0 "$r" 2>/dev/null; echo; echo "exit=$?"
  chmod 755 "$r/Locked"
}

order() {  # With -H, sort and --min-ratio run before hard-link dedup (src/app/sub.rs:134-138).
  local r="$T/order"; mkdir -p "$r/A" "$r/B"
  head -c 4194304 /dev/urandom > "$r/A/f"; ln "$r/A/f" "$r/A/f2"; ln "$r/A/f" "$r/A/f3"
  head -c 8388608 /dev/urandom > "$r/B/g"; head -c 153600 /dev/urandom > "$r/C"
  echo "== order: A = one 4 MiB inode x3 links, B = 8 MiB, C = 150 KiB (1.2% of the deduped total)"
  (cd "$r" && pdu -H --top-down -b plain . | head -8)
}

alias_roots() {  # Same dir via its firmlink alias: overlap check misses it, summary panics (exit 101).
  local r="$T/alias"; mkdir -p "$r"
  head -c 4194304 /dev/urandom > "$r/f"; ln "$r/f" "$r/f2"; ln "$r/f" "$r/f3"
  local a="/System/Volumes/Data$r"
  echo "== alias: $r and $a"
  stat -f '%d %i %N' "$r" "$a"
  pdu -H -b plain -d 1 "$r" "$a"; echo "exit=$?"
  echo "-- same with --json-output (bytes printed to stdout):"
  pdu -H --json-output "$r" "$a" 2>/dev/null | wc -c; echo "exit=${PIPESTATUS[0]}"
}

quadratic() {  # The -H correction pass is O(children x link groups) per folder (src/data_tree/hardlink.rs:16-44).
  local n d i
  for n in 1000 2000 4000; do
    d="$T/pairs$n"; mkdir -p "$d"
    for ((i = 0; i < n; i++)); do : > "$d/f$i"; ln "$d/f$i" "$d/l$i"; done
    for mode in "" "-H"; do
      /usr/bin/time -p pdu $mode -b plain --json-output "$d" 2> "$T/time" > /dev/null
      echo "== quadratic: n=$n pairs, mode=[${mode}] $(tr '\n' ' ' < "$T/time")"
    done
  done
}

case "$WHAT" in
  unreadable) unreadable ;; order) order ;; alias) alias_roots ;; quadratic) quadratic ;;
  all) unreadable; order; alias_roots; quadratic ;;
  *) echo "unknown: $WHAT" >&2; exit 2 ;;
esac
