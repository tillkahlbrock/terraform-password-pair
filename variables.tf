variable "control" {
  description = <<-EOT
    Rotation control record. The `pwctl` tool owns this value. Do not edit it by hand.

    - `active_slot`: the slot that currently holds the active password.
    - `generations`: one counter per slot. An increment regenerates that slot only.
  EOT

  type = object({
    active_slot = string
    generations = map(number)
  })

  default = {
    active_slot = "a"
    generations = {
      a = 1
      b = 1
    }
  }

  validation {
    condition     = contains(["a", "b"], var.control.active_slot)
    error_message = "control.active_slot must be \"a\" or \"b\"."
  }

  validation {
    # A list-to-tuple comparison is not type-safe here, so check the keys one by one.
    condition = (
      length(var.control.generations) == 2 &&
      contains(keys(var.control.generations), "a") &&
      contains(keys(var.control.generations), "b")
    )
    error_message = "control.generations must hold exactly the keys \"a\" and \"b\"."
  }

  validation {
    condition = alltrue([
      for generation in values(var.control.generations) :
      generation >= 1 && floor(generation) == generation
    ])
    error_message = "Each control.generations value must be an integer >= 1."
  }
}

variable "password_spec" {
  description = "Shape of the generated passwords. Both slots use the same shape."

  type = object({
    length           = optional(number, 32)
    upper            = optional(bool, true)
    lower            = optional(bool, true)
    numeric          = optional(bool, true)
    special          = optional(bool, true)
    min_upper        = optional(number, 1)
    min_lower        = optional(number, 1)
    min_numeric      = optional(number, 1)
    min_special      = optional(number, 1)
    override_special = optional(string, null)
  })

  default = {}

  validation {
    condition     = var.password_spec.length >= 16
    error_message = "password_spec.length must be 16 or more."
  }

  validation {
    condition = var.password_spec.length >= (
      var.password_spec.min_upper +
      var.password_spec.min_lower +
      var.password_spec.min_numeric +
      var.password_spec.min_special
    )
    error_message = "password_spec.length must be at least the sum of the min_* values."
  }

  validation {
    condition     = var.password_spec.special || var.password_spec.min_special == 0
    error_message = "password_spec.min_special must be 0 when special is false."
  }
}
