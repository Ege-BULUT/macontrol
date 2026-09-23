#!/usr/bin/env python3
"""Profile the Homebrew cask API feed as a leftover-path dataset.

Input : research/sources/homebrew-homebrew-cask/cask.json   (curl https://formulae.brew.sh/api/cask.json)
        research/sources/homebrew-homebrew-cask/repo/Casks  (git clone --depth 1 --sparse Homebrew/homebrew-cask)
Output: stats on stdout (JSON). Read-only, touches nothing outside those two inputs.
Data is BSD-2-Clause (Homebrew/homebrew-cask LICENSE); keep attribution when shipping derived rules.
"""
import collections, json, os, re, sys

ROOT = os.path.expanduser("~/projects/macontrol/research/sources/homebrew-homebrew-cask")
feed = json.load(open(os.path.join(ROOT, "cask.json")))

PATH_KEYS = ("trash", "delete", "rmdir")
ID_KEYS = ("launchctl", "quit", "signal", "login_item", "kext", "pkgutil")


def stanzas(cask, kind):
    """Base stanzas plus any per-OS variation that overrides the artifacts list."""
    out = [a[kind] for a in cask["artifacts"] if kind in a]
    for tag, var in (cask.get("variations") or {}).items():
        for a in var.get("artifacts") or []:
            if kind in a:
                out.append(a[kind])
    return out


def flat(v):
    if v is None:
        return []
    if isinstance(v, (str, dict)):
        return [v]
    return [y for x in v for y in flat(x)]


def root_of(p):
    parts = p.split("/")
    if p.startswith("~/Library/"):
        return "/".join(parts[:3])
    if p.startswith("~/"):
        return "~/<dot or other>"
    if p.startswith("/Library/"):
        return "/".join(parts[:3])
    return "/" + (parts[1] if len(parts) > 1 else "")


stats = collections.Counter()
directive = {"zap": collections.Counter(), "uninstall": collections.Counter()}
roots = collections.Counter()
path_owners = collections.defaultdict(set)
version_pinned = []
placeholders = collections.Counter()
wild_launchctl = []
all_labels = set()

for c in feed:
    tok = c["token"]
    zaps = stanzas(c, "zap")
    unis = stanzas(c, "uninstall")
    stats["casks"] += 1
    stats["casks_with_zap"] += bool(zaps)
    stats["casks_with_uninstall"] += bool(unis)
    ver = str(c.get("version") or "").split(",")[0]
    mm = ".".join(ver.split(".")[:2]) if re.match(r"^\d+\.\d+", ver) else None
    seen_paths = set()
    for kind, blocks in (("zap", zaps), ("uninstall", unis)):
        for block in blocks:
            for b in flat(block):
                if not isinstance(b, dict):
                    continue
                for k, v in b.items():
                    vals = flat(v)
                    directive[kind][k] += len(vals)
                    if k in ("launchctl",):
                        for s in vals:
                            if isinstance(s, str):
                                all_labels.add(s)
                                if "*" in s:
                                    wild_launchctl.append((tok, kind, s))
                    if k in PATH_KEYS:
                        for p in vals:
                            if not isinstance(p, str) or p in seen_paths:
                                continue
                            seen_paths.add(p)
                            if kind == "zap":
                                stats["zap_paths"] += 1
                                roots[root_of(p)] += 1
                                path_owners[p].add(tok)
                                if any(ch in p for ch in "*?["):
                                    stats["zap_paths_glob"] += 1
                                if mm and len(mm) >= 3 and mm in p:
                                    version_pinned.append((tok, ver, p))
                            for ph in ("/$HOME", "$HOMEBREW_PREFIX", "$APPDIR", "$HOMEBREW_CELLAR"):
                                if ph in p:
                                    placeholders[ph] += 1
                            if not (p.startswith("~/") or p.startswith("/") or p.startswith("$")):
                                stats["relative_or_odd_paths"] += 1

# Ownership classes (base artifacts only, @variant suffixes merged into one product).
USER_ROOTS = ("~/Documents", "~/Desktop", "~/Downloads", "~/Music", "~/Movies", "~/Pictures", "~/Public",
              "~/Library/Mobile Documents", "/Users/Shared")
