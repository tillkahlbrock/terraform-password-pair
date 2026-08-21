package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

// slots are the two peer positions of the module. Neither name means "active".
var slots = []string{"a", "b"}

// Record is the rotation control record. It is the single input that decides
// which password is active and which generation each slot holds.
type Record struct {
	ActiveSlot  string         `json:"active_slot"`
	Generations map[string]int `json:"generations"`
}

// Document is a Terraform variable file. It keeps every variable it did not
// come for, so a shared tfvars file survives a write.
type Document struct {
	path      string
	variable  string
	variables map[string]json.RawMessage
}

// Load reads a variable file and returns the document and the control record.
func Load(path, variable string) (*Document, Record, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, Record{}, fmt.Errorf("read %s: %w", path, err)
	}

	document := &Document{path: path, variable: variable}
	if err := json.Unmarshal(raw, &document.variables); err != nil {
		return nil, Record{}, fmt.Errorf("parse %s: %w", path, err)
	}

	encoded, found := document.variables[variable]
	if !found {
		return nil, Record{}, fmt.Errorf("%s holds no variable %q", path, variable)
	}

	var record Record
	if err := json.Unmarshal(encoded, &record); err != nil {
		return nil, Record{}, fmt.Errorf("parse variable %q in %s: %w", variable, path, err)
	}

	if err := record.Validate(); err != nil {
		return nil, Record{}, fmt.Errorf("%s: %w", path, err)
	}

	return document, record, nil
}

// Write puts the record back and replaces the file in one atomic step.
func (d *Document) Write(record Record) error {
	if err := record.Validate(); err != nil {
		return err
	}

	encoded, err := json.Marshal(record)
	if err != nil {
		return err
	}
	d.variables[d.variable] = encoded

	body, err := json.MarshalIndent(d.variables, "", "  ")
	if err != nil {
		return err
	}
	body = append(body, '\n')

	temporary, err := os.CreateTemp(filepath.Dir(d.path), ".pwctl-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(temporary.Name())

	if _, err := temporary.Write(body); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Chmod(temporary.Name(), 0o644); err != nil {
		return err
	}

	// A rename is atomic, so a reader never sees half a control record.
	return os.Rename(temporary.Name(), d.path)
}

// Validate mirrors the variable validation of the Terraform module. The tool
// refuses to write a record that Terraform would reject.
func (r Record) Validate() error {
	if !contains(slots, r.ActiveSlot) {
		return fmt.Errorf("active_slot is %q, but must be one of %v", r.ActiveSlot, slots)
	}

	if len(r.Generations) != len(slots) {
		return fmt.Errorf("generations holds %d slots, but must hold %d", len(r.Generations), len(slots))
	}

	for _, slot := range slots {
		generation, found := r.Generations[slot]
		if !found {
			return fmt.Errorf("generations has no counter for slot %q", slot)
		}
		if generation < 1 {
			return fmt.Errorf("generation of slot %q is %d, but must be 1 or more", slot, generation)
		}
	}

	return nil
}

// BackupSlot returns the slot that is not active.
func (r Record) BackupSlot() string {
	for _, slot := range slots {
		if slot != r.ActiveSlot {
			return slot
		}
	}
	return ""
}

// Rotate returns a copy with a new generation on the backup slot. The active
// slot keeps its generation, so its password stays in place.
func (r Record) Rotate() Record {
	next := r.clone()
	next.Generations[r.BackupSlot()]++
	return next
}

// Swap returns a copy with the roles exchanged. No generation changes, so no
// password changes.
func (r Record) Swap() Record {
	next := r.clone()
	next.ActiveSlot = r.BackupSlot()
	return next
}

// String renders the record for a terminal. It prints no secret, because the
// tool never reads one.
func (r Record) String() string {
	names := make([]string, 0, len(r.Generations))
	for slot := range r.Generations {
		names = append(names, slot)
	}
	sort.Strings(names)

	line := fmt.Sprintf("active slot %q, backup slot %q, generations", r.ActiveSlot, r.BackupSlot())
	for _, slot := range names {
		line += fmt.Sprintf(" %s=%d", slot, r.Generations[slot])
	}
	return line
}

func (r Record) clone() Record {
	generations := make(map[string]int, len(r.Generations))
	for slot, generation := range r.Generations {
		generations[slot] = generation
	}
	return Record{ActiveSlot: r.ActiveSlot, Generations: generations}
}

func contains(values []string, wanted string) bool {
	for _, value := range values {
		if value == wanted {
			return true
		}
	}
	return false
}
