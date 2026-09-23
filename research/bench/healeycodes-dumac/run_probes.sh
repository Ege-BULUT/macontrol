#!/bin/bash
# Probes for the dumac deep dive (T-0030). No dumac code lives here.
#
# Build dumac (healeycodes/dumac@1ffbe3c, no license: study only, never vendor) with
# its total printed in bytes instead of du -h text. One println is changed in a
# throwaway copy, nothing else:
#   cp -R research/sources/healeycodes-dumac $TMP/dumac-bytes && cd $TMP/dumac-bytes
#   sed -i '' 's|format_size(total_blocks), root_dir|total_blocks * 512, root_dir|' src/main.rs
#   cargo build --release --locked      # no cargo on this Mac: rustup was installed into
#                                       # the scratchpad (RUSTUP_HOME/CARGO_HOME), 7.5 s build
# Then: DUMAC=$TMP/dumac-bytes/target/release/dumac research/bench/healeycodes-dumac/run_probes.sh
# Output from 2026-09-23 is in results.txt next to this script.
set -uo pipefail
: "${DUMAC:?set DUMAC to the bytes-printing dumac binary}"
HERE="$(cd "$(dirname "$0")" && pwd)"
FX="$HERE/../fixtures/tree"
W="$(mktemp -d)"; trap 'chmod -R u+rwx "$W" 2>/dev/null; /bin/rm -rf "$W"' EXIT
cd "$W"

echo "== 1. fixture total, 3 runs (ground truth visible allocated_all 2368040960; du/dua 2359623680)"
for k in 1 2 3; do out=$("$DUMAC" "$FX" 2>err); echo "run$k exit=$? total=${out%%$'\t'*} stderr_lines=$(wc -l < err)"; done

echo "== 2. nested chain depth: last depth that works, first that aborts"
python3 - "$DUMAC" <<'EOF'
import os, subprocess, sys
def chain(n):
    root = f"chain{n}"; os.mkdir(root); fd = os.open(root, os.O_RDONLY)
    for _ in range(n):
        os.mkdir("a", dir_fd=fd); nfd = os.open("a", os.O_RDONLY, dir_fd=fd); os.close(fd); fd = nfd
    os.close(fd); return root
for n in (100, 126, 127, 200):
    r = subprocess.run([sys.argv[1], chain(n)], capture_output=True, text=True)
    print(f"depth={n} exit={r.returncode} stdout={r.stdout.strip()[:20]!r} stderr={r.stderr.strip().splitlines()[:1]}")
EOF

echo "== 3. fd pressure: fixture under ulimit -n 8 and 12"
for L in 8 12; do for k in 1 2 3; do
  out=$(bash -c "ulimit -n $L; exec '$DUMAC' '$FX'" 2>err); echo "ulimit=$L run$k exit=$? total=${out%%$'\t'*} cannot_access=$(grep -c 'Cannot access directory' err)"
done; done

echo "== 4. fd leak: 300 readable-but-unsearchable (r--) folders + 300 normal folders, 5000 B file each"
python3 - <<'EOF'
import os
os.mkdir("leak")
for i in range(300):
    for kind in "pn":
        d = f"leak/{kind}{i:03d}"; os.mkdir(d)
        with open(f"{d}/f.dat", "wb") as f: f.write(b"x" * 5000)
for i in range(300): os.chmod(f"leak/p{i:03d}", 0o444)
EOF
echo "expected total: $((300 * $(stat -f %b leak/n000/f.dat) * 512))"
for L in 64 1024; do
  out=$(bash -c "ulimit -n $L; exec '$DUMAC' leak" 2>err); echo "ulimit=$L exit=$? total=${out%%$'\t'*} permission_denied=$(grep -c 'Permission denied' err) cannot_access=$(grep -c 'Cannot access directory' err)"
done

echo "== 5. two APFS volumes mounted side by side (inode numbers restart at 16 on each)"
mkdir -p mnt/v1 mnt/v2
for v in v1 v2; do
  hdiutil create -quiet -size 40m -fs APFS -volname "dumacprobe_$v" -o "$v.dmg" && hdiutil attach -quiet -nobrowse -mountpoint "mnt/$v" "$v.dmg"
  python3 -c "import os,sys; [open(os.path.join(sys.argv[1], f'f{i:02d}.bin'), 'wb').write(os.urandom(65536)) for i in range(50)]" "mnt/$v"
done
echo "inodes v1: $(ls -i mnt/v1 | head -2 | tr '\n' ' ') v2: $(ls -i mnt/v2 | head -2 | tr '\n' ' ')"
echo "du -sk: $(( $(du -sk mnt | cut -f1) * 1024 )) B   dumac: $("$DUMAC" mnt | cut -f1) B   dumac v1 only: $("$DUMAC" mnt/v1 | cut -f1) B"
hdiutil detach -quiet mnt/v1; hdiutil detach -quiet mnt/v2
