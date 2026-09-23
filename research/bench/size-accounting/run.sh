#!/bin/sh
# APFS size-accounting experiment (T-0009). Builds a tiny fixture (clone, partial
# clone, hard link, sparse, decmpfs-compressed, 1-byte and empty files) and prints
# what du, stat, getattrlistbulk and URLResourceValues report for each file.
# Usage: sh run.sh [workdir]   (workdir must be on an APFS volume; default: mktemp)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
W=${1:-$(mktemp -d)}; mkdir -p "$W/exp"; cd "$W/exp"
dd if=/dev/urandom of=orig.bin bs=1m count=8 2>/dev/null
cp -c orig.bin clone.bin                                   # full APFS clone
cp -c orig.bin pclone.bin
dd if=/dev/urandom of=pclone.bin bs=1m count=1 conv=notrunc 2>/dev/null  # partial clone
dd if=/dev/urandom of=hl_src.bin bs=1m count=4 2>/dev/null && ln hl_src.bin hl_dst.bin
python3 -c "f=open('sparse.bin','wb'); f.seek(100*1024*1024-1); f.write(b'x')"
printf x > tiny.txt; : > empty.txt
python3 -c "open('comp_src.txt','w').write('macontrol size accounting '*400000)"
ditto --hfsCompression comp_src.txt comp.txt               # decmpfs, UF_COMPRESSED
sync
echo "== stat";  stat -f "%-13N size=%-10z blocks512=%-7b nlink=%l ino=%i flags=%Sf" *
echo "== du -sk (hard links once) / du -skl (each) / du -Ask (apparent)"
du -sk .; du -skl .; du -Ask .
cd "$W"
cc -O2 -o bulk "$HERE/bulk.c" && echo "== getattrlistbulk" && ./bulk exp
swiftc -O -o urlkeys "$HERE/urlkeys.swift" && echo "== URLResourceValues" && ./urlkeys exp
echo "== free-space delta on delete (64 MiB clone / hard link / last link)"
python3 "$HERE/freecheck.py" "$W/free"
