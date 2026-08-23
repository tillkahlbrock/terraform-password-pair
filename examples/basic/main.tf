terraform {
  required_version = ">= 1.6.0"
}

variable "control" {
  description = "Loaded from passwords.auto.tfvars.json. The pwctl tool owns that file."

  type = object({
    active_slot = string
    generations = map(number)
  })
}

module "credentials" {
  source = "../../"

  control = var.control

  password_spec = {
    length = 40
  }
}

# The module returns values. It writes nothing. The caller picks the substrate.
#
# On AWS:
#   resource "aws_secretsmanager_secret_version" "active" {
#     secret_id     = aws_secretsmanager_secret.database.id
#     secret_string = module.credentials.active_password
#   }
#
# On Kubernetes:
#   resource "kubernetes_secret" "database" {
#     data = {
#       password        = module.credentials.active_password
#       password_backup = module.credentials.backup_password
#     }
#   }
#
# In Vault:
#   resource "vault_kv_secret_v2" "database" {
#     data_json = jsonencode({
#       active = module.credentials.active_password
#       backup = module.credentials.backup_password
#     })
#   }

output "active_slot" {
  value = module.credentials.active_slot
}

output "backup_slot" {
  value = module.credentials.backup_slot
}

output "generations" {
  value = module.credentials.generations
}

output "fingerprints" {
  description = "Keyed by slot. Watch one entry change across a rotation, and all of them stay equal across a swap."
  value       = module.credentials.fingerprints
}

output "active_fingerprint" {
  description = "Keyed by role. Watch this change across a swap."
  value       = module.credentials.active_fingerprint
}

output "backup_fingerprint" {
  description = "Keyed by role. Watch this change across a rotation and across a swap."
  value       = module.credentials.backup_fingerprint
}

output "active_password" {
  value     = module.credentials.active_password
  sensitive = true
}

output "backup_password" {
  value     = module.credentials.backup_password
  sensitive = true
}
