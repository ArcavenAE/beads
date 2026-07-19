package main

import (
	"github.com/spf13/cobra"
	"github.com/steveyegge/beads/internal/v062migration"
)

// newMigrationV062InspectCmd builds the private, read-only protocol endpoint
// used by scripts/migrate-v062-server-to-current.sh. It deliberately owns
// no product-facing command surface. Its supported argv grammar begins with
// the hidden command token; root flags placed before that token are outside the
// protocol because the public bridge never emits them.
func newMigrationV062InspectCmd() *cobra.Command {
	var workspace string
	emitUsageError := func() error {
		if err := outputJSONRaw(v062migration.UsageErrorResult()); err != nil {
			return err
		}
		return &exitError{Code: 2}
	}
	cmd := &cobra.Command{
		Use:           "__migration-v062-inspect",
		Hidden:        true,
		SilenceUsage:  true,
		SilenceErrors: true,
		Args: func(_ *cobra.Command, args []string) error {
			if len(args) != 0 {
				return emitUsageError()
			}
			return nil
		},

		// The root lifecycle discovers ambient workspaces, loads configuration,
		// and initializes metrics before its normal no-store classification.
		// Suppress it so the descriptor-relative inspector is the only code that
		// observes the explicitly named source. main.go carries matching early
		// bypasses as defense in depth if Cobra traversal semantics ever change.
		PersistentPreRunE: func(*cobra.Command, []string) error {
			if workspace == "" {
				return emitUsageError()
			}
			return nil
		},
		PersistentPostRunE: func(*cobra.Command, []string) error { return nil },

		RunE: func(*cobra.Command, []string) error {
			result, err := v062migration.Inspect(workspace, Version)
			if err == nil {
				return outputJSONRaw(result)
			}

			refusal, ok := v062migration.AsRefusal(err)
			if !ok {
				refusal = &v062migration.Refusal{
					Code:      v062migration.CodeSourceUnverifiable,
					Retryable: true,
					Effect:    v062migration.EffectNone,
				}
			}
			if err := outputJSONRaw(v062migration.RefusedResult(refusal.Code, refusal.Retryable)); err != nil {
				return err
			}
			return SilentExit()
		},
	}
	cmd.Flags().StringVar(&workspace, "workspace", "", "absolute canonical project path")
	cmd.SetFlagErrorFunc(func(*cobra.Command, error) error {
		return emitUsageError()
	})
	return cmd
}

var migrationV062InspectCmd = newMigrationV062InspectCmd()

func init() {
	rootCmd.AddCommand(migrationV062InspectCmd)
}
