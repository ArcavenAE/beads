// Package v062migration performs the private, read-only admission inspection
// used by the v0.62.0 server-to-embedded migration bridge.
package v062migration

import "errors"

const (
	SchemaVersion = 1
	Operation     = "v062_source_inspection"
	EffectNone    = "none"

	// DigestScopeAdmissionObservation means the digest describes the two
	// consecutive descriptor-bound reads performed by admission. It is not a
	// lifetime lease on the source. Any future effectful apply must rebind and
	// reinspect the source while holding its own operation fence.
	DigestScopeAdmissionObservation = "admission_observation"

	StatusQualified  = "qualified"
	StatusRefused    = "refused"
	StatusUsageError = "usage_error"
)

// Code is a stable machine-readable admission outcome.
type Code string

const (
	CodeInvalidUsage              Code = "invalid_usage"
	CodePlatformUnsupported       Code = "platform_unsupported"
	CodeEmbeddedTargetUnavailable Code = "embedded_target_unavailable"
	CodeWorkspaceInvalid          Code = "workspace_invalid"
	CodeWorkspaceNotCanonical     Code = "workspace_not_canonical"
	CodeSourceVersionMissing      Code = "source_version_missing"
	CodeSourceVersionMismatch     Code = "source_version_mismatch"
	CodeSourceVersionAmbiguous    Code = "source_version_ambiguous"
	CodeSourceMetadataMissing     Code = "source_metadata_missing"
	CodeSourceMetadataMismatch    Code = "source_metadata_mismatch"
	CodeSourceLayoutMissing       Code = "source_layout_missing"
	CodeSourceRoutingUnsupported  Code = "source_routing_unsupported"
	CodeUnsafeSourceSymlink       Code = "unsafe_source_symlink"
	CodeUnsafeSourceHardlink      Code = "unsafe_source_hardlink"
	CodeUnsafeSourceObject        Code = "unsafe_source_object"
	CodeCrossDeviceSource         Code = "cross_device_source"
	CodeMixedStorageLayout        Code = "mixed_storage_layout"
	CodeRollbackCollision         Code = "rollback_collision"
	CodeSourceChanged             Code = "source_changed"
	CodeSourceUnverifiable        Code = "source_unverifiable"
)

// Result is the versioned JSON protocol shared by the hidden inspector and
// its shell bridge. Qualified results include Source and Target.
type Result struct {
	SchemaVersion int     `json:"schema_version"`
	Operation     string  `json:"operation"`
	Status        string  `json:"status"`
	Retryable     bool    `json:"retryable"`
	Effect        string  `json:"effect"`
	Code          Code    `json:"code,omitempty"`
	Source        *Source `json:"source,omitempty"`
	Target        *Target `json:"target,omitempty"`
}

type Source struct {
	Workspace string `json:"workspace"`
	Version   string `json:"version"`
	Backend   string `json:"backend"`
	Database  string `json:"database"`
	ProjectID string `json:"project_id"`
	// TreeSHA256 is admission evidence with the lifetime explicitly bounded
	// by DigestScope; it must never authorize a later effectful operation.
	TreeSHA256 string `json:"tree_sha256"`
	// DigestScope requires a future apply to rebind/reinspect under its fence.
	DigestScope string `json:"digest_scope"`
}

type Target struct {
	Version         string `json:"version"`
	Backend         string `json:"backend"`
	EmbeddedCapable bool   `json:"embedded_capable"`
}

// Refusal is the sole typed negative admission outcome. Error deliberately
// exposes only the stable code; OS paths and values never cross the protocol.
type Refusal struct {
	Code      Code   `json:"code"`
	Retryable bool   `json:"retryable"`
	Effect    string `json:"effect"`
	cause     error
}

func (r *Refusal) Error() string {
	if r == nil {
		return ""
	}
	return string(r.Code)
}

func (r *Refusal) Unwrap() error {
	if r == nil {
		return nil
	}
	return r.cause
}

func AsRefusal(err error) (*Refusal, bool) {
	var refusal *Refusal
	ok := errors.As(err, &refusal)
	return refusal, ok
}

func refuse(code Code, retryable bool, cause error) error {
	return &Refusal{Code: code, Retryable: retryable, Effect: EffectNone, cause: cause}
}

func QualifiedResult(workspace, targetVersion, database, projectID, treeSHA256 string) Result {
	return Result{
		SchemaVersion: SchemaVersion,
		Operation:     Operation,
		Status:        StatusQualified,
		Retryable:     false,
		Effect:        EffectNone,
		Source: &Source{
			Workspace:   workspace,
			Version:     "0.62.0",
			Backend:     "dolt-server",
			Database:    database,
			ProjectID:   projectID,
			TreeSHA256:  treeSHA256,
			DigestScope: DigestScopeAdmissionObservation,
		},
		Target: &Target{
			Version:         targetVersion,
			Backend:         "dolt-embedded",
			EmbeddedCapable: true,
		},
	}
}

func RefusedResult(code Code, retryable bool) Result {
	return Result{
		SchemaVersion: SchemaVersion,
		Operation:     Operation,
		Status:        StatusRefused,
		Retryable:     retryable,
		Effect:        EffectNone,
		Code:          code,
	}
}

func UsageErrorResult() Result {
	result := RefusedResult(CodeInvalidUsage, false)
	result.Status = StatusUsageError
	return result
}
