#!/bin/bash
# Scan-engine benchmark: every available CLI scanner over the fixture and a real tree.
#
#   research/bench/run.sh [fixture|real|both]     (default: both)
#   RUNS=5 WARMUP=1 REPEAT=3 REAL_TREE=~/projects research/bench/run.sh
#   ONLY='^bulkwalk' TAG=bulkwalk research/bench/run.sh fixture   # subset -> results/fixture-bulkwalk-*.json
#
# Per target it writes results/<target>-hyperfine.json (raw) and
# results/<target>-summary.json (wall, user+sys CPU, max RSS, reported totals vs
# ground truth), and prints a markdown table. Max RSS comes from /usr/bin/time -l,
# not hyperfine: its memory_usage_byte is cumulative over all commands of a run.
# Warm cache only: a cold-cache pass needs `sudo purge`, which this harness does not run.
# Needs: hyperfine; scanners that are missing are skipped. Install them with
#   brew install hyperfine gdu dua-cli dust parallel-disk-usage ncdu diskus
set -uo pipefail
BENCH="$(cd "$(dirname "$0")" && pwd)"
RES="$BENCH/results"
RUNS="${RUNS:-5}"
WARMUP="${WARMUP:-1}"
REPEAT="${REPEAT:-3}"   # untimed runs per tool used for reported totals
REAL_TREE="${REAL_TREE:-$HOME/projects}"
WHICH="${1:-both}"
ONLY="${ONLY:-}"          # regex on tool name
TAG="${TAG:+-$TAG}"
TMP="$(mktemp -d)"
mkdir -p "$RES"
command -v hyperfine >/dev/null || { echo "hyperfine missing: brew install hyperfine" >&2; exit 1; }

# name | timed command, disk usage ({} = root) | apparent-size command (- = none)
# The total is the largest line-leading integer of the output (children <= root),
# in bytes except du (KiB); ncdu writes a JSON export that is parsed below.
# dust runs at -d 1: at -d 0 it printed nothing when the tree had a >PATH_MAX path.
TOOLS=(
  "du|du -sk {}|du -A -sk {}"
  "gdu|gdu-go -n -p -s --no-prefix {}|gdu-go -n -p -s --no-prefix -a {}"
  "dua|dua -f bytes aggregate {}|dua -A -f bytes aggregate {}"
  "dua-apfs-clones|dua -f bytes --deduplicate-apfs-clones aggregate {}|-"
  "dust|dust -d 1 -c -P -b -o b {}|dust -s -d 1 -c -P -b -o b {}"
  "pdu|pdu -d 1 -b plain {}|pdu -q apparent-size -d 1 -b plain {}"
  "pdu-H|pdu -H -d 1 -b plain {}|pdu -H -q apparent-size -d 1 -b plain {}"
  "ncdu|ncdu --ignore-config -0 -o /dev/null {}|-"
  "ncdu-t8|ncdu --ignore-config -0 -t8 -o /dev/null {}|-"
  "diskus|diskus {}|diskus -b {}"
  "bulkwalk|$BENCH/tools/bulkwalk {}|-"
  "bulkwalk-ext|$BENCH/tools/bulkwalk -x {}|-"
)
# bulkwalk.c: serial fd-relative getattrlistbulk baseline; -x adds the APFS
# PRIVATESIZE|CLONEID|EXT_FLAGS attributes (cost question from T-0009).
[[ -x "$BENCH/tools/bulkwalk" && "$BENCH/tools/bulkwalk" -nt "$BENCH/bulkwalk.c" ]] ||
  { mkdir -p "$BENCH/tools" && cc -O2 -o "$BENCH/tools/bulkwalk" "$BENCH/bulkwalk.c"; }

