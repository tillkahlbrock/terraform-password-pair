# terraform-password-pair

A Terraform module that keeps two random passwords: one **active** and one **backup**.
It supports three operations: create the pair, rotate the backup password, and swap the
two roles. Every other run is a no-op.

The module depends on the `random` provider only. It writes nothing and reads no cloud
API, so the caller decides where the passwords go: AWS Secrets Manager, Vault,
Kubernetes, a database user, or anything else.

## The idea: a role is a mapping, not a property

A first design gives each role its own resource: `random_password.active` and
`random_password.backup`. That design cannot swap. The role is then a property of the
resource, so an exchange needs state surgery or a new password. Both are wrong: one is
not reproducible, the other destroys the credential it is supposed to keep.

This module makes the two passwords **peers**. It creates one password per **slot**,
`a` and `b`. Neither slot means "active". The role lives in a **control record** that
the outputs read:

```
                control record
        active_slot = "a"          ┌──────────────────────┐
        generations = {a=1, b=1}   │ random_password.slot │
                 │                 │   ["a"]  gen 1       │
                 ├── outputs ──────┤   ["b"]  gen 1       │
                 │                 └──────────────────────┘
        active_password  → slot a
        backup_password  → slot b
```

Every requirement follows from that one decision:

| Requirement | Mechanism | Applies |
| --- | --- | --- |
| Create two passwords | one `random_password` per slot | 1 |
| Rotate the backup password only | raise the generation counter of the **inactive** slot. `keepers` replaces that instance, and only that instance. | 1 |
| Swap the roles | flip `active_slot`. **No** resource changes. Only the output mapping changes, so no password is generated. | 1 |
| Idempotence | `keepers` is a pure function of the input. An unchanged control record produces an empty plan. | 0 |
| Substrate-agnostic | `hashicorp/random` only. The module returns values and owns no sink. | — |
| At most two applies | a full credential rotation is two phases: rotate, then swap. Each phase is one apply. | 2 |

The two phases are the point, not a limitation. Phase one creates the next password while
the current one stays valid. Phase two promotes it, and the previous password stays
available as the backup. No phase invalidates a password that consumers still use.

## Layout

```
.
├── main.tf, variables.tf, outputs.tf, versions.tf   the module
├── tests/                                           terraform test, 17 assertions
├── examples/basic/                                  a root module and its control file
└── tools/                                           the guard tool, bash and jq
```

## Use

```hcl
module "credentials" {
  source = "github.com/tillkahlbrock/terraform-password-pair"

  control = var.control # loaded from passwords.auto.tfvars.json

  password_spec = {
    length = 40
  }
}
```

The control record lives in `passwords.auto.tfvars.json`. Terraform loads every
`*.auto.tfvars.json` file automatically, so no wrapper script and no extra flag is
needed:

```json
{
  "control": {
    "active_slot": "a",
    "generations": { "a": 1, "b": 1 }
  }
}
```

The file is part of the configuration, not part of the state. It is therefore visible in
a diff and reviewable in a merge request. That is the reason for this location. Two
alternatives are worse: a `-var` flag hides the current state and a forgotten flag
reverts a swap without a trace; a workspace variable in Terraform Cloud, SSM, or
Parameter Store breaks the substrate-agnostic requirement.

### Outputs

| Output | Purpose |
| --- | --- |
| `active_password` | the password that consumers must use (sensitive) |
| `backup_password` | the password that consumers must still accept (sensitive) |
| `active_slot`, `backup_slot` | the current mapping. Read this instead of a resource address. |
| `generations` | the counter per slot. It rises by one per rotation. |
| `fingerprints` | a stable, non-reversible identity per slot |

`fingerprints` makes an operation observable without printing a secret. A rotation
changes the fingerprint of the backup slot. A swap changes no fingerprint at all,
because a swap moves no secret. The value is a truncated SHA-256 over the slot name, the
generation, and the password. The slot name and the generation act as a salt, so the
fingerprint does not help an attack on the password itself.

## Operate

