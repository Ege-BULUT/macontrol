#!/bin/bash
# Deterministic scan-benchmark fixture for macontrol.
#
#   research/bench/make_fixture.sh          # build if missing, print ground truth
#   FORCE=1 research/bench/make_fixture.sh  # wipe and rebuild
#
# Output: research/bench/fixtures/tree/ (gitignored) and
#         research/bench/fixtures/ground_truth.json (copied to results/).
# ~300k files, deep + wide trees, 0-byte..1 MiB small files, 280 MiB of real big
# files, 5 GiB of sparse files, hard links, APFS clones (cp -c), symlinks incl.
# loops, an unreadable dir, a path longer than PATH_MAX, unicode names and
# .app-like bundles. Real bytes on disk: ~1.7 GB. Needs APFS (clones, sparse).
set -euo pipefail
BENCH="$(cd "$(dirname "$0")" && pwd)"
FIX="$BENCH/fixtures"
TREE="$FIX/tree"
GT="$FIX/ground_truth.json"
VERSION=1

if [[ -f "$GT" && -z "${FORCE:-}" ]] && grep -q "\"fixture_version\": $VERSION," "$GT"; then
  cat "$GT"; exit 0
fi

if [[ -e "$TREE" ]]; then
  chmod -R u+rwx "$TREE" 2>/dev/null || true
  rm -rf "$TREE"
fi
mkdir -p "$FIX" "$BENCH/results"

python3 - "$TREE" "$GT" "$VERSION" <<'PY'
import json, os, random, subprocess, sys, time, unicodedata

tree, gt_path, version = sys.argv[1], sys.argv[2], int(sys.argv[3])
rnd = random.Random(20260923)          # fixed seed: same tree every run
t0 = time.time()
BLOCK = b"macontrol-bench\n" * 4096    # 64 KiB of filler
clones = []                            # (path, bytes physically shared with source)

