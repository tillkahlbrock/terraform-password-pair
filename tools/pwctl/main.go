// Command pwctl owns the rotation control record of the password-pair Terraform
// module. It is the external half of the design: it decides which operation may
// run, and it never touches a password.
//
//	pwctl status   show the current record
//	pwctl rotate   replace the backup password on the next apply
//	pwctl swap     exchange the roles on the next apply
//
// A command is one operation. Rotation and swap cannot be combined, cannot run
// at the same time, and cannot stack into one apply.
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

const (
	defaultControlFile = "passwords.auto.tfvars.json"
	defaultVariable    = "control"
	lockFileName       = ".pwctl.lock"
)

const exitRefused = 3

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "pwctl: %v\n", err)
		if errors.Is(err, ErrPendingChange) {
			os.Exit(exitRefused)
		}
		os.Exit(1)
	}
}

func run(arguments []string) error {
	if len(arguments) == 0 {
		usage()
		return errors.New("no command given")
	}

	command := arguments[0]
	if command == "help" || command == "-h" || command == "--help" {
		usage()
		return nil
	}

	flags := flag.NewFlagSet(command, flag.ExitOnError)
	directory := flags.String("dir", ".", "Terraform working directory")
	name := flags.String("file", defaultControlFile, "control file, relative to -dir")
	variable := flags.String("var", defaultVariable, "name of the Terraform variable in the control file")
	binary := flags.String("terraform", "terraform", "Terraform binary; use tofu for OpenTofu")
	skipPlanCheck := flags.Bool("skip-plan-check", false, "skip the pending-change guard (for a first apply or a broken state)")
	dryRun := flags.Bool("dry-run", false, "print the new record, write nothing")
	if err := flags.Parse(arguments[1:]); err != nil {
		return err
	}

	path := filepath.Join(*directory, *name)

	document, record, err := Load(path, *variable)
	if err != nil {
		return err
	}

	if command == "status" {
		fmt.Println(record)
		return nil
	}

	var operation func(Record) Record
	switch command {
	case "rotate":
		operation = Record.Rotate
	case "swap":
		operation = Record.Swap
	default:
		usage()
		return fmt.Errorf("unknown command %q", command)
	}

	next := operation(record)

	if *dryRun {
		fmt.Printf("current: %s\nnext:    %s\n", record, next)
		return nil
	}

	release, err := lock(*directory)
	if err != nil {
		return err
	}
	defer release()

	if *skipPlanCheck {
		fmt.Fprintln(os.Stderr, "pwctl: warning: the pending-change guard is off")
	} else if err := requireCleanPlan(*binary, *directory); err != nil {
		if errors.Is(err, ErrPendingChange) {
			return fmt.Errorf("%w in %s; run terraform apply before the next %s", err, *directory, command)
		}
		return err
	}

	if err := document.Write(next); err != nil {
		return err
	}

	fmt.Printf("%s\n", command)
	fmt.Printf("  before: %s\n", record)
	fmt.Printf("  after:  %s\n", next)
	fmt.Printf("  file:   %s\n", path)
	fmt.Printf("\nRun: terraform -chdir=%s apply\n", *directory)

	return nil
}

func usage() {
	fmt.Fprint(os.Stderr, `pwctl owns the rotation control record of the password-pair module.

Usage:
  pwctl status [flags]
  pwctl rotate [flags]
  pwctl swap   [flags]

Commands:
  status   print the current record
  rotate   raise the generation of the backup slot; the next apply replaces that password
  swap     exchange the roles of the two slots; the next apply replaces no password

Flags:
  -dir string               Terraform working directory (default ".")
  -file string              control file, relative to -dir (default "passwords.auto.tfvars.json")
  -var string               name of the Terraform variable in the control file (default "control")
  -terraform string         Terraform binary; use tofu for OpenTofu (default "terraform")
  -skip-plan-check          skip the pending-change guard
  -dry-run                  print the new record, write nothing

Exit codes:
  0   done
  1   error
  3   refused, because a change is still waiting for an apply
`)
}
