package cmd

import (
	"os"
	"strings"
	"testing"
)

func TestCheckWorkspaceRequirements(t *testing.T) {
	tests := []struct {
		name      string
		beadID    string
		issueType string
		wsOutput  string
		wsErr     error
		wantErr   bool
		errSubstr string
	}{
		{
			name:      "bug with acceptance-criteria",
			beadID:    "gt-abc",
			issueType: "bug",
			wsOutput: `r  acceptance-criteria   (draft)
r  functional            (no status)
r  technical-design      (no status)`,
			wantErr: false,
		},
		{
			name:      "feature with acceptance-criteria approved",
			beadID:    "gt-abc",
			issueType: "feature",
			wsOutput: `r  acceptance-criteria   (approved)
r  functional            (approved)`,
			wantErr: false,
		},
		{
			name:      "bug missing acceptance-criteria",
			beadID:    "gt-abc",
			issueType: "bug",
			wsOutput:  `r  functional            (draft)`,
			wantErr:   true,
			errSubstr: "acceptance-criteria",
		},
		{
			name:      "feature no requirements at all",
			beadID:    "gt-abc",
			issueType: "feature",
			wsOutput:  "",
			wantErr:   true,
			errSubstr: "acceptance-criteria",
		},
		{
			name:      "ws command fails - skip check gracefully",
			beadID:    "gt-abc",
			issueType: "bug",
			wsOutput:  "",
			wsErr:     &testWsError{msg: "ws not found"},
			wantErr:   false,
		},
		{
			name:      "task with acceptance-criteria",
			beadID:    "gt-abc",
			issueType: "task",
			wsOutput: `r  acceptance-criteria   (draft)
r  functional            (no status)`,
			wantErr: false,
		},
		{
			name:      "task missing acceptance-criteria",
			beadID:    "gt-abc",
			issueType: "task",
			wsOutput:  "",
			wantErr:   true,
			errSubstr: "acceptance-criteria",
		},
		{
			name:      "chore skips requirement check",
			beadID:    "gt-abc",
			issueType: "chore",
			wsOutput:  "",
			wantErr:   false,
		},
		{
			name:      "epic skips requirement check",
			beadID:    "gt-abc",
			issueType: "epic",
			wsOutput:  "",
			wantErr:   false,
		},
		{
			name:      "empty type skips requirement check",
			beadID:    "gt-abc",
			issueType: "",
			wsOutput:  "",
			wantErr:   false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			prev := wsListRequirementsFn
			t.Cleanup(func() { wsListRequirementsFn = prev })

			wsListRequirementsFn = func(beadID string) (string, error) {
				if tt.wsErr != nil {
					return "", tt.wsErr
				}
				return tt.wsOutput, nil
			}

			err := checkWorkspaceRequirements(tt.beadID, tt.issueType)
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				if tt.errSubstr != "" && !strings.Contains(err.Error(), tt.errSubstr) {
					t.Errorf("error %q should contain %q", err.Error(), tt.errSubstr)
				}
			} else {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
			}
		})
	}
}

// TestRequirementsNotBypassedByForce is a regression test ensuring that
// workspace requirements for bugs/features cannot be bypassed by --force.
// The checkWorkspaceRequirements function intentionally has no force parameter.
// If someone adds one, this test must be updated — forcing a deliberate review.
func TestRequirementsNotBypassedByForce(t *testing.T) {
	prev := wsListRequirementsFn
	t.Cleanup(func() { wsListRequirementsFn = prev })

	// ws returns no acceptance-criteria
	wsListRequirementsFn = func(beadID string) (string, error) {
		return "", nil
	}

	// Bug without requirements: must error regardless of any external force flag
	err := checkWorkspaceRequirements("gt-abc", "bug")
	if err == nil {
		t.Fatal("bug without acceptance-criteria must be rejected — requirements are non-negotiable")
	}

	// Feature without requirements: same
	err = checkWorkspaceRequirements("gt-def", "feature")
	if err == nil {
		t.Fatal("feature without acceptance-criteria must be rejected — requirements are non-negotiable")
	}

	// Task without requirements: same
	err = checkWorkspaceRequirements("gt-ghi", "task")
	if err == nil {
		t.Fatal("task without acceptance-criteria must be rejected — requirements are non-negotiable")
	}
}

// TestCallSitesNotGuardedByForce scans sling.go and sling_dispatch.go to verify
// that checkWorkspaceRequirements calls are not wrapped in force-conditional blocks.
// This catches the regression where someone adds "if !force {" around the call.
func TestCallSitesNotGuardedByForce(t *testing.T) {
	files := []string{"sling.go", "sling_dispatch.go", "sling_schedule.go"}
	for _, filename := range files {
		content, err := os.ReadFile(filename)
		if err != nil {
			t.Fatalf("reading %s: %v", filename, err)
		}

		lines := strings.Split(string(content), "\n")
		for i, line := range lines {
			if strings.Contains(line, "checkWorkspaceRequirements") && strings.Contains(line, "err") {
				// Check the 3 lines before the call for force guards
				for j := max(0, i-3); j < i; j++ {
					prev := strings.TrimSpace(lines[j])
					if strings.Contains(prev, "!force") || strings.Contains(prev, "!params.Force") ||
						strings.Contains(prev, "!slingForce") || strings.Contains(prev, "Force") && strings.Contains(prev, "if") {
						t.Errorf("%s:%d: checkWorkspaceRequirements is guarded by a force check at line %d: %q\n"+
							"Requirements for bugs/features must NOT be bypassed by --force", filename, i+1, j+1, prev)
					}
				}
			}
		}
	}
}

type testWsError struct {
	msg string
}

func (e *testWsError) Error() string { return e.msg }
