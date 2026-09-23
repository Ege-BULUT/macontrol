//go:build darwin

// Research probe (macontrol dive-tw93-mole, T-0012). Run it inside a Mole@a7fa8dd clone:
//   cp zz_macontrol_probe_test.go <mole>/cmd/analyze/ && go test -count=1 -run TestMacontrolProbe -v ./cmd/analyze
// Result 2026-09-23: top30 entries_after_complete=30 of 45 (hidden=983040 B); stale after_deep_delete_shown=12582912 stale_flag=false.
package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

func TestMacontrolProbeTop30(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	root := t.TempDir()
	for i := 0; i < 45; i++ {
		d := filepath.Join(root, fmt.Sprintf("d%02d", i))
		if err := os.Mkdir(d, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, "f"), bytes.Repeat([]byte{1}, 8192*(i+1)), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	var f, d, b int64
	cp := &atomic.Value{}
	cp.Store("")
	start := startLiveScanCmd(root, &f, &d, &b, cp)().(liveScanStartMsg)
	t.Logf("live start: %d entries visible while scanning", len(start.entries))
	res := drainLiveScanToResultMsg(t, start)
	var sum int64
	for _, e := range res.result.Entries {
		sum += e.Size
	}
	t.Logf("PROBE top30: children=45 entries_after_complete=%d total=%d sum_visible=%d hidden=%d",
		len(res.result.Entries), res.result.TotalSize, sum, res.result.TotalSize-sum)
}

func TestMacontrolProbeStaleCache(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	root := t.TempDir()
	deep := filepath.Join(root, "A", "B")
	if err := os.MkdirAll(deep, 0o755); err != nil {
		t.Fatal(err)
	}
	big := filepath.Join(deep, "big.bin")
	if err := os.WriteFile(big, bytes.Repeat([]byte{7}, 12<<20), 0o644); err != nil {
		t.Fatal(err)
	}
	var f, d, b int64
	cp := &atomic.Value{}
	cp.Store("")
	res := drainLiveScanToResultMsg(t, startLiveScanCmd(root, &f, &d, &b, cp)().(liveScanStartMsg))
	if err := saveCacheToDisk(root, res.result); err != nil { // finishLiveScan does this (update.go:236-238)
		t.Fatal(err)
	}
	if err := os.Remove(big); err != nil { // deep delete, e.g. by `mo clean` or Finder
		t.Fatal(err)
	}
	msg := model{}.scanCmd(root)().(scanResultMsg)
	t.Logf("PROBE stale: before=%d after_deep_delete_shown=%d stale_flag=%v", res.result.TotalSize, msg.result.TotalSize, msg.stale)
}
