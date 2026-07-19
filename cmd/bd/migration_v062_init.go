package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"

	"github.com/spf13/cobra"
	"github.com/steveyegge/beads/internal/beads"
	"github.com/steveyegge/beads/internal/configfile"
)

const migrationV062ProjectIDFlag = "migration-v062-project-id"
const migrationV062RepositoryRootFlag = "migration-v062-repository-root"

var migrationV062ProjectIDPattern = regexp.MustCompile(
	`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`,
)

// migrationV062InitProjectID admits the authenticated historical project ID
// only on a fresh, explicitly selected embedded-Dolt initialization. Keeping
// this as a creation-time input lets normal init persist metadata.json and the
// database _project_id together; a post-init rewrite could strand them in a
// mismatched state after a crash.
func migrationV062InitProjectID(cmd *cobra.Command, admission initBackendAdmission) (string, error) {
	flags := cmd.Flags()
	if flags.Lookup(migrationV062ProjectIDFlag) == nil {
		return "", nil
	}
	projectID, err := flags.GetString(migrationV062ProjectIDFlag)
	if err != nil || projectID == "" {
		return "", err
	}
	refuse := func(reason string) (string, error) {
		return "", fmt.Errorf("--%s %s", migrationV062ProjectIDFlag, reason)
	}

	if !cmd.Flags().Changed("backend") || admission.backend != configfile.BackendDolt {
		return refuse("requires explicit --backend=dolt")
	}
	if !migrationV062ProjectIDPattern.MatchString(projectID) {
		return refuse("requires a canonical UUID")
	}
	if admission.initialized {
		return refuse("requires a fresh, uninitialized target")
	}

	for _, flag := range []string{
		"force", "reinit-local", "discard-remote", "from-jsonl", "init-if-missing",
		"remote", "server", "shared-server", "external", "proxied-server",
		"server-host", "server-port", "server-socket", "server-user",
	} {
		if cmd.Flags().Changed(flag) {
			return refuse("cannot be combined with --" + flag)
		}
	}
	proxied, _ := cmd.Flags().GetBool("proxied-server")
	shared, _ := cmd.Flags().GetBool("shared-server")
	server, _ := cmd.Flags().GetBool("server")
	if mode := resolveInitDoltMode(proxied, shared, server); mode != "embedded" {
		return refuse("requires embedded Dolt mode")
	}

	return projectID, nil
}

// migrationV062InitRepositoryRoot admits the final physical Git workspace whose
// tracking identity must be persisted into a side-by-side migration target.
// The target itself is initialized under a temporary staging path, so deriving
// repo_id and clone_id from its current working directory would publish the
// staging repository's identity after the .beads directory is moved.
func migrationV062InitRepositoryRoot(cmd *cobra.Command, projectID string) (string, error) {
	flags := cmd.Flags()
	if flags.Lookup(migrationV062RepositoryRootFlag) == nil {
		return "", nil
	}
	if !flags.Changed(migrationV062RepositoryRootFlag) {
		return "", nil
	}
	root, err := flags.GetString(migrationV062RepositoryRootFlag)
	if err != nil {
		return "", err
	}
	refuse := func(reason string) (string, error) {
		return "", fmt.Errorf("--%s %s", migrationV062RepositoryRootFlag, reason)
	}
	if projectID == "" {
		return refuse("requires --" + migrationV062ProjectIDFlag)
	}
	if root == "" || !filepath.IsAbs(root) {
		return refuse("requires an absolute physical Git workspace")
	}
	physical, err := filepath.EvalSymlinks(root)
	if err != nil || physical != filepath.Clean(root) {
		return refuse("requires an existing canonical physical Git workspace")
	}
	info, err := os.Stat(physical)
	if err != nil || !info.IsDir() {
		return refuse("requires an existing canonical physical Git workspace")
	}
	if _, err := beads.ComputeRepoIDForPath(physical); err != nil {
		return refuse("requires an existing canonical physical Git workspace")
	}
	if _, err := beads.GetCloneIDForPath(physical); err != nil {
		return refuse("requires an existing canonical physical Git workspace")
	}
	return physical, nil
}
