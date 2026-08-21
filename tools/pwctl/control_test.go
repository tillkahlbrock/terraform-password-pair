package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func record() Record {
	return Record{ActiveSlot: "a", Generations: map[string]int{"a": 1, "b": 1}}
}

func TestRotateRaisesTheBackupGenerationOnly(t *testing.T) {
	before := record()
	after := before.Rotate()

	if after.Generations["b"] != 2 {
		t.Errorf("backup generation is %d, want 2", after.Generations["b"])
	}
	if after.Generations["a"] != 1 {
		t.Errorf("active generation is %d, want 1", after.Generations["a"])
	}
	if after.ActiveSlot != "a" {
		t.Errorf("active slot is %q, want \"a\"", after.ActiveSlot)
	}
	if before.Generations["b"] != 1 {
		t.Error("Rotate changed the receiver")
	}
}

func TestRotateFollowsTheActiveSlot(t *testing.T) {
	swapped := record().Swap()
	after := swapped.Rotate()

	if after.Generations["a"] != 2 {
		t.Errorf("generation of slot a is %d, want 2", after.Generations["a"])
	}
	if after.Generations["b"] != 1 {
		t.Errorf("rotation touched the active slot: %v", after.Generations)
	}
}

func TestSwapExchangesTheRolesAndKeepsEveryGeneration(t *testing.T) {
	before := record()
	after := before.Swap()

	if after.ActiveSlot != "b" || after.BackupSlot() != "a" {
		t.Errorf("roles are %q/%q, want \"b\"/\"a\"", after.ActiveSlot, after.BackupSlot())
	}
	if after.Generations["a"] != 1 || after.Generations["b"] != 1 {
		t.Errorf("swap changed a generation: %v", after.Generations)
	}
	if before.ActiveSlot != "a" {
		t.Error("Swap changed the receiver")
	}
}

func TestTwoSwapsReturnToTheStart(t *testing.T) {
	if got := record().Swap().Swap(); got.ActiveSlot != "a" {
		t.Errorf("active slot is %q, want \"a\"", got.ActiveSlot)
	}
}

func TestValidateRejectsABrokenRecord(t *testing.T) {
	cases := map[string]Record{
		"unknown slot":       {ActiveSlot: "c", Generations: map[string]int{"a": 1, "b": 1}},
		"missing counter":    {ActiveSlot: "a", Generations: map[string]int{"a": 1}},
		"extra counter":      {ActiveSlot: "a", Generations: map[string]int{"a": 1, "b": 1, "c": 1}},
		"generation is zero": {ActiveSlot: "a", Generations: map[string]int{"a": 0, "b": 1}},
	}

	for name, broken := range cases {
		t.Run(name, func(t *testing.T) {
			if err := broken.Validate(); err == nil {
				t.Error("Validate accepted a record that Terraform would reject")
			}
		})
	}
}

func TestValidateAcceptsAGoodRecord(t *testing.T) {
	if err := record().Validate(); err != nil {
		t.Errorf("Validate rejected a good record: %v", err)
	}
}

// A control file may hold other variables. A write must keep them.
func TestWriteKeepsEveryOtherVariable(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, defaultControlFile)

	original := `{
  "control": {
    "active_slot": "a",
    "generations": { "a": 1, "b": 1 }
  },
  "password_spec": { "length": 48 }
}`
	if err := os.WriteFile(path, []byte(original), 0o644); err != nil {
		t.Fatal(err)
	}

	document, loaded, err := Load(path, defaultVariable)
	if err != nil {
		t.Fatal(err)
	}
	if err := document.Write(loaded.Rotate()); err != nil {
		t.Fatal(err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	var written struct {
		Control      Record `json:"control"`
		PasswordSpec struct {
			Length int `json:"length"`
		} `json:"password_spec"`
	}
	if err := json.Unmarshal(raw, &written); err != nil {
		t.Fatal(err)
	}

	if written.PasswordSpec.Length != 48 {
		t.Errorf("password_spec is lost, length is %d", written.PasswordSpec.Length)
	}
	if written.Control.Generations["b"] != 2 {
		t.Errorf("backup generation is %d, want 2", written.Control.Generations["b"])
	}
}

func TestLoadReportsAMissingVariable(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, defaultControlFile)
	if err := os.WriteFile(path, []byte(`{"other": 1}`), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, _, err := Load(path, defaultVariable); err == nil {
		t.Error("Load accepted a file without the control variable")
	}
}

func TestLockIsExclusive(t *testing.T) {
	directory := t.TempDir()

	release, err := lock(directory)
	if err != nil {
		t.Fatal(err)
	}

	if _, err := lock(directory); err == nil {
		release()
		t.Fatal("a second lock succeeded")
	}

	release()

	release, err = lock(directory)
	if err != nil {
		t.Fatalf("the lock was not released: %v", err)
	}
	release()
}
