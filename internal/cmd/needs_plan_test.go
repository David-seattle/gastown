package cmd

import "testing"

func TestNeedsPlan(t *testing.T) {
	tests := []struct {
		issueType string
		want      bool
	}{
		{"feature", true},
		{"bug", true},
		{"task", true},
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
