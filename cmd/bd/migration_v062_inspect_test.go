package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"

	"github.com/spf13/cobra"
	"github.com/steveyegge/beads/internal/v062migration"
)

func TestMigrationV062InspectRawEntrypointGrammar(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want bool
	}{
		{name: "no argv", args: nil, want: false},
		{name: "binary only", args: []string{"bd"}, want: false},
		{name: "exact token first", args: []string{"bd", "__migration-v062-inspect"}, want: true},
		{name: "root flag before token", args: []string{"bd", "--json", "__migration-v062-inspect"}, want: false},
		{name: "similar token", args: []string{"bd", "__migration-v062-inspect-extra"}, want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isMigrationV062InspectRawEntrypoint(tt.args); got != tt.want {
				t.Fatalf("isMigrationV062InspectRawEntrypoint(%q) = %v, want %v", tt.args, got, tt.want)
			}
		})
	}
}

func TestMigrationV062InspectRawEntrypointDoesNotInitializeAmbientConfig(t *testing.T) {
	bd := buildMigrationV062LifecycleBinary(t)
	fixture := newMigrationV062AmbientConfigFixture(t)
	missingWorkspace := filepath.Join(fixture.root, "missing-v062-workspace")

	t.Run("hidden token first ignores ambient config", func(t *testing.T) {
		stdout, stderr, err := runMigrationV062LifecycleProcess(
			t,
			bd,
			fixture.cwd,
			fixture.env,
			"__migration-v062-inspect",
			"--workspace", missingWorkspace,
		)
		if code := migrationV062ProcessExitCode(err); code != 1 {
			t.Fatalf("exit code = %d, want 1\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
		}
		if stderr != "" {
			t.Fatalf("private migration entrypoint observed ambient initialization:\n%s", stderr)
		}
		var result v062migration.Result
		if err := json.Unmarshal([]byte(stdout), &result); err != nil {
			t.Fatalf("decode protocol output: %v\nstdout: %s", err, stdout)
		}
		if result.Status != v062migration.StatusRefused || result.Effect != v062migration.EffectNone {
			t.Fatalf("unexpected refusal envelope: %#v", result)
		}
	})

	t.Run("normal command still initializes ambient config", func(t *testing.T) {
		stdout, stderr, err := runMigrationV062LifecycleProcess(t, bd, fixture.cwd, fixture.env, "version")
		if code := migrationV062ProcessExitCode(err); code != 0 {
			t.Fatalf("exit code = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
		}
		if !strings.Contains(stderr, "Warning: failed to initialize config:") {
			t.Fatalf("normal command did not observe hostile ambient config:\n%s", stderr)
		}
	})

	t.Run("hidden token not first still initializes ambient config", func(t *testing.T) {
		stdout, stderr, err := runMigrationV062LifecycleProcess(
			t,
			bd,
			fixture.cwd,
			fixture.env,
			"--json",
			"__migration-v062-inspect",
			"--workspace", missingWorkspace,
		)
		if code := migrationV062ProcessExitCode(err); code != 1 {
			t.Fatalf("exit code = %d, want 1\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
		}
		if !strings.Contains(stderr, "Warning: failed to initialize config:") {
			t.Fatalf("token-not-first invocation incorrectly bypassed ambient config:\n%s", stderr)
		}
	})
}

func TestMigrationV062InspectRawEntrypointDoesNotInvokeGitDuringInitialization(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fake executable probe uses a POSIX shell")
	}

	bd := buildMigrationV062LifecycleBinary(t)
	root := t.TempDir()
	cwd := filepath.Join(root, "caller")
	binDir := filepath.Join(root, "bin")
	marker := filepath.Join(root, "git-was-invoked")
	for _, dir := range []string{cwd, binDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", dir, err)
		}
	}
	gitProbe := filepath.Join(binDir, "git")
	if err := os.WriteFile(gitProbe, []byte("#!/bin/sh\n: > \"$BD_V062_GIT_PROBE\"\nexit 1\n"), 0o755); err != nil {
		t.Fatalf("write git probe: %v", err)
	}
	env := migrationV062LifecycleEnv(
		filepath.Join(root, "home"),
		filepath.Join(root, "xdg"),
		"PATH="+binDir,
		"BD_V062_GIT_PROBE="+marker,
	)

	stdout, stderr, err := runMigrationV062LifecycleProcess(
		t,
		bd,
		cwd,
		env,
		"__migration-v062-inspect",
		"--workspace", filepath.Join(root, "missing-v062-workspace"),
	)
	if code := migrationV062ProcessExitCode(err); code != 1 {
		t.Fatalf("exit code = %d, want 1\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("private migration entrypoint invoked ambient git probe: %v", err)
	}

	// Root help does not run Cobra's command lifecycle, so this marker can only
	// come from the eager configuration initialization performed by init().
	stdout, stderr, err = runMigrationV062LifecycleProcess(t, bd, cwd, env, "--help")
	if code := migrationV062ProcessExitCode(err); code != 0 {
		t.Fatalf("control exit code = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("control command did not invoke git during config initialization: %v", err)
	}
}

func TestMigrationV062InspectCommandBypassesParentLifecycle(t *testing.T) {
	t.Setenv("BD_BACKEND", "postgres")
	t.Setenv("BD_DATABASE_BACKEND", "mysql")

	parentPreRun := false
	parentPostRun := false
	root := &cobra.Command{
		Use: "bd",
		PersistentPreRunE: func(*cobra.Command, []string) error {
			parentPreRun = true
			return nil
		},
		PersistentPostRunE: func(*cobra.Command, []string) error {
			parentPostRun = true
			return nil
		},
	}
	command := newMigrationV062InspectCmd()
	root.AddCommand(command)
	root.SetArgs([]string{
		"__migration-v062-inspect",
		"--workspace", "/definitely/not/a/v062/workspace",
	})

	stdout, executeErr := captureMigrationV062Stdout(t, root.Execute)
	if code, ok := exitCodeFromError(executeErr); !ok || code != 1 {
		t.Fatalf("Execute() error = %T %v, want exit code 1", executeErr, executeErr)
	}
	if parentPreRun || parentPostRun {
		t.Fatalf("hidden protocol ran parent lifecycle: pre=%v post=%v", parentPreRun, parentPostRun)
	}
	if !command.Hidden {
		t.Fatal("migration inspection plumbing must remain hidden")
	}

	var result v062migration.Result
	if err := json.Unmarshal([]byte(stdout), &result); err != nil {
		t.Fatalf("decode protocol output: %v\nstdout: %s", err, stdout)
	}
	if result.SchemaVersion != v062migration.SchemaVersion ||
		result.Operation != v062migration.Operation ||
		result.Status != v062migration.StatusRefused ||
		result.Effect != v062migration.EffectNone ||
		result.Code == "" {
		t.Fatalf("unexpected refusal envelope: %#v", result)
	}
}

func TestMigrationV062InspectCommandUsageContract(t *testing.T) {
	tests := []struct {
		name string
		args []string
	}{
		{name: "missing workspace", args: nil},
		{name: "empty workspace", args: []string{"--workspace", ""}},
		{name: "unexpected argument", args: []string{"--workspace", "/tmp", "extra"}},
		{name: "unknown flag", args: []string{"--unknown"}},
		{name: "missing flag value", args: []string{"--workspace"}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			root := &cobra.Command{Use: "bd"}
			root.AddCommand(newMigrationV062InspectCmd())
			root.SetArgs(append([]string{"__migration-v062-inspect"}, tt.args...))

			stdout, executeErr := captureMigrationV062Stdout(t, root.Execute)
			if code, ok := exitCodeFromError(executeErr); !ok || code != 2 {
				t.Fatalf("Execute() error = %T %v, want exit code 2", executeErr, executeErr)
			}
			var result v062migration.Result
			if err := json.Unmarshal([]byte(stdout), &result); err != nil {
				t.Fatalf("decode protocol output: %v\nstdout: %s", err, stdout)
			}
			if result != v062migration.UsageErrorResult() {
				t.Fatalf("usage result = %#v, want %#v", result, v062migration.UsageErrorResult())
			}
		})
	}
}

func TestMigrationV062InspectCommandIsAbsentFromHelp(t *testing.T) {
	root := &cobra.Command{Use: "bd"}
	root.AddCommand(newMigrationV062InspectCmd())
	var output bytes.Buffer
	root.SetOut(&output)
	root.SetErr(&output)
	if err := root.Help(); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(output.String(), "__migration-v062-inspect") {
		t.Fatalf("hidden protocol leaked into help:\n%s", output.String())
	}
}

func captureMigrationV062Stdout(t *testing.T, fn func() error) (string, error) {
	t.Helper()

	stdioMutex.Lock()
	defer stdioMutex.Unlock()

	previous := os.Stdout
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = writer

	executeErr := fn()
	_ = writer.Close()
	os.Stdout = previous

	data, readErr := io.ReadAll(reader)
	_ = reader.Close()
	if readErr != nil {
		t.Fatal(readErr)
	}
	return string(data), executeErr
}

type migrationV062AmbientConfigFixture struct {
	root string
	cwd  string
	env  []string
}

func newMigrationV062AmbientConfigFixture(t *testing.T) migrationV062AmbientConfigFixture {
	t.Helper()

	root := t.TempDir()
	home := filepath.Join(root, "home")
	xdg := filepath.Join(root, "xdg")
	cwd := filepath.Join(root, "caller", "nested")
	configPaths := []string{
		filepath.Join(home, ".beads", "config.yaml"),
		filepath.Join(xdg, "bd", "config.yaml"),
		filepath.Join(root, "caller", ".beads", "config.yaml"),
	}
	if err := os.MkdirAll(cwd, 0o755); err != nil {
		t.Fatalf("mkdir caller: %v", err)
	}
	for _, path := range configPaths {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatalf("mkdir config parent: %v", err)
		}
		if err := os.WriteFile(path, []byte("json: [unterminated\n"), 0o600); err != nil {
			t.Fatalf("write hostile config: %v", err)
		}
	}

	return migrationV062AmbientConfigFixture{
		root: root,
		cwd:  cwd,
		env:  migrationV062LifecycleEnv(home, xdg),
	}
}

var (
	migrationV062LifecycleBuildOnce sync.Once
	migrationV062LifecycleBD        string
	migrationV062LifecycleBuildErr  string
)

func buildMigrationV062LifecycleBinary(t *testing.T) string {
	t.Helper()

	migrationV062LifecycleBuildOnce.Do(func() {
		packageDir, err := os.Getwd()
		if err != nil {
			migrationV062LifecycleBuildErr = "get package directory: " + err.Error()
			return
		}
		buildDir, err := testTempDir("bd-v062-lifecycle-*")
		if err != nil {
			migrationV062LifecycleBuildErr = "create build directory: " + err.Error()
			return
		}
		name := "bd"
		if runtime.GOOS == "windows" {
			name = "bd.exe"
		}
		migrationV062LifecycleBD = filepath.Join(buildDir, name)
		cmd := exec.Command("go", "build", "-tags", "gms_pure_go", "-o", migrationV062LifecycleBD, ".")
		cmd.Dir = packageDir
		if output, err := cmd.CombinedOutput(); err != nil {
			migrationV062LifecycleBuildErr = "build bd: " + err.Error() + "\n" + string(output)
		}
	})
	if migrationV062LifecycleBuildErr != "" {
		t.Fatal(migrationV062LifecycleBuildErr)
	}
	return migrationV062LifecycleBD
}

func migrationV062LifecycleEnv(home, xdg string, extra ...string) []string {
	blocked := map[string]bool{
		"HOME":                true,
		"USERPROFILE":         true,
		"XDG_CONFIG_HOME":     true,
		"GIT_CONFIG_GLOBAL":   true,
		"GIT_CONFIG_NOSYSTEM": true,
		"PATH":                true,
	}
	env := make([]string, 0, len(os.Environ())+len(extra)+9)
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		if blocked[name] || strings.HasPrefix(name, "BD_") || strings.HasPrefix(name, "BEADS_") {
			continue
		}
		env = append(env, entry)
	}
	env = append(env,
		"HOME="+home,
		"USERPROFILE="+home,
		"XDG_CONFIG_HOME="+xdg,
		"GIT_CONFIG_GLOBAL="+filepath.Join(home, "gitconfig"),
		"GIT_CONFIG_NOSYSTEM=1",
		"PATH="+os.Getenv("PATH"),
		"BEADS_DOLT_AUTO_START=0",
		"BEADS_NO_DAEMON=1",
		"BD_DISABLE_METRICS=1",
		"BD_DISABLE_EVENT_FLUSH=1",
	)
	return append(env, extra...)
}

func runMigrationV062LifecycleProcess(
	t *testing.T,
	bd string,
	dir string,
	env []string,
	args ...string,
) (stdout, stderr string, runErr error) {
	t.Helper()

	cmd := exec.Command(bd, args...)
	cmd.Dir = dir
	cmd.Env = env
	var stdoutBuffer bytes.Buffer
	var stderrBuffer bytes.Buffer
	cmd.Stdout = &stdoutBuffer
	cmd.Stderr = &stderrBuffer
	runErr = cmd.Run()
	return stdoutBuffer.String(), stderrBuffer.String(), runErr
}

func migrationV062ProcessExitCode(err error) int {
	if err == nil {
		return 0
	}
	if exitErr, ok := err.(*exec.ExitError); ok {
		return exitErr.ExitCode()
	}
	return -1
}
