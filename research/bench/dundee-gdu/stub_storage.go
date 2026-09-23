// macontrol probe stub (not gdu code). Replaces pkg/analyze/storage.go through
// `go test -overlay` so the probe builds without badger. Only the API used by
// report/export.go, tui/actions.go, webui and stdout is kept; it always fails.
package analyze

import (
	"errors"

	"github.com/dundee/gdu/v5/pkg/fs"
)

type Storage struct{}

func NewStorage(storagePath, topDir string) *Storage { return &Storage{} }
func (s *Storage) Open() func()                     { return func() {} }
func (s *Storage) GetDirForPath(path string) (fs.Item, error) {
	return nil, errors.New("storage stubbed out by macontrol probe")
}
