// macontrol probe stub (not gdu code). Replaces pkg/analyze/sqlite_modernc.go
// through `go test -overlay` so the probe builds without compiling modernc.org/sqlite.
package analyze

func checkAvailable() error { return nil }
