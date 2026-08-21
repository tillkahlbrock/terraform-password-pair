# Requirement 3: a swap exchanges the roles and keeps both passwords.

run "before_swap" {
  command = apply

  variables {
    control = {
      active_slot = "a"
      generations = { a = 1, b = 1 }
    }
  }
}

run "after_swap" {
  command = apply

  variables {
    control = {
      active_slot = "b"
      generations = { a = 1, b = 1 }
    }
  }

  assert {
    condition     = output.active_slot == "b" && output.backup_slot == "a"
    error_message = "A swap must exchange the roles of the two slots."
  }

  # Both fingerprints are unchanged, so the swap moved no secret material.
  # The former backup password is now the active password.
  assert {
    condition     = output.fingerprints["b"] == run.before_swap.fingerprints["b"]
    error_message = "The promoted password must be the same value as before the swap."
  }

  assert {
    condition     = output.fingerprints["a"] == run.before_swap.fingerprints["a"]
    error_message = "The demoted password must survive the swap."
  }
}
