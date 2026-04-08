package cmd

import (
	"fmt"
	"os/exec"
	"strings"
)

// wsListRequirementsFn shells out to `ws list <beadID> r` and returns the output.
// Replaceable for testing.
var wsListRequirementsFn = wsListRequirements

func wsListRequirements(beadID string) (string, error) {
	cmd := exec.Command("ws", "list", beadID, "r")
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// requiresWorkspaceDocs returns true for bead types that need requirement
// documents (acceptance-criteria, functional, technical-design) before slinging.
// Bugs, features, and tasks require workspace docs — any work that modifies
// version-controlled files needs acceptance criteria. Chores, epics, and
// other types are either operational work or containers that don't need them.
func requiresWorkspaceDocs(issueType string) bool {
	switch issueType {
	case "bug", "feature", "task":
		return true
	default:
		return false
	}
}

// checkWorkspaceRequirements verifies that a bead has at minimum an
// acceptance-criteria document in the workspace before allowing sling.
// Only enforced for bugs and features — other types skip the check.
// If `ws` is not installed or fails, the check is skipped gracefully
// so that environments without the workspace tool are not blocked.
func checkWorkspaceRequirements(beadID, issueType string) error {
	if !requiresWorkspaceDocs(issueType) {
		return nil
	}

	output, err := wsListRequirementsFn(beadID)
	if err != nil {
		// ws not available or bead not found in workspace — skip check
		return nil
	}

	for _, line := range strings.Split(output, "\n") {
		if strings.Contains(line, "acceptance-criteria") {
			return nil
		}
	}

	return fmt.Errorf("bead %s has no acceptance-criteria in the workspace\n"+
		"Every bead needs acceptance-criteria before it can be slung.\n"+
		"  1. Create the doc:   ws new %s r acceptance-criteria\n"+
		"  2. Fill it in:       ws edit %s acceptance-criteria --old \"...\" --new \"...\"\n"+
		"  3. Then sling again: gt sling %s <rig>", beadID, beadID, beadID, beadID)
}
