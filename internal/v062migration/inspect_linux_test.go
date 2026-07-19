//go:build linux && cgo

package v062migration

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"testing"

	"golang.org/x/sys/unix"
)

func TestInspectQualifiesExactV062ServerTreeWithoutMutation(t *testing.T) {
	project := newV062Project(t)
	before := snapshotTree(t, project)

	result, err := Inspect(project, "1.1.0")
	if err != nil {
		t.Fatalf("Inspect() error = %v", err)
	}
	if result.SchemaVersion != 1 || result.Operation != Operation || result.Status != StatusQualified {
		t.Fatalf("unexpected envelope: %#v", result)
	}
	if result.Retryable || result.Effect != EffectNone {
		t.Fatalf("qualified retryable/effect = %v/%q", result.Retryable, result.Effect)
	}
	if result.Source.Workspace != project || result.Source.Version != "0.62.0" || result.Source.Backend != "dolt-server" {
		t.Fatalf("unexpected source: %#v", result.Source)
	}
	if result.Source.Database != "smoke" {
		t.Fatalf("source database = %q, want %q", result.Source.Database, "smoke")
	}
	if result.Source.ProjectID != "7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6" {
		t.Fatalf("source project ID = %q", result.Source.ProjectID)
	}
	if result.Source.DigestScope != DigestScopeAdmissionObservation {
		t.Fatalf("digest scope = %q, want %q", result.Source.DigestScope, DigestScopeAdmissionObservation)
	}
	if len(result.Source.TreeSHA256) != 64 {
		t.Fatalf("tree digest = %q", result.Source.TreeSHA256)
	}
	if result.Target.Version != "1.1.0" || result.Target.Backend != "dolt-embedded" || !result.Target.EmbeddedCapable {
		t.Fatalf("unexpected target: %#v", result.Target)
	}
	if after := snapshotTree(t, project); after != before {
		t.Fatalf("inspection mutated source tree\nbefore: %s\nafter:  %s", before, after)
	}
}

func TestInspectAdmitsAuthenticV062DoltAncillaryLayout(t *testing.T) {
	project := newV062Project(t)
	for _, dir := range []string{
		filepath.Join(project, ".beads", "dolt", ".doltcfg"),
		filepath.Join(project, ".beads", "dolt", ".dolt", "stats", ".dolt"),
		filepath.Join(project, ".beads", "dolt", "smoke", ".dolt", "stats", ".dolt"),
	} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	for path, content := range map[string]string{
		filepath.Join(project, ".beads", ".gitignore"):                                              "dolt/\n*.db\n",
		filepath.Join(project, ".beads", ".beads-credential-key"):                                   "fixture-key\n",
		filepath.Join(project, ".beads", "config.yaml"):                                             "dolt:\n  auto-start: true\n",
		filepath.Join(project, ".beads", "dolt-server.port"):                                        "3307\n",
		filepath.Join(project, ".beads", "ephemeral.sqlite3"):                                       "known v0.62 ephemeral store\n",
		filepath.Join(project, ".beads", "interactions.jsonl"):                                      "",
		filepath.Join(project, ".beads", "last-touched"):                                            "0\n",
		filepath.Join(project, ".beads", "dolt", ".doltcfg", "privileges.db"):                       "dolt-owned ancillary database\n",
		filepath.Join(project, ".beads", "dolt", ".dolt", "stats", ".dolt", "config.json"):          "{}\n",
		filepath.Join(project, ".beads", "dolt", ".dolt", "stats", ".dolt", "repo_state.json"):      "{\"head\":\"refs/heads/main\"}\n",
		filepath.Join(project, ".beads", "dolt", "smoke", ".dolt", "stats", ".dolt", "config.json"): "{}\n",
	} {
		mustWrite(t, path, content)
	}

	if _, err := Inspect(project, "1.1.0"); err != nil {
		t.Fatalf("Inspect() rejected authentic v0.62 ancillary layout: %v", err)
	}
}

