# Requirement 4: a run without an external trigger changes nothing.
#
# The fingerprint of a slot is stable for as long as its password is stable.
# Equal fingerprints across two applies prove that no password was replaced.

variables {
  control = {
    active_slot = "a"
    generations = { a = 1, b = 1 }
  }
}

run "first_apply" {
  command = apply
}

run "second_apply_is_a_no_op" {
  command = apply

  assert {
    condition     = output.fingerprints["a"] == run.first_apply.fingerprints["a"]
    error_message = "A repeated apply must not replace the active password."
  }

  assert {
    condition     = output.fingerprints["b"] == run.first_apply.fingerprints["b"]
    error_message = "A repeated apply must not replace the backup password."
  }
}

run "third_apply_is_a_no_op" {
  command = apply

  assert {
    condition = (
      output.fingerprints["a"] == run.first_apply.fingerprints["a"] &&
      output.fingerprints["b"] == run.first_apply.fingerprints["b"]
    )
    error_message = "Idempotence must hold for every further apply."
  }
}
