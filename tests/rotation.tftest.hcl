# Requirement 2: a rotation replaces the backup password and nothing else.

run "before_rotation" {
  command = apply

  variables {
    control = {
      active_slot = "a"
      generations = { a = 1, b = 1 }
    }
  }
}

run "after_rotation" {
  command = apply

  variables {
    control = {
      active_slot = "a"
      generations = { a = 1, b = 2 }
    }
  }

  assert {
    condition     = output.fingerprints["a"] == run.before_rotation.fingerprints["a"]
    error_message = "A rotation must never touch the active password."
  }

  assert {
    condition     = output.fingerprints["b"] != run.before_rotation.fingerprints["b"]
    error_message = "A rotation must replace the backup password."
  }

  assert {
    condition     = output.active_slot == "a" && output.backup_slot == "b"
    error_message = "A rotation must not change the role of a slot."
  }

  assert {
    condition     = output.generations["b"] == 2
    error_message = "The module must report the new generation of the rotated slot."
  }
}
