#!/bin/bash
# kondo dry-run probe (T-0020). Builds a synthetic home under $2 and runs `kondo -n` on it.
# Usage: probe.sh <path-to-kondo-binary> <scratch-dir>
# Binary used on 2026-09-23: kondo v0.9 release asset kondo-aarch64-apple-darwin.tar.gz
#   (gh release download v0.9 -R tbillington/kondo -p 'kondo-aarch64-apple-darwin.tar.gz').
# `-n` never deletes: kondo/src/main.rs:255-258 sets clean_project=false, and clap makes -n conflict with --all.
# Doubles as an acceptance fixture for macontrol's dev-artifact scanner (expected macontrol results in comments).
set -euo pipefail
K="$1"; R="$2"; H="$R/home"
/bin/rm -rf "$R"; mkdir -p "$H"
mk() { mkdir -p "$(dirname "$1")"; head -c "$2" /dev/zero > "$1"; }
# 1. app-internal node project under ~/Library (kondo #191).        macontrol: not offered (Library excluded)
Z="$H/Library/Application Support/Zed/languages/vtsls"
mkdir -p "$Z"; echo '{"dependencies":{"@vtsls/language-server":"0.2.9"}}' > "$Z/package.json"
mk "$Z/node_modules/@vtsls/language-server/bin/vtsls.js" 300000
# 2. stray script at the top of ~/code masks two projects (#175).    macontrol: app/target and web/node_modules offered
mkdir -p "$H/code/app" "$H/code/web"; echo 'print(1)' > "$H/code/notes.py"
echo '[package]' > "$H/code/app/Cargo.toml"; mk "$H/code/app/target/debug/app.bin" 2000000
echo '{}' > "$H/code/web/package.json"; mk "$H/code/web/node_modules/x/index.js" 1000000
# 3. Unreal Saved/ holds autosaves.                                  macontrol: Intermediate offered, Saved = review tier, unselected
mkdir -p "$H/game"; echo '{}' > "$H/game/MyGame.uproject"
mk "$H/game/Saved/Autosaves/Main_Auto1.umap" 1000000; mk "$H/game/Intermediate/x.o" 500000
# 4. CMake project whose build/ is git-tracked source.               macontrol: build/ not offered (tracked, no CMakeCache.txt)
mkdir -p "$H/cm/build"; echo 'project(cm)' > "$H/cm/CMakeLists.txt"
printf '#!/bin/sh\necho release\n' > "$H/cm/build/release.sh"; mk "$H/cm/build/signing-notes.txt" 200000
git -C "$H/cm" init -q && git -C "$H/cm" add -A && git -C "$H/cm" -c user.name=t -c user.email=t@t commit -qm init
# 5. pnpm-style hard links into a shared store.                      macontrol: frees 0 B for either node_modules (F-0010)
mk "$H/store/big.bin" 4194304
for p in pn1 pn2; do mkdir -p "$H/$p/node_modules/.pnpm"; echo '{}' > "$H/$p/package.json"; ln "$H/store/big.bin" "$H/$p/node_modules/.pnpm/big.bin"; done
# 6. .venv: released v0.9 deletes it, master 1d351ca stopped.        macontrol: review tier, unselected
mkdir -p "$H/py"; echo 'print(1)' > "$H/py/main.py"; mk "$H/py/.venv/lib/site.bin" 1000000
# 7. multi-type dirs: first marker in readdir order wins (#111).     macontrol: all artifact dirs of all matching types
mkdir -p "$H/multi/tauri" "$H/multi/mixed"
echo '[package]' > "$H/multi/tauri/Cargo.toml"; echo '{}' > "$H/multi/tauri/package.json"
mk "$H/multi/tauri/target/debug/a.bin" 1000000; mk "$H/multi/tauri/node_modules/x/i.js" 1000000
echo 'x' > "$H/multi/mixed/setup.py"; echo '{}' > "$H/multi/mixed/package.json"; mk "$H/multi/mixed/node_modules/y/i.js" 500000

strip() { sed -E "s#$R/##"; }
echo "## kondo -n home";                  "$K" -n "$H" | strip
echo "## kondo -n home/code (notes.py)";  "$K" -n "$H/code" | strip
/bin/rm -f "$H/code/notes.py"
echo "## kondo -n home/code (no notes.py)"; "$K" -n "$H/code" | strip
echo "## readdir order"; ls -f "$H/multi/tauri" | tr '\n' ' '; echo; ls -f "$H/multi/mixed" | tr '\n' ' '; echo
echo "## store link count"; stat -f '%l links %z B' "$H/store/big.bin"
