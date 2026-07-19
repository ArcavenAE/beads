//go:build !linux

package v062migration

// Inspect fails before touching the source on platforms outside the single
// qualified Linux/amd64 migration environment.
func Inspect(_ string, _ string) (Result, error) {
	return Result{}, refuse(CodePlatformUnsupported, false, nil)
}