def payload(n):
    return (BLOCK * (n // len(BLOCK) + 1))[:n]

def small_size():
    r = rnd.random()                   # 30% empty, 66% <=4K, 3.9% <=64K, 0.1% <=1M
    if r < 0.30: return 0
    if r < 0.96: return rnd.randint(1, 4096)
    if r < 0.999: return rnd.randint(4097, 65536)
    return rnd.randint(65537, 1 << 20)

def write(path, size):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    if size: os.write(fd, payload(size))
    os.close(fd)

def files(d, n, prefix="f"):
    os.makedirs(d, exist_ok=True)
    for i in range(n):
        write(os.path.join(d, f"{prefix}{i:05d}.dat"), small_size())

def big(path, mib):
    chunk = payload(1 << 20)
    with open(path, "wb") as f:
        for _ in range(mib): f.write(chunk)

os.makedirs(tree)
T = lambda *p: os.path.join(tree, *p)

# wide: one flat dir of 20k files + 200 dirs x 400 files
files(T("wide", "flat"), 20000)
for d in range(200): files(T("wide", f"w{d:03d}"), 400)

# bushy: branching 4, depth 6 -> 4096 leaf dirs x 30 files
def bushy(d, depth):
    if depth == 0: return files(d, 30)
    for b in range(4): bushy(os.path.join(d, f"b{b}"), depth - 1)
bushy(T("bushy"), 6)

# node_modules-like: 1500 small packages x 40 files, 2 levels
for p in range(1500):
    base = T("node_modules", f"pkg{p:04d}")
    files(os.path.join(base, "lib"), 30); files(os.path.join(base, "dist"), 9)
    write(os.path.join(base, "package.json"), rnd.randint(200, 2000))

# deep: a 120-level chain (path stays under PATH_MAX) with 2 files per level
d = T("deep")
for lvl in range(120):
    d = os.path.join(d, f"d{lvl:03d}"); files(d, 2)

# pathmax: chain whose full path exceeds PATH_MAX (1024); built with dir fds.
# The 8 MiB file at the bottom makes a walker that gives up here visibly short.
os.makedirs(T("pathmax"))
fd = os.open(T("pathmax"), os.O_RDONLY)
for lvl in range(120):
    name = f"long_segment_{lvl:03d}"
    os.mkdir(name, dir_fd=fd); nfd = os.open(name, os.O_RDONLY, dir_fd=fd); os.close(fd); fd = nfd
    if lvl % 10 == 9:
        f = os.open("marker.dat", os.O_WRONLY | os.O_CREAT, 0o644, dir_fd=fd); os.write(f, payload(1000)); os.close(f)
f = os.open("bottom_8mib.bin", os.O_WRONLY | os.O_CREAT, 0o644, dir_fd=fd)
os.write(f, payload(8 << 20)); os.close(f); os.close(fd)

# bundles: .app-like packages (Contents/MacOS, Resources, a versioned framework)
for a in range(8):
    app = T("bundles", f"App{a}.app", "Contents")
    for sub in ("MacOS", "Resources/en.lproj", "Frameworks/Kit.framework/Versions/A/Resources"):
        os.makedirs(os.path.join(app, sub), exist_ok=True)
    write(os.path.join(app, "Info.plist"), 1500); write(os.path.join(app, "PkgInfo"), 8)
    write(os.path.join(app, "MacOS", f"App{a}"), 3 << 20)
    files(os.path.join(app, "Resources"), 1100, "res")
    fw = os.path.join(app, "Frameworks", "Kit.framework")
    write(os.path.join(fw, "Versions", "A", "Kit"), 1 << 20)
    os.symlink("A", os.path.join(fw, "Versions", "Current"))
    os.symlink("Versions/Current/Kit", os.path.join(fw, "Kit"))
    os.symlink("Versions/Current/Resources", os.path.join(fw, "Resources"))
files(T("bundles", "Media.photoslibrary", "originals"), 500, "img")
files(T("bundles", "Assets.xcassets", "AppIcon.appiconset"), 40, "icon")

# big: real files, sparse files (1 GiB and 4 GiB logical, ~1 MiB allocated)
os.makedirs(T("big"))
big(T("big", "real_a.bin"), 160); big(T("big", "real_b.bin"), 120)
for name, logical, writes in (("sparse_1g.bin", 1 << 30, (0, (1 << 30) - (512 << 10))),
                              ("sparse_4g.bin", 4 << 30, (2 << 30,))):
    with open(T("big", name), "wb") as f:
        f.truncate(logical)
        for off in writes: f.seek(off); f.write(payload(512 << 10))

# clones: 3 full APFS clones of real_a (160 MiB each, 0 new blocks), 1 clone with
# 1 MiB rewritten (partially shared), 100 clones of small files.
os.makedirs(T("clones", "small"))
for i in range(3):
    subprocess.run(["cp", "-c", T("big", "real_a.bin"), T("clones", f"real_a_clone{i}.bin")], check=True)
    clones.append((T("clones", f"real_a_clone{i}.bin"), 160 << 20))
subprocess.run(["cp", "-c", T("big", "real_b.bin"), T("clones", "real_b_partial.bin")], check=True)
with open(T("clones", "real_b_partial.bin"), "r+b") as f:
    f.seek(50 << 20); f.write(bytes(range(256)) * 4096)  # 1 MiB of new extents
clones.append((T("clones", "real_b_partial.bin"), 119 << 20))
src = T("wide", "w000")
for i, name in enumerate(sorted(os.listdir(src))[:100]):
    dst = T("clones", "small", f"c{i:03d}.dat")
    subprocess.run(["cp", "-c", os.path.join(src, name), dst], check=True)
    clones.append((dst, os.lstat(dst).st_blocks * 512))

# hard links: 10 links to each of 50 small files, 3 extra links to real_b (120 MiB)
os.makedirs(T("hardlinks", "small"))
src = T("wide", "w001")
for i, name in enumerate(sorted(os.listdir(src))[:50]):
    for k in range(10):
        os.link(os.path.join(src, name), T("hardlinks", "small", f"h{i:02d}_{k}.dat"))
for k in range(3): os.link(T("big", "real_b.bin"), T("hardlinks", f"real_b_link{k}.bin"))

# symlinks: 1000 file links, links to big files, a 2-link loop, dir loops,
# a dangling link and one pointing outside the tree
os.makedirs(T("symlinks", "many"))
for i in range(1000): os.symlink(f"../../wide/w002/f{i % 400:05d}.dat", T("symlinks", "many", f"s{i:04d}"))
os.symlink("../big/real_a.bin", T("symlinks", "to_real_a"))
os.symlink("../big/sparse_4g.bin", T("symlinks", "to_sparse_4g"))
os.symlink("loop_b", T("symlinks", "loop_a")); os.symlink("loop_a", T("symlinks", "loop_b"))
os.symlink("..", T("symlinks", "up_loop")); os.symlink(".", T("symlinks", "self_loop"))
os.symlink("does/not/exist", T("symlinks", "dangling")); os.symlink("/usr", T("symlinks", "outside"))

# unicode and hostile names
os.makedirs(T("unicode"))
names = ["café-nfc", unicodedata.normalize("NFD", "café-nfd"), "日本語のファイル", "العربية",
         "emoji-📦🧹💾", "zwj-👩‍💻", "space name", " leading-space", "trailing-space ",
         "-rf", "--help", "back\\slash", "new\nline", "tab\tname", "quote'\"", "$HOME",
         "*glob?", ".hidden", "..double-dot", "ü" * 127]  # last one: 254 bytes UTF-8
for i, n in enumerate(names): write(T("unicode", n), 100 + i)
os.makedirs(T("unicode", "Ωmega-dir", "子目录")); files(T("unicode", "Ωmega-dir", "子目录"), 30)

# unreadable: 100 files a non-root scanner can't list (chmod 000 at the end)
files(T("unreadable", "locked"), 100)
write(T("unreadable", "no_read_perm.dat"), 3000)

# pad to exactly 300,000 regular-file directory entries
n = 0
for _, _, fnames, dfd in os.fwalk(tree):
    for f in fnames:
        st = os.stat(f, dir_fd=dfd, follow_symlinks=False)
        n += (st.st_mode & 0o170000) == 0o100000
files(T("misc"), 300000 - n)

# ---- ground truth, from lstat of every entry (fd-relative, so > PATH_MAX works)
S_IFMT, REG, DIR, LNK = 0o170000, 0o100000, 0o040000, 0o120000
locked = T("unreadable", "locked")
tot = dict(files=0, file_entries=0, dirs=0, symlinks=0,
           apparent_files=0, apparent_files_all_links=0,
           alloc_files=0, alloc_files_all_links=0, alloc_dirs=0, alloc_symlinks=0)
hidden = dict(files=0, apparent_files=0, alloc_files=0)   # inside unreadable/locked
seen = set()
for dpath, dnames, fnames, dfd in os.fwalk(tree):
    inside = dpath == locked or dpath.startswith(locked + "/")
    st = os.stat(dfd)
    tot["dirs"] += 1; tot["alloc_dirs"] += st.st_blocks * 512
    for f in fnames + dnames:          # dnames may hold symlinks to dirs; real dirs are counted when walked
        st = os.stat(f, dir_fd=dfd, follow_symlinks=False)
        kind = st.st_mode & S_IFMT
        if kind == LNK:
            tot["symlinks"] += 1; tot["alloc_symlinks"] += st.st_blocks * 512
        elif kind == REG:
            tot["file_entries"] += 1
            tot["apparent_files_all_links"] += st.st_size
            tot["alloc_files_all_links"] += st.st_blocks * 512
            if (st.st_dev, st.st_ino) in seen: continue
            seen.add((st.st_dev, st.st_ino))
            tot["files"] += 1; tot["apparent_files"] += st.st_size; tot["alloc_files"] += st.st_blocks * 512
            if inside:
                hidden["files"] += 1; hidden["apparent_files"] += st.st_size; hidden["alloc_files"] += st.st_blocks * 512

clone_shared = sum(b for _, b in clones)
gt = {
    "fixture_version": version,
    "root": tree,
    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    "generate_seconds": round(time.time() - t0, 1),
    "counts": {k: tot[k] for k in ("files", "file_entries", "dirs", "symlinks")},
    "bytes": {
        "apparent_files": tot["apparent_files"],
        "apparent_files_counting_hardlinks_each_time": tot["apparent_files_all_links"],
        "allocated_files": tot["alloc_files"],
        "allocated_files_counting_hardlinks_each_time": tot["alloc_files_all_links"],
        "allocated_dirs": tot["alloc_dirs"],
        "allocated_symlinks": tot["alloc_symlinks"],
        "allocated_all": tot["alloc_files"] + tot["alloc_dirs"] + tot["alloc_symlinks"],
        "apfs_clone_shared": clone_shared,
        "physical_estimate_clones_once": tot["alloc_files"] + tot["alloc_dirs"] + tot["alloc_symlinks"] - clone_shared,
    },
    "hidden_from_non_root": hidden,
    "visible_to_non_root": {
        "files": tot["files"] - hidden["files"],
        "apparent_files": tot["apparent_files"] - hidden["apparent_files"],
        "allocated_all": tot["alloc_files"] + tot["alloc_dirs"] + tot["alloc_symlinks"] - hidden["alloc_files"],
    },
    "notes": [
        "Hard links counted once by (st_dev, st_ino) unless the key says otherwise.",
        "allocated_* = st_blocks*512, which reports every APFS clone at full size; "
        "physical_estimate_clones_once subtracts the extents the generator knows are shared.",
        "unreadable/locked is chmod 000 after the walk: a non-root scanner should match visible_to_non_root.",
        "pathmax/ holds a path longer than PATH_MAX (1024) with an 8 MiB file at the bottom.",
    ],
}
json.dump(gt, open(gt_path, "w"), indent=2)
PY

chmod 000 "$TREE/unreadable/locked" "$TREE/unreadable/no_read_perm.dat"
cp "$GT" "$BENCH/results/ground_truth.json"
cat "$GT"
