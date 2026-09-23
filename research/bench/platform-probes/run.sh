#!/bin/sh
# Re-runs the T-0010 trash experiments (topic-platform-constraints report, facts D1-D6).
#   trash.swift    FileManager.trashItem vs NSWorkspace.recycle: resulting URL, collision rename,
#                  undo by moving back, Finder "Put Back" record (ptbL in ~/.Trash/.DS_Store),
#                  error codes on the sealed system volume and on a SIP path (both cannot succeed).
#   trashvol.swift trashItem on a 4 MB FAT disk image: item lands in <volume>/.Trashes/<uid>.
# Run from Terminal (needs Full Disk Access to read ~/.Trash/.DS_Store). Removes its own files after.
set -e
W=${TMPDIR:-/tmp}/macontrol-platform-probes
HERE=$(cd "$(dirname "$0")" && pwd)
rm -rf "$W" && mkdir -p "$W/work"
swiftc -O "$HERE/trash.swift" -o "$W/trash"
swiftc -O "$HERE/trashvol.swift" -o "$W/trashvol"

"$W/trash" "$W/work" | tee "$W/trash.out"
sleep 3
python3 - "$W/trash.out" <<'EOF'
import os, re, sys
a, b = re.search(r'TRASHED: (\S+) (\S+)', open(sys.argv[1]).read()).groups()
ds = open(os.path.expanduser('~/.Trash/.DS_Store'), 'rb').read()
for label, p in (('trashItem', a), ('recycle', b)):
    hit = os.path.basename(p).encode('utf-16-be') in ds
    print(f'{label}: put-back record {"present" if hit else "ABSENT"} for {os.path.basename(p)}')
    os.remove(p)  # only the probe's own file
EOF

hdiutil create -size 4m -fs MS-DOS -volname MCPROBE -o "$W/fat.dmg" >/dev/null
MP=$(hdiutil attach -nobrowse "$W/fat.dmg" | awk -F'\t' '/MCPROBE/{print $NF}')
"$W/trashvol" "$MP/probe.txt"
hdiutil detach "$MP" >/dev/null
rm -rf "$W"
