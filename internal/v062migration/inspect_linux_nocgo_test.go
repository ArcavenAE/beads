//go:build linux && !cgo

package v062migration

import "testing"

func TestInspectWithoutCGORefusesBeforeSourceAccess(t *testing.T) {
	_, err := Inspect("/definitely/not/a/source", "1.1.0")
	refusal, ok := AsRefusal(err)
	if !ok {
		t.Fatalf("Inspect() error = %T %v, want Refusal", err, err)
	}
	if refusal.Code != CodeEmbeddedTargetUnavailable || refusal.Retryable || refusal.Effect != EffectNone {
		t.Fatalf("refusal = %#v", refusal)
	}
}