`pwctl` is the only writer of the control record. One command is one operation.

```bash
cd examples/basic
terraform init && terraform apply        # the pair exists

../../tools/pwctl status
../../tools/pwctl rotate && terraform apply   # phase one: a new backup password
../../tools/pwctl swap   && terraform apply   # phase two: promote it
```

A real run of that sequence, with the fingerprints of both slots:

```
apply 0   a=a02aade388d6f018  b=411432f5b8802e5a   active slot a
rotate    generations a=1 b=1  ->  a=1 b=2
apply 1   a=a02aade388d6f018  b=baa8acf7530c9e77   active slot a   # only the backup changed
swap      active_slot a  ->  b
apply 2   a=a02aade388d6f018  b=baa8acf7530c9e77   active slot b   # no password changed
apply 3   No changes.
```

### The guard, and why it lives outside Terraform

The bonus requirement asks that rotation and swap cannot run at the same time. `pwctl`
enforces it three times over:

1. **One command, one operation.** There are no `--rotate` and `--swap` flags to combine.
2. **An exclusive lock directory**, taken with `mkdir`, which is atomic. Two `pwctl` runs
   cannot edit the control record at the same time.
3. **A pending-change guard.** Before a write, `pwctl` runs
   `terraform plan -detailed-exitcode`. Exit code 2 means that a change still waits for an
   apply. `pwctl` then refuses the new operation and exits with code 3. A rotation and a
   swap can therefore never land in the same apply.

Rule 3 has to be external, and this is the interesting part. Terraform evaluates the
configuration against the prior state, but the configuration cannot **read** that prior
state. A `validation`, `precondition`, or `check` block sees the new control record only.
It cannot see that the record already moved once since the last apply. The rule needs a
component that compares the desired state with the applied state, which is exactly what a
plan does. So the guard runs a plan and reads its exit code.

`pwctl` refuses an operation before the first apply as well, because the initial create is
a pending change. Apply first, then operate. `PWCTL_SKIP_PLAN_CHECK=1` exists for a broken
state, and it prints a warning.

`pwctl` never reads, writes, or logs a password. It only edits counters and one slot name.
It keeps every other variable in the control file, and it replaces the file with an atomic
rename.

The tool has no flags. Environment variables cover the few knobs, and `cd` picks the
working directory.

```
pwctl status | rotate | swap
  CONTROL_FILE             control file (default "passwords.auto.tfvars.json")
  TERRAFORM                binary to call; use tofu for OpenTofu
  LOCK_DIR                 lock directory (default ".pwctl.lock")
  PWCTL_SKIP_PLAN_CHECK=1  turn the pending-change guard off
exit codes: 0 done, 1 error, 3 refused because an apply is missing
```

It is a bash script around `jq`. Three `jq` definitions carry the whole record logic, and
the command name **is** the name of the `jq` function that runs, so one command cannot be
two operations. The write goes to a temporary file in the same directory and lands with a
rename, so a reader never sees half a record.

## Test

```bash
terraform test          # 17 assertions, no credentials, no cloud
tools/pwctl_test.sh     # 17 assertions over the record logic, the write, and the lock
```

The Terraform tests prove the behaviour instead of describing it:

| File | Proof |
| --- | --- |
| `creation.tftest.hcl` | the first apply creates one password per slot |
| `idempotence.tftest.hcl` | a second and a third apply keep both fingerprints |
| `rotation.tftest.hcl` | a rotation changes the backup fingerprint and keeps the active one |
| `swap.tftest.hcl` | a swap changes the roles and keeps both fingerprints |
| `two_apply_rotation.tftest.hcl` | rotate plus swap promotes the new password in two applies, and the old password stays the backup |
| `validation.tftest.hcl` | a broken control record fails before a password exists |

Both suites run in CI. `.github/workflows/ci.yml` runs the format check, the validation,
the Terraform tests, `shellcheck`, and the guard tests on every push. The pipeline needs no secret and no
cloud account, because the module talks to no cloud API.

## Alternatives considered

