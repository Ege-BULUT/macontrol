#!/usr/bin/env python3
"""How much of the curated zap data could a bundle-id / app-name matcher find?

For each cask with a zap stanza and a derivable bundle id, classify every zap trash/delete path by the
strongest key that appears in it: bundle id, bundle-id prefix (vendor, e.g. com.docker), app name, or none.
This is the upper bound a macontrol matcher can reach per key, and the list of 'none' paths is the part
only curated data (or a vendor rule) supplies. Read-only; input is the cask.json feed.
"""
import collections, json, os, re

feed = json.load(open(os.path.expanduser(
    "~/projects/macontrol/research/sources/homebrew-homebrew-cask/cask.json")))


def flat(v):
    if v is None:
        return []
    if isinstance(v, (str, dict)):
        return [v]
    return [y for x in v for y in flat(x)]


def norm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())


cls = collections.Counter()
by_root = collections.defaultdict(collections.Counter)
casks_used = 0
none_examples = []
for c in feed:
    zap, quit_ids, apps = [], [], []
    for a in c["artifacts"]:
        for b in flat(a.get("zap")):
            if isinstance(b, dict):
                for k in ("trash", "delete"):
                    zap += [p for p in flat(b.get(k)) if isinstance(p, str)]
        for b in flat(a.get("uninstall")):
            if isinstance(b, dict):
                quit_ids += [q for q in flat(b.get("quit")) if isinstance(q, str) and "*" not in q]
        for x in flat(a.get("app")):
            if isinstance(x, str):
                apps.append(os.path.basename(x)[:-4] if x.endswith(".app") else x)
    saved = [m.group(1) for p in zap for m in [re.search(r"Saved Application State/([^/*]+)\.savedState$", p)] if m]
    bids = sorted(set(quit_ids + saved))
    if not zap or not bids:
        continue
    casks_used += 1
    vendors = {".".join(b.split(".")[:2]).lower() for b in bids if b.count(".") >= 2}
    names = {norm(n) for n in apps + [n for n in c.get("name") or []] if len(norm(n)) >= 4}
    for p in zap:
        low = p.lower()
        root = "/".join(p.split("/")[:3]) if p.startswith("~/Library/") else p.split("/")[0] + "/" + (p.split("/")[1][:1] == "." and ".<dot>" or "<other>")
        if any(b.lower() in low for b in bids):
            k = "bundle_id"
        elif any(v in low for v in vendors):
            k = "vendor_prefix"
        elif any(n in norm(p) for n in names):
            k = "app_name"
        else:
            k = "none"
            if len(none_examples) < 25:
                none_examples.append((c["token"], p))
        cls[k] += 1
        by_root[root][k] += 1

tot = sum(cls.values())
print(f"casks with zap and a derivable bundle id: {casks_used}; zap trash/delete paths: {tot}")
for k, v in cls.most_common():
    print(f"  {k:14s} {v:6d}  {100 * v / tot:5.1f}%")
print("by root (top 12):")
for r, cnt in sorted(by_root.items(), key=lambda kv: -sum(kv[1].values()))[:12]:
    n = sum(cnt.values())
    print(f"  {r:40s} {n:5d}  " + "  ".join(f"{k}={100 * cnt[k] / n:.0f}%" for k in ("bundle_id", "vendor_prefix", "app_name", "none")))
print("examples of 'none':")
for t, p in none_examples:
    print("  ", t, p)
