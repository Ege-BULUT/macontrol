// macontrol probe (T-0032, dive-dundee-gdu). Injected into package tui of
// dundee/gdu@848a5dd through `go test -overlay` by run.sh (gdu's own tui tests
// are masked out so only this file is compiled). Scratch fixture only.
package tui

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/dundee/gdu/v5/internal/testapp"
	"github.com/dundee/gdu/v5/pkg/fs"
	"github.com/rivo/tview"
)

// `gdu --type log <dir>` then `d` on a folder: is delete offered, and what goes?
func TestProbeTypeFilterDelete(t *testing.T) {
	root := t.TempDir()
	logs := filepath.Join(root, "logs")
	if err := os.MkdirAll(logs, 0o755); err != nil {
		t.Fatal(err)
	}
	_ = os.WriteFile(filepath.Join(logs, "app.log"), bytes.Repeat([]byte("l"), 2048), 0o644)
	_ = os.WriteFile(filepath.Join(logs, "video.mov"), bytes.Repeat([]byte{0xA5}, 4<<20), 0o644)

	screen := testapp.CreateSimScreen()
	defer screen.Fini()
	app := testapp.CreateMockedApp(true)
	ui := CreateUI(app, screen, &bytes.Buffer{}, false, false, false, false)
	ui.SetIncludeTypes([]string{"log"}) // what --type log does (cmd/gdu/app/app.go:321)
	ui.done = make(chan struct{})
	if err := ui.AnalyzePath(root, nil); err != nil {
		t.Fatal(err)
	}
	<-ui.done
	for _, f := range ui.app.(*testapp.MockedApp).GetUpdateDraws() {
		f()
	}

	row := -1
	for r := 0; r < ui.table.GetRowCount(); r++ {
		if it, ok := ui.table.GetCell(r, 0).GetReference().(fs.Item); ok && it.GetName() == "logs" {
			row = r
			fmt.Printf("RESULT typefilter row logs shown usage=%d size=%d\n", it.GetUsage(), it.GetSize())
		}
	}
	if row < 0 {
		t.Fatal("logs row not found")
	}
	ui.table.Select(row, 0)
	ui.confirmDeletion(ActionDelete) // the `d` key path (keys.go -> confirmDeletion)
	name, page := ui.pages.GetFrontPage()
	text := ""
	if m, ok := page.(*tview.Modal); ok {
		_ = m
		text = "modal"
	}
	fmt.Printf("RESULT typefilter front page after d: %q (%s) IsFilteringFiles=%v noDeleteWithFilter=%v\n",
		name, text, ui.IsFilteringFiles(), ui.noDeleteWithFilter)
	if name != "confirm" {
		return
	}
	ui.deleteSelected(ActionDelete) // what the Yes button runs (tui.go:706-707)
	<-ui.done
	_, errMov := os.Stat(filepath.Join(logs, "video.mov"))
	_, errDir := os.Stat(logs)
	fmt.Printf("RESULT typefilter after Yes: logs/ exists=%v video.mov exists=%v\n", errDir == nil, errMov == nil)
}
