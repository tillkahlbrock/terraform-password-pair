package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// ErrPendingChange reports that the working directory already holds a change
// that no apply has consumed yet.
var ErrPendingChange = errors.New("a change is already pending")

// lock takes an exclusive lock on the working directory. Two invocations of
// pwctl can therefore never edit the control record at the same time.
func lock(directory string) (release func(), err error) {
	path := filepath.Join(directory, lockFileName)

	handle, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		if errors.Is(err, os.ErrExist) {
			return nil, fmt.Errorf("another pwctl run holds %s; remove the file if no run is active", path)
		}
		return nil, err
	}

	fmt.Fprintf(handle, "%d\n", os.Getpid())
	handle.Close()

	return func() { os.Remove(path) }, nil
}

// requireCleanPlan refuses an operation while an earlier one waits for an
// apply. Rotation and swap can therefore never land in the same apply.
//
// Terraform cannot enforce this on its own. During a plan, the configuration
// has no access to the values of the previous state, so it cannot see that the
// other operation is already queued. The rule has to live outside Terraform.
func requireCleanPlan(binary, directory string) error {
	command := exec.Command(binary, "-chdir="+directory, "plan", "-detailed-exitcode", "-input=false", "-lock-timeout=60s")
	output, err := command.CombinedOutput()

	var exitError *exec.ExitError
	switch {
	case err == nil:
		return nil // Exit code 0: the working directory is in sync.
	case errors.As(err, &exitError) && exitError.ExitCode() == 2:
		return ErrPendingChange
	case errors.As(err, &exitError):
		return fmt.Errorf("%s plan failed:\n%s", binary, output)
	default:
		return fmt.Errorf("run %s: %w", binary, err)
	}
}
