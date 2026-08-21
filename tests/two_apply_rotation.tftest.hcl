# The "at most two applies" requirement, end to end.
#
# A full credential rotation is deliberately two phases:
#   apply 1: rotate the backup password. The active password stays valid.
#   apply 2: swap. The new password becomes active, the old one stays accepted.
#
# No phase invalidates a password that consumers still use.

run "day_zero" {
  command = apply

  variables {
    control = {
      active_slot = "a"
      generations = { a = 1, b = 1 }
    }
  }
}

run "apply_one_rotate_backup" {
  command = apply

  variables {
    control = {
      active_slot = "a"
      generations = { a = 1, b = 2 }
    }
  }

  assert {
    condition     = output.fingerprints[output.active_slot] == run.day_zero.fingerprints["a"]
    error_message = "Phase one must keep the active password in place."
  }
}

run "apply_two_swap" {
  command = apply

  variables {
    control = {
      active_slot = "b"
      generations = { a = 1, b = 2 }
    }
  }

  assert {
    condition     = output.fingerprints[output.active_slot] == run.apply_one_rotate_backup.fingerprints["b"]
    error_message = "Phase two must promote the password created in phase one."
  }

  assert {
    condition     = output.fingerprints[output.backup_slot] == run.day_zero.fingerprints["a"]
    error_message = "The password from before the rotation must remain the backup."
  }

  assert {
    condition     = output.generations == tomap({ a = 1, b = 2 })
    error_message = "Two applies must be enough to reach the desired state."
  }
}
