package cmd

import "testing"

func TestNeedsPlan(t *testing.T) {
	// Plan pre-generation is temporarily disabled (see needsPlan): the deferred
	// agent session interacts badly with the dispatch/recover/startup-nudge path.
	// All bead types currently return false until the deferred-session path is fixed.
	tests := []struct {
		issueType string
		want      bool
	}{
		{"feature", false},
		{"bug", false},
		{"task", false},
		{"chore", false},
		{"epic", false},
		{"decision", false},
		{"", false},
		{"unknown", false},
	}
	for _, tt := range tests {
		t.Run(tt.issueType, func(t *testing.T) {
			if got := needsPlan(tt.issueType); got != tt.want {
				t.Errorf("needsPlan(%q) = %v, want %v", tt.issueType, got, tt.want)
			}
		})
	}
}