user_paths = collections.Counter()
user_casks = set()
by_product = collections.defaultdict(set)      # zap trash/delete path -> products
rmdir_by = collections.defaultdict(set)        # zap rmdir path -> products
uninstall_ids = collections.defaultdict(set)   # (pkgutil|launchctl, id) -> products (default uninstall)
for c in feed:
    base = c["token"].split("@")[0]
    for a in c["artifacts"]:
        for b in flat(a.get("zap")):
            if not isinstance(b, dict):
                continue
            for p in flat(b.get("rmdir")):
                rmdir_by[p].add(base)
            for k in ("trash", "delete"):
                for p in flat(b.get(k)):
                    if not isinstance(p, str):
                        continue
                    by_product[p].add(base)
                    root = next((u for u in USER_ROOTS if p == u or p.startswith(u + "/")), None)
                    if not root and re.match(r"^~/[^./][^/]*", p) and not p.startswith("~/Library"):
                        root = "~/<non-dot home folder>"
                    if root:
                        user_paths[root] += 1
                        user_casks.add(c["token"])
        for b in flat(a.get("uninstall")):
            if isinstance(b, dict):
                for k in ("pkgutil", "launchctl"):
                    for s in flat(b.get(k)):
                        if isinstance(s, str):
                            uninstall_ids[(k, s)].add(base)
multi = {p: t for p, t in by_product.items() if len(t) > 1}

shared = {p: sorted(t) for p, t in path_owners.items() if len(t) > 1}
shared_dirs = {p: t for p, t in shared.items() if "*" not in p}

# Source-level check: zap stanzas that interpolate #{version...} (the feed freezes them to one version).
rb_version_zap = []
rb_version_lines = 0
rb_version_kinds = collections.Counter()
casks_dir = os.path.join(ROOT, "repo", "Casks")
if os.path.isdir(casks_dir):
    for dp, _, fs in os.walk(casks_dir):
        for f in fs:
            if not f.endswith(".rb"):
                continue
            src = open(os.path.join(dp, f), encoding="utf-8").read()
            m = re.search(r"^\s*zap\b.*?(?=^\s*(?:caveats|end\s*$)|\Z)", src, re.S | re.M)
            if m and "#{version" in m.group(0):
                rb_version_zap.append(f[:-3])
                zap_lines = [l for l in m.group(0).split("\n") if "#{version" in l and re.search(r'"(~|/)', l)]
                rb_version_lines += len(zap_lines)
                for l in zap_lines:
                    rb_version_kinds.update(re.findall(r"#\{version[^}]*\}", l))

out = {
    "stats": dict(stats),
    "zap_directives": dict(directive["zap"]),
    "uninstall_directives": dict(directive["uninstall"]),
    "zap_roots_top25": roots.most_common(25),
    "placeholders_in_paths": dict(placeholders),
    "zap_paths_shared_by_2plus_casks": len(shared),
    "shared_non_glob_top20": sorted(shared_dirs.items(), key=lambda kv: -len(kv[1]))[:20],
    "zap_paths_containing_current_major_minor": len(version_pinned),
    "casks_with_version_pinned_zap_path": len({t for t, _, _ in version_pinned}),
    "version_pinned_examples": version_pinned[:8],
    "rb_casks_with_version_interpolated_zap": len(rb_version_zap),
    "rb_version_zap_path_lines": rb_version_lines,
    "rb_version_accessors": rb_version_kinds.most_common(10),
    "rb_examples": sorted(rb_version_zap)[:15],
    "user_content_trash_paths": dict(user_paths),
    "user_content_trash_paths_total": sum(user_paths.values()),
    "user_content_casks": len(user_casks),
    "trash_paths_of_2plus_products": len(multi),
    "trash_paths_of_2plus_products_literal": sum("*" not in p for p in multi),
    "trashed_by_one_rmdired_by_another": sorted(p for p in by_product if p in rmdir_by and rmdir_by[p] - by_product[p]),
    "uninstall_ids_of_2plus_products": len([1 for v in uninstall_ids.values() if len(v) > 1]),
    "wildcard_launchctl": wild_launchctl,
    "distinct_launchctl_labels": len(all_labels),
}
json.dump(out, sys.stdout, indent=1, default=list)
print()
