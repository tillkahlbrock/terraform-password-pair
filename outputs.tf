output "active_password" {
  description = "The password that consumers must use."
  value       = random_password.slot[local.active_slot].result
  sensitive   = true
}

output "backup_password" {
  description = "The password that consumers must still accept, but not use."
  value       = random_password.slot[local.backup_slot].result
  sensitive   = true
}

output "active_slot" {
  description = "The slot that holds the active password. Read this instead of the resource address."
  value       = local.active_slot
}

output "backup_slot" {
  description = "The slot that holds the backup password. `pwctl rotate` targets this slot."
  value       = local.backup_slot
}

output "generations" {
  description = "The generation counter of each slot. It increases by one per rotation."
  value       = var.control.generations
}

output "fingerprints" {
  description = <<-EOT
    A stable, non-reversible identity per slot. Keyed by slot, so an entry is stable
    for as long as that password is: a rotation changes one entry, and a swap changes
    nothing. Use it to prove what was regenerated.
  EOT

  value = local.fingerprints
}

output "active_fingerprint" {
  description = "The identity of the live password. A swap changes this; a rotation does not."
  value       = local.fingerprints[local.active_slot]
}

output "backup_fingerprint" {
  description = "The identity of the standby password. A rotation changes this, and a swap does too."
  value       = local.fingerprints[local.backup_slot]
}