**Fixed roles plus `moved` blocks or `terraform state mv`.** The resource address then
carries the role, which reads well. It does not work. A simultaneous exchange of two
addresses is not expressible with `moved` blocks; it needs a three-step move through a
temporary address, so several applies and a configuration edit between them.
`terraform state mv` is imperative state surgery beside the plan and apply model: not
reviewable, not idempotent, and unsafe in a pipeline. The `keepers` expressions would also
have to follow every move, or the next plan replaces the password. Rejected.

**Fixed roles, copy the value across on a swap.** A `random_password` value comes from the
provider and cannot be assigned. This design needs a value-carrying layer, so the same
secret then exists under two addresses in the state, and the invariant "the backup after a
swap is the former active password" depends on the order inside a single apply.
`lifecycle.ignore_changes` would also hide real drift. More parts, less proof. Rejected.

**A ring of N slots with a moving pointer.** This generalises the design and handles an
N-way rotation with one operation. It also merges rotation and swap into one operation
called "advance", and this task needs them separate and mutually exclusive. The module
keeps two slots on purpose. The step to N slots is a change to `local.slots` and to the
control record, not to the design.

**A timestamp or `time_rotating` as the trigger.** Time-based regeneration breaks the
idempotence requirement by construction, because an apply after the deadline creates a new
password without an external trigger. A monotonic counter per slot is readable in a diff
and auditable. An opaque token would work as well, but it says nothing in a review.

## Simpler guards considered

The pending-change guard runs a plan and reads one exit code. Three simpler designs
exist. Each one trades something away.

**Let the tool own the apply.** `pwctl rotate` edits the control record and runs the apply
in one command. One command is then one operation and one apply, so the rule becomes a
property of the workflow and the guard disappears. The apply also leaves the hands of the
reviewer. A pipeline usually wants a plan before a credential changes, so the guard stays.

**Check the rule in the pipeline.** The control record lives in the repository, so a merge
request can carry the rule: read the record from the target branch, then fail when
`active_slot` and a generation counter change in the same commit. That is ten lines of
`jq` and no local tool at all. The guarantee then equals "the pipeline applies every merge". Two
merges before one apply still stack into one apply, so the local guard is the stronger
rule.

**Make the control record a log.** One input, an append-only list of operations, for
example `["rotate", "swap", "rotate"]`. The module replays it: the active slot is the
parity of the `swap` count, and the generation of a slot is one plus the number of
rotations that happened while that slot was inactive. "Rotate and swap at the same time"
then has no representation in the input, and the log doubles as an audit trail. The cost:
the replay moves into HCL, the record grows without bound, and one rule survives anyway,
because the log must not grow by two between two applies.

## Security notes

- Both passwords are in the Terraform state, in clear text. This is true for every
  `random_*` resource. Use an encrypted remote backend with strict access, for example S3
  with SSE-KMS, DynamoDB locking, and no public read.
- The outputs are marked `sensitive`, so a plan or an apply does not print them. A root
  module that exposes them must mark its own outputs as well.
- `fingerprints` is safe to log. It is a truncated hash over a salted 32-character random
  password.
- Do not commit a `*.tfstate` file. `.gitignore` covers the state, the lock directory, and
  a temporary control file left behind by an interrupted write.
- The state is the source of truth for a password, so a backend restore restores a
  credential pair. Keep the backup password acceptable to consumers for at least one
  rotation interval.

## Limits and next steps

- The module owns the passwords, not their distribution. A production setup adds a thin
  substrate module per sink, so the pair stays reusable.
- Consumers must accept both passwords during a rotation. That is a property of the
  consuming system, not of this module. Where a system accepts one password only, the two
  phases become two short windows instead of a safe overlap.
- `pwctl` locks the working directory. In a pipeline, the same guarantee needs the state
  lock of the backend, so let the pipeline own both steps of a phase.
- A rotation schedule belongs in the pipeline, not in the module. `pwctl rotate` in a
  scheduled job plus a review of the diff keeps the trigger explicit and auditable.
