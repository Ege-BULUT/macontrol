#!/bin/bash
# Behaviour tests for sveinbjornt/searchfs@3afcfc3 on a throwaway 64 MB APFS image, so no
# search touches the real Data volume. Needs: SEARCHFS (the built tool), SEARCHFS_ASAN
# (same main.m built with -fsanitize=address), VOL (mount point of the scratch image).
# Build: clang -Os -framework Foundation -o searchfs <clone>/main.m
#        clang -O1 -g -fsanitize=address -framework Foundation -o searchfs_asan <clone>/main.m
# Image: hdiutil create -size 64m -fs APFS -volname MCZAPFS -type SPARSE img
#        hdiutil attach -nobrowse -mountpoint "$VOL" img.sparseimage
# Test 6 needs VOL_HFS, an HFS+ image made the same way (-fs HFS+): on APFS the kernel
# never returned EBUSY in our runs (searchfs_probe -w, 3000 resumes), so the defect only shows on HFS+.
# Results 2026-09-23, macOS 26.6: see research/reports/sources/sveinbjornt-searchfs.md "Verified behaviour".
set -u
: "${SEARCHFS:?}" "${SEARCHFS_ASAN:?}" "${VOL:?}"
cd "$VOL" || exit 1
/bin/rm -rf "$VOL"/t && mkdir -p "$VOL"/t && cd "$VOL"/t

echo "== 1. -s (case-sensitive) filters on the whole path, not the name (main.m:437-448)"
mkdir -p MCZ_Dir && touch MCZ_Dir/lower_mcz.txt
"$SEARCHFS" -v "$VOL" -s MCZ; echo "exit=$?  (name semantics expect only .../MCZ_Dir)"

echo "== 2. ^ and \$ are case-sensitive even without -s (main.m:450-460)"
touch README.md
"$SEARCHFS" -v "$VOL" '^readme'; echo "exit=$?  (default is case-insensitive, expect .../README.md)"
"$SEARCHFS" -v "$VOL" 'readme'; echo "exit=$?  (plain substring, kernel match)"
"$SEARCHFS" -v "$VOL" '.MD$'; echo "exit=$?  (expect .../README.md)"

echo "== 3. '*' matches a literal asterisk, though searchfs.1:75-77 says it finds all files (issue #11)"
"$SEARCHFS" -v "$VOL" '*' | wc -l | tr -d ' '; echo "lines for '*' (volume has $(find "$VOL" 2>/dev/null | wc -l | tr -d ' ') entries)"

echo "== 4. hard link: which path does fsgetpath(OBJID) return for the second link's name?"
mkdir -p hlA hlB && echo x > hlA/hl_one && ln hlA/hl_one hlB/hl_two
"$SEARCHFS" -v "$VOL" -e hl_two; echo "exit=$?  (expect .../hlB/hl_two)"
"$SEARCHFS" -v "$VOL" hl_; echo "exit=$?  (partial 'hl_': expect both links)"

echo "== 5. clone: cp -c gives a new object; both names found?"
cp -c hlA/hl_one clone_hl_c; "$SEARCHFS" -v "$VOL" clone_hl; echo "exit=$?"

echo "== 6. EBUSY under a concurrent writer (HFS+): duplicates printed, partial result, exit code"
if [ -n "${VOL_HFS:-}" ]; then VOL=$VOL_HFS; mkdir -p "$VOL"/t; cd "$VOL"/t || exit 1; fi
mkdir -p many && (cd many && for i in $(seq 1 3000); do : > "mczmany_$i"; done)
( for i in $(seq 1 100000); do : > "$VOL/t/w_$i"; /bin/rm -f "$VOL/t/w_$i"; done ) &
W=$!; sleep 1
"$SEARCHFS" -v "$VOL" mczmany > "$VOL"/../out6.txt 2> "$VOL"/../err6.txt; rc=$?
kill $W 2>/dev/null; wait $W 2>/dev/null
echo "exit=$rc lines=$(wc -l < "$VOL"/../out6.txt | tr -d ' ') unique=$(sort -u "$VOL"/../out6.txt | wc -l | tr -d ' ') of 3000; stderr: $(head -c 300 "$VOL"/../err6.txt)"
echo "-- control, no writer:"
"$SEARCHFS" -v "$VOL" mczmany | sort | uniq -d | wc -l | tr -d ' '; echo "duplicate lines without writer"

echo "== 7. stack overflow: length check counts UTF-16 units (main.m:222), strcpy copies UTF-8 bytes into char[PATH_MAX] (main.m:51,313)"
T=$(python3 -c 'print("é"*1024)')
"$SEARCHFS_ASAN" -v "$VOL" "$T" 2>&1 | grep -E "ERROR: AddressSanitizer|WRITE of size|#[01] " | head -4
echo "exit=${PIPESTATUS[0]}"