bench_target() {  # $1 = label, $2 = root
  local label="$1" root="$2" line name cmd app bin hf_args=()
  local out="$TMP/$label"; mkdir -p "$out"
  LOAD0="$(sysctl -n vm.loadavg)"
  : > "$out/tools.txt"
  for line in "${TOOLS[@]}"; do
    IFS='|' read -r name cmd app <<< "$line"
    [[ -n "$ONLY" && ! "$name" =~ $ONLY ]] && continue
    bin="${cmd%% *}"
    command -v "$bin" >/dev/null || { echo "skip $name: $bin not installed" >&2; continue; }
    cmd="${cmd//\{\}/$root}"; app="${app//\{\}/$root}"
    printf '%s\t%s\t%s\n' "$name" "$cmd" "$app" >> "$out/tools.txt"
    hf_args+=(--command-name "$name" "$cmd")
    # Correctness runs outside hyperfine: run 1 under /usr/bin/time -l (exit code,
    # max RSS, peak footprint); all $REPEAT runs keep their reported total, so a
    # scanner whose total changes between identical runs shows up.
    for k in $(seq "$REPEAT"); do
      local c="$cmd"; [[ "$name" == ncdu* ]] && c="${cmd/\/dev\/null/$out/$name.ncdu.$k.json}"
      if [[ $k == 1 ]]; then
        /usr/bin/time -l $c > "$out/$name.out.$k" 2> "$out/$name.time"; echo $? > "$out/$name.exit"
      else
        $c > "$out/$name.out.$k" 2>/dev/null
      fi
    done
    [[ "$app" != "-" ]] && $app > "$out/$name.apparent" 2>/dev/null
  done
  echo "== hyperfine: $label ($root), warmup $WARMUP, runs $RUNS" >&2
  hyperfine -N -i --warmup "$WARMUP" --runs "$RUNS" --style basic \
    --export-json "$RES/$label$TAG-hyperfine.json" "${hf_args[@]}" >&2
  python3 - "$label" "$root" "$out" "$RES" "$TAG" "$LOAD0" <<'PY'
import json, os, platform, re, subprocess, sys
label, root, out, res, tag, load0 = sys.argv[1:7]

def last_int(text, scale=1):
    nums = [int(m.group(1)) for m in re.finditer(r"^\s*(\d+)", text, re.M)]
    return max(nums) * scale if nums else None

def ncdu_totals(path):
    # ncdu JSON export: [ver, ver, meta, [rootinfo, entries...]]; a list is a dir.
    # Hard links carry "ino" + "hlnkc"; count each (dev, ino) once.
    try: data = json.load(open(path))
    except Exception: return None, None, None
    seen, tot = set(), [0, 0, 0]
    def walk(node, dev):
        info, kids = (node[0], node[1:]) if isinstance(node, list) else (node, [])
        dev = info.get("dev", dev)
        if not isinstance(node, list):
            key = (dev, info["ino"]) if "ino" in info else None
            if key and key in seen: return
            if key: seen.add(key)
            tot[2] += 1
        tot[0] += info.get("dsize", 0); tot[1] += info.get("asize", 0)
        for k in kids: walk(k, dev)
    walk(data[3], 0)
    return tot[0], tot[1], tot[2]

def time_l(path):
    t = open(path, errors="replace").read()
    g = lambda pat: (lambda m: float(m.group(1)) if m else None)(re.search(pat, t))
    return {"real_s": g(r"([\d.]+) real"), "user_s": g(r"([\d.]+) user"), "sys_s": g(r"([\d.]+) sys"),
            "max_rss_bytes": g(r"(\d+)\s+maximum resident set size"),
            "peak_footprint_bytes": g(r"(\d+)\s+peak memory footprint"),
            "stderr_lines": sum(1 for l in t.splitlines() if not re.match(r"\s*[\d.]+\s", l))}

hf = {r["command"]: r for r in json.load(open(f"{res}/{label}{tag}-hyperfine.json"))["results"]}
gt = json.load(open(os.path.join(os.path.dirname(res), "fixtures", "ground_truth.json"))) if label == "fixture" else None
ref_disk = gt["visible_to_non_root"]["allocated_all"] if gt else None
ref_app = gt["visible_to_non_root"]["apparent_files"] if gt else None

rows = []
for line in open(f"{out}/tools.txt"):
    name, cmd, app = line.rstrip("\n").split("\t")
    r = hf.get(name, {})
    row = {"tool": name, "command": cmd, "apparent_command": app,
           "wall_mean_s": r.get("mean"), "wall_stddev_s": r.get("stddev"), "wall_min_s": r.get("min"),
           "wall_median_s": r.get("median"), "user_mean_s": r.get("user"), "sys_mean_s": r.get("system"),
           "exit_codes": sorted(set(r.get("exit_codes", []))),
           "exit_code": int(open(f"{out}/{name}.exit").read()),
           **time_l(f"{out}/{name}.time")}
    k = 1
    runs = []
    while os.path.exists(f"{out}/{name}.out.{k}"):
        if name.startswith("ncdu"):
            d, a, n = ncdu_totals(f"{out}/{name}.ncdu.{k}.json")
            runs.append(d)
            if k == 1: row["reported_apparent_bytes"], row["reported_items"] = a, n
        else:
            runs.append(last_int(open(f"{out}/{name}.out.{k}", errors="replace").read(), 1024 if name == "du" else 1))
        k += 1
    row["reported_disk_bytes_runs"] = runs
    row["reported_disk_bytes"] = runs[0] if runs else None
    row["total_stable_across_runs"] = len(set(runs)) == 1
    if not name.startswith("ncdu"):
        p = f"{out}/{name}.apparent"
        row["reported_apparent_bytes"] = last_int(open(p, errors="replace").read(), 1024 if name == "du" else 1) if os.path.exists(p) else None
    if gt:
        d, a = row["reported_disk_bytes"], row["reported_apparent_bytes"]
        row["disk_delta_bytes"] = d - ref_disk if d is not None else None
        row["apparent_delta_bytes"] = a - ref_app if a is not None else None
    rows.append(row)

def ver(cmd):
    try: return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip().splitlines()[0]
    except Exception: return None
versions = {"gdu": ver(["gdu-go", "--version"]), "dua": ver(["dua", "--version"]), "dust": ver(["dust", "--version"]),
            "pdu": ver(["pdu", "--version"]), "ncdu": ver(["ncdu", "--version"]), "diskus": ver(["diskus", "--version"]),
            "hyperfine": ver(["hyperfine", "--version"])}
machine = {"macos": platform.mac_ver()[0], "cpu": ver(["sysctl", "-n", "machdep.cpu.brand_string"]),
           "ncpu": os.cpu_count(), "mem_bytes": int(ver(["sysctl", "-n", "hw.memsize"]) or 0),
           "kern_maxvnodes": int(ver(["sysctl", "-n", "kern.maxvnodes"]) or 0),
           "load_avg_at_start": load0, "load_avg_at_summary": os.getloadavg()}
summary = {"target": label, "root": root, "cache": "warm", "machine": machine, "versions": versions,
           "ground_truth": {"allocated_visible": ref_disk, "apparent_visible": ref_app} if gt else None,
           "results": sorted(rows, key=lambda r: r["wall_mean_s"] or 1e9)}
json.dump(summary, open(f"{res}/{label}{tag}-summary.json", "w"), indent=2)

mb = lambda b: "n/a" if b is None else f"{b / 1e6:,.1f}"
print(f"\n### {label}: {root}\n")
print("| tool | wall mean ± sd (s) | user (s) | sys (s) | max RSS (MB) | disk total (MB) | same total every run | apparent (MB) | exit |")
print("|---|---|---|---|---|---|---|---|---|")
for r in summary["results"]:
    w = "n/a" if r["wall_mean_s"] is None else f'{r["wall_mean_s"]:.3f} ± {r["wall_stddev_s"] or 0:.3f}'
    print(f'| {r["tool"]} | {w} | {r["user_mean_s"] or 0:.2f} | {r["sys_mean_s"] or 0:.2f} | {mb(r["max_rss_bytes"])} '
          f'| {mb(r["reported_disk_bytes"])} | {"yes" if r["total_stable_across_runs"] else "NO: " + ", ".join(mb(x) for x in r["reported_disk_bytes_runs"])} '
          f'| {mb(r["reported_apparent_bytes"])} | {r["exit_code"]} |')
if gt:
    print(f"\nground truth (visible to non-root): allocated {mb(ref_disk)} MB, apparent (files) {mb(ref_app)} MB")
PY
}

"$BENCH/make_fixture.sh" > /dev/null
if [[ "$WHICH" == fixture || "$WHICH" == both ]]; then
  bench_target fixture "$BENCH/fixtures/tree"
fi
if [[ "$WHICH" == real || "$WHICH" == both ]]; then
  # The fixture lives inside ~/projects; lock it for this pass so the real-tree
  # numbers are not 300k synthetic files. Every scanner then sees one EACCES dir.
  chmod 000 "$BENCH/fixtures"; trap 'chmod 755 "$BENCH/fixtures"' EXIT
  bench_target real "$REAL_TREE"
  chmod 755 "$BENCH/fixtures"; trap - EXIT
fi
rm -rf "$TMP"
