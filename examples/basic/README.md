# Basic example

Terraform loads `passwords.auto.tfvars.json` on every run. The `pwctl` tool is the
only writer of that file.

```bash
terraform init
terraform apply

# Look at the state of the pair.
../../tools/pwctl status

# Phase one: replace the backup password.
../../tools/pwctl rotate
terraform apply

# Phase two: promote it.
../../tools/pwctl swap
terraform apply
```

`terraform output` shows the effect of each phase without printing a secret, and the
fingerprints answer two questions.

`active_fingerprint` and `backup_fingerprint` follow the roles. The rotation changes the
backup view. The swap makes the two views trade places.

`fingerprints` is keyed by slot instead, so the rotation changes one entry and the swap
changes nothing at all. That is the proof that a swap moves no secret.
