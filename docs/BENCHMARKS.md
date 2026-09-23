# Scan engine benchmarks

`mcscan` is the command-line front end of `ScanEngine.scan`, the same walk the Disk Map runs. It is
read-only. Numbers come from `research/bench/run.sh`: hyperfine, warm cache, 1 warmup and 5 timed
runs, plus 3 untimed runs per tool to check that the total is the same every run.

## v1 integration, 2026-09-23

Apple M1, 8 cores, 8 GB, macOS 26.6, `kern.maxvnodes` 120,350. Another process held one core at 100%
throughout (load average 5.5 to 8.4), so compare tools within a table, not across dates. The fastest
exact tool is in bold.

```
ONLY='^(mcscan|dua|ncdu-t8)$' TAG=v1 research/bench/run.sh both
```

### Fixture: `research/bench/fixtures/tree`

311,437 nodes, with hard links, clones, deep chains and one unreadable folder. Ground truth:
2,368,040,960 B allocated, 7,303,463,078 B apparent.

| tool | wall mean ± sd | user | sys | max RSS | allocated total | vs truth | stable |
|---|---|---|---|---|---|---|---|
| dua | 0.601 ± 0.013 s | 0.15 s | 1.72 s | 11.3 MB | 2,359,623,680 B | −8,417,280 B | yes |
| **mcscan** | **0.683 ± 0.031 s** | 0.07 s | 2.21 s | 52.8 MB | **2,368,040,960 B** | **exact** | yes |
| ncdu -t8 | 1.581 ± 0.111 s | 0.12 s | 4.68 s | 13.9 MB | 2,368,040,960 B | exact | yes |

### Real tree: `~/projects`

About 850k nodes, a live tree that other agents were writing to during the run.

| tool | wall mean ± sd | user | sys | max RSS | allocated total | stable |
|---|---|---|---|---|---|---|
| dua | 1.954 ± 0.044 s | 0.60 s | 6.93 s | 17.4 MB | 33,392,095,232 B | yes |
| **mcscan** | **2.104 ± 0.020 s** | 0.30 s | 8.55 s | 93.8 MB | 33,392,095,232 B | yes |
| ncdu -t8 | 2.876 ± 0.094 s | 0.33 s | 11.13 s | 29.9 MB | 33,392,095,232 B | yes |

### Reading

- **Headline:** mcscan is the fastest scanner that gets the fixture exactly right: 2.3× faster than
  ncdu -t8, the only other exact tool. dua is 12% faster and misses 8.4 MB of hard-linked data.
  On `~/projects` all three agree to the byte: mcscan is 1.37× faster than ncdu -t8, and dua is 7% faster.
- Against M1 (`results/fixture-summary.json`, `results/fixture-bulkwalk-summary.json`): the serial
  fd-relative walker took 7.10 s on the fixture and 11.41 s on `~/projects`. The parallel engine
  takes 0.68 s and 2.10 s, 10× and 5× faster (the real tree has grown since). The next-fastest exact tool then was also ncdu -t8, at 1.47 s.
- Memory is spent on purpose: mcscan keeps the whole tree for the map, while the others only add up
  sizes. `mcscan --stats`: 75 B/node on the fixture (23.6 MB for 311k nodes, target under 80) and
  126 B/node on `~/projects`, where names are longer.
- Apparent size: mcscan reports 7,303,489,524 B, 26,446 B (0.0004%) above the ground truth's
  files-only figure. The difference is not investigated yet. The allocated total is the number the
  app shows and promises.
- Exit code 1 for mcscan and ncdu: both report the fixture's one unreadable folder, as designed
  ("not scanned", never 0 B). dua exits 1 as well.

Raw data: `research/bench/results/{fixture,real}-v1-{summary,hyperfine}.json`.
