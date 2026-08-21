# Basic example

Terraform loads `passwords.auto.tfvars.json` on every run. The `pwctl` tool is the
only writer of that file.

```bash
terraform init
terraform apply

# Look at the state of the pair.
../../tools/pwctl/pwctl status

# Phase one: replace the backup password.
../../tools/pwctl/pwctl rotate
terraform apply

# Phase two: promote it.
../../tools/pwctl/pwctl swap
terraform apply
```

`terraform output fingerprints` shows the effect of each phase without printing a
secret. The rotation changes the fingerprint of the backup slot. The swap changes
no fingerprint at all, because it moves no secret.
