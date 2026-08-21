# Requirement 1: the first apply creates two passwords.

run "initial_create" {
  command = apply

  assert {
    condition     = output.active_slot == "a" && output.backup_slot == "b"
    error_message = "The default control record must make slot a active and slot b the backup."
  }

  assert {
    condition     = length(output.fingerprints) == 2
    error_message = "The module must create one password per slot."
  }

  assert {
    condition     = output.fingerprints["a"] != output.fingerprints["b"]
    error_message = "Each slot must hold its own password."
  }

  assert {
    condition     = output.generations == tomap({ a = 1, b = 1 })
    error_message = "The module must report the generation counter of each slot."
  }
}

run "custom_password_spec" {
  command = apply

  variables {
    password_spec = {
      length  = 48
      special = false

      min_special = 0
    }
  }

  assert {
    condition     = length(output.fingerprints) == 2
    error_message = "The module must accept a custom password shape."
  }
}
