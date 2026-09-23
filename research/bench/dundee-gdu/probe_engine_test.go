// macontrol probe (T-0032, dive-dundee-gdu). Runs gdu's own packages
// (dundee/gdu@848a5dd) against scratch fixtures under t.TempDir(). Nothing
// outside the temp dir is read or deleted. Injected into pkg/remove (external test package) through
// `go test -overlay` by run.sh, so the clone is never modified.
package remove_test

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/dundee/gdu/v5/pkg/analyze"
	"github.com/dundee/gdu/v5/pkg/fs"
	"github.com/dundee/gdu/v5/pkg/remove"
	"github.com/dundee/gdu/v5/report"
)

const mib = 1 << 20

func noIgnore(string, string) bool { return false }

func write(t *testing.T, path string, n int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, bytes.Repeat([]byte{0xA5}, n), 0o644); err != nil {
		t.Fatal(err)
	}
}

func child(t *testing.T, dir fs.Item, name string) fs.Item {
	t.Helper()
	for it := range dir.GetFiles(fs.SortByName, fs.SortAsc) {
		if it.GetName() == name {
			return it
		}
	}
	t.Fatalf("no child %q in %s", name, dir.GetPath())
	return nil
}

func allocated(path string) int64 {
	var st syscall.Stat_t
	if err := syscall.Lstat(path, &st); err != nil {
		return -1
	}
	return st.Blocks * 512
}

// F-0007 root cause: gdu's own WaitGroup (pkg/analyze/wait.go).
func TestProbeWaitGroupRearm(t *testing.T) {
	wg := (&analyze.WaitGroup{}).Init()
	wg.Add(1)
	wg.Done() // count 1 -> 0: check() unlocks the wait mutex
	wg.Add(1) // new outstanding job: Add never re-locks it
	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	select {
	case <-done:
		fmt.Println("RESULT waitgroup: Wait() returned while 1 job is still outstanding (bug reproduced)")
	case <-time.After(500 * time.Millisecond):
		fmt.Println("RESULT waitgroup: Wait() blocked as expected (no bug)")
	}
}

// Deleting one link of a hard-linked file: what does the tree say afterwards?
func TestProbeHardlinkDelete(t *testing.T) {
	for _, deleteCounted := range []bool{false, true} {
		root := t.TempDir()
		write(t, filepath.Join(root, "a", "data.bin"), 4*mib)
		write(t, filepath.Join(root, "keep", "other.bin"), 1*mib)
		if err := os.MkdirAll(filepath.Join(root, "b"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Link(filepath.Join(root, "a", "data.bin"), filepath.Join(root, "b", "data.bin")); err != nil {
			t.Fatal(err)
		}

		top := analyze.CreateAnalyzer().AnalyzeDir(root, noIgnore, nil)
		top.UpdateStats(make(fs.HardLinkedItems)) // what tui/actions.go:108 does
		a, b := child(t, top, "a"), child(t, top, "b")
		before := fmt.Sprintf("root=%d a=%d b=%d", top.GetUsage(), a.GetUsage(), b.GetUsage())

		// the link whose folder got the bytes is "counted", the other one reads 0
		counted, uncounted := a, b
		if a.GetUsage() == 0 {
			counted, uncounted = b, a
		}
		victimDir, keptDir := uncounted, counted
		if deleteCounted {
			victimDir, keptDir = counted, uncounted
		}
		keptPath := filepath.Join(root, keptDir.GetName(), "data.bin")
		link := child(t, victimDir, "data.bin")
		if err := remove.ItemFromDir(victimDir, link); err != nil { // tui default remover (tui.go:162)
			t.Fatal(err)
		}
		realAfter := allocated(keptPath) + allocated(filepath.Join(root, "keep", "other.bin"))
		fmt.Printf("RESULT hardlink deleteCounted=%v before[%s] deleted=%s/data.bin after[root=%d a=%d b=%d] real_on_disk=%d\n",
			deleteCounted, before, victimDir.GetName(), top.GetUsage(), a.GetUsage(), b.GetUsage(), realAfter)
	}
}

// Import a report and delete from it: which real path does gdu remove?
func TestProbeImportDelete(t *testing.T) {
	base := t.TempDir()
	victim := filepath.Join(base, "elsewhere", "victim")
	write(t, filepath.Join(victim, "keep.txt"), 100)
	write(t, filepath.Join(base, "elsewhere", "victim2.txt"), 100)
	reportRoot := filepath.Join(base, "report-root") // does not even need to exist

	js := fmt.Sprintf(`[1,2,{"progname":"gdu","progver":"x","timestamp":0},
[{"name":%q,"asize":0,"dsize":0,"items":4},
 {"name":"notes.txt","asize":10,"dsize":4096},
 [{"name":%q,"asize":1,"dsize":4096,"items":2},{"name":"x.bin","asize":1,"dsize":4096}],
 {"name":"../elsewhere/victim2.txt","asize":1,"dsize":4096}
]]`, reportRoot, victim)

	top, err := report.ReadAnalysis(strings.NewReader(js)) // what `gdu -f` calls (tui/actions.go:237)
	if err != nil {
		t.Fatal(err)
	}
	for _, it := range top.Files {
		fmt.Printf("RESULT import row name=%q -> GetPath()=%q\n", it.GetName(), it.GetPath())
	}
	for _, it := range append([]fs.Item(nil), top.Files...) {
		if it.GetName() == "notes.txt" {
			continue
		}
		p := it.GetPath()
		err := remove.ItemFromDir(top, it)
		_, statErr := os.Lstat(p)
		fmt.Printf("RESULT import delete row=%q removed=%q err=%v still_exists=%v\n", it.GetName(), p, err, statErr == nil)
	}
}
