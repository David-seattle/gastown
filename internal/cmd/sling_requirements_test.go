package cmd

import (
	"strings"
	"testing"
)

func TestCheckWorkspaceRequirements(t *testing.T) {
	tests := []struct {
		name      string
		beadID    string
		wsOutput  string
		wsErr     error
		wantErr   bool
		errSubstr string
	}{
		{
			name:   "has acceptance-criteria",
			beadID: "gt-abc",
			wsOutput: `r  acceptance-criteria   (draft)
r  functional            (no status)
r  technical-design      (no status)`,
			wantErr: false,
		},
		{
			name:   "has acceptance-criteria with approved status",
			beadID: "gt-abc",
			wsOutput: `r  acceptance-criteria   (approved)
r  functional            (approved)`,
			wantErr: false,
		},
		{
			name:      "missing acceptance-criteria",
			beadID:    "gt-abc",
			wsOutput:  `r  functional            (draft)`,
			wantErr:   true,
			errSubstr: "acceptance-criteria",
		},
		{
			name:      "no requirements at all",
			beadID:    "gt-abc",
			wsOutput:  "",
			wantErr:   true,
			errSubstr: "acceptance-criteria",
		},
		{
			name:     "ws command fails - skip check gracefully",
			beadID:   "gt-abc",
			wsOutput: "",
			wsErr:    &testWsError{msg: "ws not found"},
			wantErr:  false,
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

			err := checkWorkspaceRequirements(tt.beadID)
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

type testWsError struct {
	msg string
}

func (e *testWsError) Error() string { return e.msg }
