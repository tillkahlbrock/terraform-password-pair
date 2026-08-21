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
    A stable, non-reversible identity per slot. Two runs with the same passwords
    produce the same fingerprints. Use it to observe rotation and swap without
    reading the secrets. The fingerprint is salted with the slot name and the
    generation counter, so it does not help an offline attack on the password.
  EOT

  value = {
    for slot, password in random_password.slot :
    slot => substr(
      sha256("${slot}:${var.control.generations[slot]}:${nonsensitive(password.result)}"),
      0,
      16
    )
  }
}