func TestInspectAdmitsDefaultV062MetadataWithoutPersistedServerEndpoint(t *testing.T) {
	project := newV062Project(t)
	mustWrite(t, filepath.Join(project, ".beads", "metadata.json"), `{
  "database": "dolt",
  "backend": "dolt",
  "dolt_mode": "server",
  "dolt_database": "smoke",
  "project_id": "7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"
}
`)
	before := snapshotTree(t, project)

	if _, err := Inspect(project, "1.1.0"); err != nil {
		t.Fatalf("Inspect() rejected default v0.62 metadata: %v", err)
	}
	if after := snapshotTree(t, project); after != before {
		t.Fatalf("inspection mutated source tree\nbefore: %s\nafter:  %s", before, after)
	}
}

func TestInspectTreeDigestChangesWithRegularFileContent(t *testing.T) {
	first := newV062Project(t)
	second := newV062Project(t)
	if err := os.WriteFile(filepath.Join(second, ".beads", "dolt", "smoke", ".dolt", "repo_state.json"), []byte("{\"head\":\"other\"}\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	left, err := Inspect(first, "1.1.0")
	if err != nil {
		t.Fatal(err)
	}
	right, err := Inspect(second, "1.1.0")
	if err != nil {
		t.Fatal(err)
	}
	if left.Source.TreeSHA256 == right.Source.TreeSHA256 {
		t.Fatalf("different trees produced digest %q", left.Source.TreeSHA256)
	}
}

func TestInspectTreeDigestIsStableAcrossRepeatedAndEquivalentTrees(t *testing.T) {
	first := newV062Project(t)
	second := newV062Project(t)

	firstResult, err := Inspect(first, "1.1.0")
	if err != nil {
		t.Fatal(err)
	}
	repeatedResult, err := Inspect(first, "1.1.0")
	if err != nil {
		t.Fatal(err)
	}
	secondResult, err := Inspect(second, "1.1.0")
	if err != nil {
		t.Fatal(err)
	}
	if firstResult.Source.TreeSHA256 != repeatedResult.Source.TreeSHA256 {
		t.Fatalf("repeated inspection changed digest: %q != %q", firstResult.Source.TreeSHA256, repeatedResult.Source.TreeSHA256)
	}
	if firstResult.Source.TreeSHA256 != secondResult.Source.TreeSHA256 {
		t.Fatalf("equivalent trees changed digest: %q != %q", firstResult.Source.TreeSHA256, secondResult.Source.TreeSHA256)
	}
}

func TestInspectRefusesUnsafeAndMixedSourceShapes(t *testing.T) {
	tests := []struct {
		name string
		want Code
		edit func(*testing.T, string)
	}{
		{
			name: "version missing",
			want: CodeSourceVersionMissing,
			edit: func(t *testing.T, project string) {
				t.Helper()
				if err := os.Remove(filepath.Join(project, ".beads", ".local_version")); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "version mismatch",
			want: CodeSourceVersionMismatch,
			edit: func(t *testing.T, project string) {
				t.Helper()
				mustWrite(t, filepath.Join(project, ".beads", ".local_version"), "0.61.0\n")
			},
		},
		{
			name: "version symlink",
			want: CodeSourceVersionAmbiguous,
			edit: func(t *testing.T, project string) {
				t.Helper()
				version := filepath.Join(project, ".beads", ".local_version")
				if err := os.Rename(version, version+".real"); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(".local_version.real", version); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "version fifo is an unsafe object, not an ambiguous symlink",
			want: CodeUnsafeSourceObject,
			edit: func(t *testing.T, project string) {
				t.Helper()
				version := filepath.Join(project, ".beads", ".local_version")
				if err := os.Remove(version); err != nil {
					t.Fatal(err)
				}
				if err := unix.Mkfifo(version, 0o600); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "metadata mismatch",
			want: CodeSourceMetadataMismatch,
			edit: func(t *testing.T, project string) {
				t.Helper()
				setV062MetadataField(t, project, "backend", "postgres")
			},
		},
		{
			name: "current global Dolt database selector",
			want: CodeSourceMetadataMismatch,
			edit: func(t *testing.T, project string) {
				t.Helper()
				setV062MetadataField(t, project, "global_dolt_database", "other")
			},
		},
		{
			name: "current global project selector",
			want: CodeSourceMetadataMismatch,
			edit: func(t *testing.T, project string) {
				t.Helper()
				setV062MetadataField(t, project, "global_project_id", "other")
			},
		},
		{
			name: "metadata symlink",
			want: CodeUnsafeSourceSymlink,
			edit: func(t *testing.T, project string) {
				t.Helper()
				metadata := filepath.Join(project, ".beads", "metadata.json")
				if err := os.Rename(metadata, metadata+".real"); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink("metadata.json.real", metadata); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "metadata fifo is an unsafe object, not a symlink",
			want: CodeUnsafeSourceObject,
			edit: func(t *testing.T, project string) {
				t.Helper()
				metadata := filepath.Join(project, ".beads", "metadata.json")
				if err := os.Remove(metadata); err != nil {
					t.Fatal(err)
				}
				if err := unix.Mkfifo(metadata, 0o600); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "symlinked dolt root",
			want: CodeUnsafeSourceSymlink,
			edit: func(t *testing.T, project string) {
				t.Helper()
				dolt := filepath.Join(project, ".beads", "dolt")
				if err := os.Rename(dolt, dolt+".real"); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink("dolt.real", dolt); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "mixed provider",
			want: CodeMixedStorageLayout,
			edit: func(t *testing.T, project string) {
				t.Helper()
				if err := os.Mkdir(filepath.Join(project, ".beads", "embeddeddolt"), 0o700); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "project env routing override",
			want: Code("source_routing_unsupported"),
			edit: func(t *testing.T, project string) {
				t.Helper()
				mustWrite(t, filepath.Join(project, ".beads", ".env"), "BEADS_DOLT_SERVER_HOST=poison.invalid\n")
			},
		},
		{
			name: "project redirect routing override",
			want: Code("source_routing_unsupported"),
			edit: func(t *testing.T, project string) {
				t.Helper()
				mustWrite(t, filepath.Join(project, ".beads", "redirect"), "../other/.beads\n")
			},
		},
		{
			name: "arbitrary root db artifact",
			want: CodeMixedStorageLayout,
			edit: func(t *testing.T, project string) {
				t.Helper()
				mustWrite(t, filepath.Join(project, ".beads", "unrecognized.DB"), "sqlite-like bytes")
			},
		},
		{
			name: "arbitrary root sqlite artifact",
			want: CodeMixedStorageLayout,
			edit: func(t *testing.T, project string) {
				t.Helper()
				mustWrite(t, filepath.Join(project, ".beads", "unrecognized.sqlite3"), "sqlite-like bytes")
			},
		},
		{
			name: "unexpected additional dolt database root",
			want: CodeMixedStorageLayout,
			edit: func(t *testing.T, project string) {
				t.Helper()
				other := filepath.Join(project, ".beads", "dolt", "other", ".dolt")
				if err := os.MkdirAll(other, 0o700); err != nil {
					t.Fatal(err)
				}
				mustWrite(t, filepath.Join(other, "config.json"), "{}\n")
				mustWrite(t, filepath.Join(other, "repo_state.json"), "{\"head\":\"refs/heads/main\"}\n")
			},
		},
		{
			name: "rollback collision",
			want: CodeRollbackCollision,
			edit: func(t *testing.T, project string) {
				t.Helper()
				if err := os.Mkdir(filepath.Join(project, ".beads-v0.62.0-rollback"), 0o700); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "hard link",
			want: CodeUnsafeSourceHardlink,
			edit: func(t *testing.T, project string) {
				t.Helper()
				source := filepath.Join(project, ".beads", "dolt", "config.yaml")
				if err := os.Link(source, filepath.Join(project, ".beads", "hardlink")); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "fifo",
			want: CodeUnsafeSourceObject,
			edit: func(t *testing.T, project string) {
				t.Helper()
				if err := unix.Mkfifo(filepath.Join(project, ".beads", "pipe"), 0o600); err != nil {
					t.Fatal(err)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			project := newV062Project(t)
			tt.edit(t, project)
			before := snapshotTree(t, project)
			_, err := Inspect(project, "1.1.0")
			assertRefusalCode(t, err, tt.want)
			if after := snapshotTree(t, project); after != before {
				t.Fatalf("refusal mutated source tree")
			}
		})
	}
}

func TestInspectRefusesMissingRequiredLayoutEntries(t *testing.T) {
	// The required-layout gate is one of the two central admission decisions.
	// Deleting any required layout entry must fail closed with a stable
	// source_layout_missing code, never admit a partial Dolt-server tree.
	tests := []struct {
		name   string
		remove string
		want   Code
	}{
		{"beads directory", ".beads", CodeSourceLayoutMissing},
		{"dolt root", ".beads/dolt", CodeSourceLayoutMissing},
		{"dolt config", ".beads/dolt/config.yaml", CodeSourceLayoutMissing},
		{"server dolt directory", ".beads/dolt/.dolt", CodeSourceLayoutMissing},
		{"server config", ".beads/dolt/.dolt/config.json", CodeSourceLayoutMissing},
		{"server repo state", ".beads/dolt/.dolt/repo_state.json", CodeSourceLayoutMissing},
		{"database dolt directory", ".beads/dolt/smoke/.dolt", CodeSourceLayoutMissing},
		{"database config", ".beads/dolt/smoke/.dolt/config.json", CodeSourceLayoutMissing},
		{"database repo state", ".beads/dolt/smoke/.dolt/repo_state.json", CodeSourceLayoutMissing},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			project := newV062Project(t)
			if err := os.RemoveAll(filepath.Join(project, filepath.FromSlash(tt.remove))); err != nil {
				t.Fatal(err)
			}
			before := snapshotTree(t, project)
			_, err := Inspect(project, "1.1.0")
			assertRefusalCode(t, err, tt.want)
			if after := snapshotTree(t, project); after != before {
				t.Fatalf("refusal mutated source tree")
			}
		})
	}
}

func TestInspectRefusesMissingMetadata(t *testing.T) {
	project := newV062Project(t)
	if err := os.Remove(filepath.Join(project, ".beads", "metadata.json")); err != nil {
		t.Fatal(err)
	}
	before := snapshotTree(t, project)
	_, err := Inspect(project, "1.1.0")
	assertRefusalCode(t, err, CodeSourceMetadataMissing)
	if after := snapshotTree(t, project); after != before {
		t.Fatalf("refusal mutated source tree")
	}
}

func TestInspectRefusesMalformedV062Metadata(t *testing.T) {
	// parseMetadata is the second central admission gate. Every rejected field,
	// pattern, and JSON-shape branch must collapse to a non-retryable
	// source_metadata_mismatch rather than admit a foreign or ambiguous source.
	tests := []struct {
		name string
		edit func(*testing.T, string)
	}{
		{
			name: "backend not dolt",
			edit: func(t *testing.T, project string) { setV062MetadataField(t, project, "backend", "sqlite") },
		},
		{
			name: "database not dolt",
			edit: func(t *testing.T, project string) { setV062MetadataField(t, project, "database", "sqlite") },
		},
		{
			name: "dolt mode not server",
			edit: func(t *testing.T, project string) { setV062MetadataField(t, project, "dolt_mode", "embedded") },
		},
		{
			name: "non-loopback server host",
			edit: func(t *testing.T, project string) { setV062MetadataField(t, project, "dolt_server_host", "10.0.0.5") },
		},
		{
			name: "invalid dolt database name",
			edit: func(t *testing.T, project string) { setV062MetadataField(t, project, "dolt_database", "smoke;drop") },
		},
		{
			name: "non-uuid project id",
			edit: func(t *testing.T, project string) { setV062MetadataField(t, project, "project_id", "not-a-uuid") },
		},
		{
			name: "server port below range",
			edit: func(t *testing.T, project string) { setV062MetadataField(t, project, "dolt_server_port", 0) },
		},
		{
			name: "server port above range",
			edit: func(t *testing.T, project string) { setV062MetadataField(t, project, "dolt_server_port", 70000) },
		},
		{
			name: "non-empty custom data dir",
			edit: func(t *testing.T, project string) { setV062MetadataField(t, project, "dolt_data_dir", "/srv/dolt") },
		},
		{
			name: "unknown metadata field",
			edit: func(t *testing.T, project string) { setV062MetadataField(t, project, "shared_server", "true") },
		},
		{
			name: "duplicate metadata key",
			edit: func(t *testing.T, project string) {
				mustWrite(t, filepath.Join(project, ".beads", "metadata.json"),
					`{"backend":"dolt","backend":"dolt","database":"dolt","dolt_mode":"server","dolt_database":"smoke","project_id":"7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"}`)
			},
		},
		{
			name: "trailing content after object",
			edit: func(t *testing.T, project string) {
				mustWrite(t, filepath.Join(project, ".beads", "metadata.json"),
					`{"backend":"dolt","database":"dolt","dolt_mode":"server","dolt_database":"smoke","project_id":"7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"}{}`)
			},
		},
		{
			name: "not a json object",
			edit: func(t *testing.T, project string) {
				mustWrite(t, filepath.Join(project, ".beads", "metadata.json"), `["dolt"]`)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			project := newV062Project(t)
			tt.edit(t, project)
			before := snapshotTree(t, project)
			_, err := Inspect(project, "1.1.0")
			assertRefusalCode(t, err, CodeSourceMetadataMismatch)
			if after := snapshotTree(t, project); after != before {
				t.Fatalf("refusal mutated source tree")
			}
		})
	}
}

func TestInspectClassifiesStableOversizedWitnessesAsNonRetryableMismatch(t *testing.T) {
	tests := []struct {
		name    string
		path    string
		content string
		want    Code
	}{
		{
			name:    "version",
			path:    ".local_version",
			content: strings.Repeat("0", maxVersionBytes+1),
			want:    CodeSourceVersionMismatch,
		},
		{
			name:    "metadata",
			path:    "metadata.json",
			content: strings.Repeat("{", maxMetadataBytes+1),
			want:    CodeSourceMetadataMismatch,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			project := newV062Project(t)
			mustWrite(t, filepath.Join(project, ".beads", tt.path), tt.content)
			_, err := Inspect(project, "1.1.0")
			refusal, ok := AsRefusal(err)
			if !ok {
				t.Fatalf("Inspect() error = %T %v, want Refusal", err, err)
			}
			if refusal.Code != tt.want || refusal.Retryable || refusal.Effect != EffectNone {
				t.Fatalf("refusal = %#v, want code %q/nonretryable/effect none", refusal, tt.want)
			}
		})
	}
}

func TestWitnessReadFailureClassificationDistinguishesDriftFromUnverifiableIO(t *testing.T) {
	changed, ok := AsRefusal(classifyWitnessReadFailure(errWitnessChanged))
	if !ok || changed.Code != CodeSourceChanged || !changed.Retryable || changed.Effect != EffectNone {
		t.Fatalf("changed witness classified as %#v", changed)
	}
	unverifiable, ok := AsRefusal(classifyWitnessReadFailure(unix.EIO))
	if !ok || unverifiable.Code != CodeSourceUnverifiable || !unverifiable.Retryable || unverifiable.Effect != EffectNone {
		t.Fatalf("witness I/O failure classified as %#v", unverifiable)
	}
}

func TestInspectRequiresAbsoluteCanonicalProject(t *testing.T) {
	project := newV062Project(t)
	_, err := Inspect(project+string(os.PathSeparator)+".", "1.1.0")
	assertRefusalCode(t, err, CodeWorkspaceNotCanonical)

	_, err = Inspect("relative/project", "1.1.0")
	assertRefusalCode(t, err, CodeWorkspaceInvalid)
}

func TestInspectRefusesInjectedCrossDeviceObservation(t *testing.T) {
	err := checkDevice(2, 1)
	assertRefusalCode(t, err, CodeCrossDeviceSource)
}

func TestInspectRefusesDifferentNamedAndOpenedMountIdentityInsideTree(t *testing.T) {
	tests := []struct {
		name   string
		target func(int, string) bool
	}{
		{
			name: "named entry",
			target: func(dirfd int, path string) bool {
				return path == "repo_state.json" && descriptorPathHasSuffix(dirfd, "/dolt/smoke/.dolt")
			},
		},
		{
			name: "opened descriptor after safe named lookup",
			target: func(dirfd int, path string) bool {
				return path == "" && descriptorPathHasSuffix(dirfd, "/dolt/smoke/.dolt/repo_state.json")
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			project := newV062Project(t)
			injected := false
			_, err := inspectWithHooks(project, "1.1.0", inspectHooks{
				mountIDAt: func(dirfd int, path string, flags int) (uint64, error) {
					mountID, readErr := readMountIDAt(dirfd, path, flags)
					if readErr != nil {
						return 0, readErr
					}
					if tt.target(dirfd, path) {
						injected = true
						return mountID + 1, nil
					}
					return mountID, nil
				},
			})
			if !injected {
				t.Fatal("mount identity seam did not observe the nested Dolt witness")
			}
			assertRefusalCode(t, err, CodeCrossDeviceSource)
		})
	}
}

func TestInspectFailsClosedWhenMountIdentityCannotBeRead(t *testing.T) {
	project := newV062Project(t)
	injected := false
	_, err := inspectWithHooks(project, "1.1.0", inspectHooks{
		mountIDAt: func(dirfd int, path string, flags int) (uint64, error) {
			if path == "config.yaml" && descriptorPathHasSuffix(dirfd, "/.beads/dolt") {
				injected = true
				return 0, unix.ENOSYS
			}
			return readMountIDAt(dirfd, path, flags)
		},
	})
	if !injected {
		t.Fatal("mount identity seam did not observe the nested config")
	}
	refusal, ok := AsRefusal(err)
	if !ok || refusal.Code != CodeSourceUnverifiable || !refusal.Retryable || refusal.Effect != EffectNone {
		t.Fatalf("refusal = %#v (%v), want source_unverifiable/retryable/effect none", refusal, err)
	}
}

func TestProjectNoAtimePermissionFailureIsUnverifiableWithoutRetryOpen(t *testing.T) {
	for _, openErr := range []error{unix.EPERM, unix.EACCES} {
		attempts := 0
		_, _, _, err := openProjectWith("/absolute/project", readMountIDAt, func(_ string, flags int, _ uint32) (int, error) {
			attempts++
			if flags&unix.O_NOATIME == 0 {
				t.Fatalf("open flags %#x omitted O_NOATIME", flags)
			}
			return -1, openErr
		})
		if attempts != 1 {
			t.Fatalf("open attempts = %d, want exactly one O_NOATIME attempt", attempts)
		}
		refusal, ok := AsRefusal(err)
		if !ok || refusal.Code != CodeSourceUnverifiable || !refusal.Retryable || refusal.Effect != EffectNone {
			t.Fatalf("open error %v classified as %#v (%v)", openErr, refusal, err)
		}
	}
}

func TestAdmissionObservationsCompareBothStructureAndContent(t *testing.T) {
	first := treeSnapshot{treeSHA256: "first-content", structureSHA256: "same-structure"}
	second := treeSnapshot{treeSHA256: "second-content", structureSHA256: "same-structure"}
	if sameAdmissionObservation(first, second) {
		t.Fatal("equal structure with different content digest was accepted")
	}
	second.treeSHA256 = first.treeSHA256
	if !sameAdmissionObservation(first, second) {
		t.Fatal("identical admission observations were rejected")
	}
}

func TestInspectRefusesDeterministicRevalidationDrift(t *testing.T) {
	project := newV062Project(t)
	changed := filepath.Join(project, ".beads", "dolt", "smoke", ".dolt", "repo_state.json")
	result, err := inspectWithHooks(project, "1.1.0", inspectHooks{
		afterFirstTree: func() {
			if writeErr := os.WriteFile(changed, []byte("{\"head\":\"changed\"}\n"), 0o600); writeErr != nil {
				t.Fatalf("inject drift: %v", writeErr)
			}
		},
	})
	if result.Status != "" {
		t.Fatalf("drift returned result %#v", result)
	}
	assertRefusalCode(t, err, CodeSourceChanged)
}

func TestInspectReleasesDescriptorsOnSuccessAndRefusal(t *testing.T) {
	project := newV062Project(t)
	before := openDescriptorCount(t)
	for range 20 {
		if _, err := Inspect(project, "1.1.0"); err != nil {
			t.Fatalf("qualified Inspect() error = %v", err)
		}
	}
	mustWrite(t, filepath.Join(project, ".beads", ".local_version"), "0.61.0\n")
	for range 20 {
		_, err := Inspect(project, "1.1.0")
		assertRefusalCode(t, err, CodeSourceVersionMismatch)
	}
	if after := openDescriptorCount(t); after != before {
		t.Fatalf("descriptor count changed from %d to %d", before, after)
	}
}

func TestWSLReleaseDetection(t *testing.T) {
	for _, release := range []string{"5.15.90.1-microsoft-standard-WSL2", "4.4.0-Microsoft", "6.1.0-wsl"} {
		if !isWSLRelease(release) {
			t.Errorf("isWSLRelease(%q) = false", release)
		}
	}
	if isWSLRelease("6.8.0-1018-azure") {
		t.Fatal("native Linux release classified as WSL")
	}
}

func assertRefusalCode(t *testing.T, err error, want Code) {
	t.Helper()
	refusal, ok := AsRefusal(err)
	if !ok {
		t.Fatalf("error %T %v is not a Refusal", err, err)
	}
	if refusal.Code != want || refusal.Effect != EffectNone {
		t.Fatalf("refusal = %#v, want code %q/effect none", refusal, want)
	}
}

func newV062Project(t *testing.T) string {
	t.Helper()
	project := filepath.Join(t.TempDir(), "project")
	for _, dir := range []string{
		filepath.Join(project, ".beads", "dolt", ".dolt"),
		filepath.Join(project, ".beads", "dolt", "smoke", ".dolt"),
	} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	mustWrite(t, filepath.Join(project, ".beads", ".local_version"), "0.62.0\n")
	mustWrite(t, filepath.Join(project, ".beads", "metadata.json"), `{
  "database": "dolt",
  "backend": "dolt",
  "dolt_mode": "server",
  "dolt_server_host": "127.0.0.1",
  "dolt_server_port": 3307,
  "dolt_database": "smoke",
  "project_id": "7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"
}
`)
	mustWrite(t, filepath.Join(project, ".beads", "dolt", "config.yaml"), "listener:\n  host: 127.0.0.1\n  port: 3307\n")
	mustWrite(t, filepath.Join(project, ".beads", "dolt", ".dolt", "config.json"), "{}\n")
	mustWrite(t, filepath.Join(project, ".beads", "dolt", ".dolt", "repo_state.json"), "{\"head\":\"refs/heads/main\"}\n")
	mustWrite(t, filepath.Join(project, ".beads", "dolt", "smoke", ".dolt", "config.json"), "{}\n")
	mustWrite(t, filepath.Join(project, ".beads", "dolt", "smoke", ".dolt", "repo_state.json"), "{\"head\":\"refs/heads/main\"}\n")
	return project
}

func mustWrite(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func setV062MetadataField(t *testing.T, project, key string, fieldValue any) {
	t.Helper()
	metadata := filepath.Join(project, ".beads", "metadata.json")
	var value map[string]any
	data, err := os.ReadFile(metadata)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &value); err != nil {
		t.Fatal(err)
	}
	value[key] = fieldValue
	updated, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(metadata, updated, 0o600); err != nil {
		t.Fatal(err)
	}
}

func snapshotTree(t *testing.T, root string) string {
	t.Helper()
	var records []string
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		record := rel + "|" + info.Mode().String() + "|" + info.ModTime().UTC().String()
		if info.Mode().IsRegular() {
			stat, ok := info.Sys().(*syscall.Stat_t)
			if !ok {
				return errors.New("file stat is not syscall.Stat_t")
			}
			record += "|atime=" + strconv.FormatInt(stat.Atim.Sec, 10) + "." + strconv.FormatInt(stat.Atim.Nsec, 10)
			fd, err := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NOATIME, 0)
			if err != nil {
				return err
			}
			file := os.NewFile(uintptr(fd), path)
			if file == nil {
				_ = unix.Close(fd)
				return errors.New("could not wrap snapshot descriptor")
			}
			data, readErr := io.ReadAll(file)
			closeErr := file.Close()
			if readErr != nil {
				return readErr
			}
			if closeErr != nil {
				return closeErr
			}
			record += "|" + string(data)
		} else if info.Mode()&os.ModeSymlink != 0 {
			target, err := os.Readlink(path)
			if err != nil {
				return err
			}
			record += "|" + target
		}
		records = append(records, record)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(records)
	return strings.Join(records, "\n")
}

func openDescriptorCount(t *testing.T) int {
	t.Helper()
	entries, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		t.Fatal(err)
	}
	return len(entries)
}

func descriptorPathHasSuffix(fd int, suffix string) bool {
	path, err := os.Readlink("/proc/self/fd/" + strconv.Itoa(fd))
	return err == nil && strings.HasSuffix(path, suffix)
}
