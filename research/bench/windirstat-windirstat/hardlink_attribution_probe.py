# Probe: per-folder sizes under WinDirStat's hard-link rule vs a lowest-common-ancestor rule.
# WinDirStat rule (windirstat@da13ad6, code-read, re-implemented here, not copied):
#   Item.Extended.cpp:849-875  any file whose index is seen >= 2 times in a drive scan is a "hardlink"
#   Item.Extended.cpp:906-914  its physical size is subtracted from every real parent folder
#   Item.cpp:386-389           GetSizePhysical() returns 0 for it while ProcessHardlinks (default true, Options.h:236)
#   Item.Extended.cpp:923-935  one copy (max size) is added to a synthetic <Hardlinks> node under the drive
# LCA rule (proposed for macontrol): an inode's allocated bytes belong to the deepest folder that
#   holds every link seen in the scan; if st_nlink > links seen, the bytes are "shared outside".
# "Freed if deleted" is ground truth: bytes of inodes whose every link (st_nlink) is inside the folder.
import os, sys, shutil, collections

root = sys.argv[1]
shutil.rmtree(root, ignore_errors=True)
def mk(p, mib):
    p = os.path.join(root, p); os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f: f.write(os.urandom(mib << 20))
    return p
def ln(src, dst):
    dst = os.path.join(root, dst); os.makedirs(os.path.dirname(dst), exist_ok=True); os.link(src, dst)

x = mk("A/x.bin", 4); ln(x, "A/sub/x_link.bin")          # both links inside A
y = mk("B/y.bin", 4); ln(y, "C/y_link.bin")              # links split across B and C
mk("D/z.bin", 4)                                         # ordinary file

files = []  # (path, dev, ino, nlink, allocated)
for d, _, fs in os.walk(root):
    for f in fs:
        st = os.lstat(os.path.join(d, f))
        files.append((os.path.join(d, f), st.st_dev, st.st_ino, st.st_nlink, st.st_blocks * 512))
seen = collections.Counter((f[1], f[2]) for f in files)
folders = sorted({os.path.relpath(d, root) for d, _, _ in os.walk(root)})

def inside(path, folder):
    folder = os.path.normpath(os.path.join(root, folder))
    return path == folder or path.startswith(folder + os.sep)

def wds(folder):    # WinDirStat display size
    return sum(a for p, dv, ino, nl, a in files if inside(p, folder) and seen[(dv, ino)] < 2)

def lca(folder):    # proposed display size
    groups = collections.defaultdict(list)
    for p, dv, ino, nl, a in files: groups[(dv, ino)].append((p, a))
    total = 0
    for links in groups.values():
        common = os.path.commonpath([os.path.dirname(p) for p, _ in links])
        if inside(common, folder): total += links[0][1]
    return total

def freed(folder):  # ground truth: every link of the inode lives inside the folder
    by_inode = collections.defaultdict(list)
    for p, dv, ino, nl, a in files: by_inode[(dv, ino)].append((p, nl, a))
    return sum(v[0][2] for v in by_inode.values() if len(v) == v[0][1] and all(inside(p, folder) for p, _, _ in v))

hl = sum({(dv, ino): a for p, dv, ino, nl, a in files if seen[(dv, ino)] >= 2}.values())
M = 1 << 20
print(f"{'folder':<8} {'WinDirStat':>11} {'LCA rule':>9} {'freed if deleted':>17}")
for fo in folders:
    print(f"{fo:<8} {wds(fo)/M:>9.1f} M {lca(fo)/M:>7.1f} M {freed(fo)/M:>15.1f} M")
print(f"<Hardlinks> synthetic node under the drive (WinDirStat): {hl/M:.1f} M")
assert wds("A") == 0 and freed("A") == lca("A") > 0
assert all(lca(fo) == freed(fo) for fo in ("A", "B", "C", "D", "."))
