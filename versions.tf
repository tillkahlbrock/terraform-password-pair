terraform {
  # 1.6 is the floor for `terraform test`, which this module ships with.
  required_version = ">= 1.6.0"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
  }
}
