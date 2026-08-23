locals {
  slots = ["a", "b"]

  active_slot = var.control.active_slot
  backup_slot = one([for slot in local.slots : slot if slot != local.active_slot])
}

# Both slots are peers. Neither resource knows whether it is active.
# The role of a slot lives in the outputs, not in the resource.
resource "random_password" "slot" {
  for_each = toset(local.slots)

  length           = var.password_spec.length
  upper            = var.password_spec.upper
  lower            = var.password_spec.lower
  numeric          = var.password_spec.numeric
  special          = var.password_spec.special
  min_upper        = var.password_spec.min_upper
  min_lower        = var.password_spec.min_lower
  min_numeric      = var.password_spec.min_numeric
  min_special      = var.password_spec.min_special
  override_special = var.password_spec.override_special

  keepers = {
    # This is the only trigger for a new password. The value is a pure
    # function of the input, so an unchanged input produces an empty plan.
    generation = tostring(var.control.generations[each.key])
  }
}

locals {
  # One fingerprint per slot, so the outputs can report a password without
  # exposing it. Salted with the slot name and the generation.
  fingerprints = {
    for slot, password in random_password.slot :
    slot => substr(
      sha256("${slot}:${var.control.generations[slot]}:${nonsensitive(password.result)}"),
      0,
      16
    )
  }
}
