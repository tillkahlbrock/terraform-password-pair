# The module rejects a broken control record before it touches a password.

run "unknown_slot_name" {
  command = plan

  variables {
    control = {
      active_slot = "c"
      generations = { a = 1, b = 1 }
    }
  }

  expect_failures = [var.control]
}

run "missing_generation_counter" {
  command = plan

  variables {
    control = {
      active_slot = "a"
      generations = { a = 1 }
    }
  }

  expect_failures = [var.control]
}

run "generation_below_one" {
  command = plan

  variables {
    control = {
      active_slot = "a"
      generations = { a = 0, b = 1 }
    }
  }

  expect_failures = [var.control]
}

run "password_too_short" {
  command = plan

  variables {
    password_spec = {
      length = 8
    }
  }

  expect_failures = [var.password_spec]
}

run "special_characters_contradict_the_minimum" {
  command = plan

  variables {
    password_spec = {
      special     = false
      min_special = 2
    }
  }

  expect_failures = [var.password_spec]
}

run "extra_generation_counter" {
  command = plan

  variables {
    control = {
      active_slot = "a"
      generations = { a = 1, b = 1, c = 1 }
    }
  }

  expect_failures = [var.control]
}

run "fractional_generation" {
  command = plan

  variables {
    control = {
      active_slot = "a"
      generations = { a = 1, b = 1.5 }
    }
  }

  expect_failures = [var.control]
}

run "length_below_the_sum_of_the_minimums" {
  command = plan

  variables {
    password_spec = {
      length      = 16
      min_upper   = 8
      min_lower   = 8
      min_numeric = 8
      min_special = 8
    }
  }

  expect_failures = [var.password_spec]
}
