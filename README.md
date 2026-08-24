# terraform-password-pair

A Terraform module that keeps two random passwords: one **active** and one **backup**.
It supports three operations: create the pair, rotate the backup password, and swap the
two roles. Every other run is a no-op.

The module depends on the `random` provider only. It writes nothing and reads no cloud
API, so the caller decides where the passwords go: AWS Secrets Manager, Vault,
Kubernetes, a database user, or anything else.

## The idea: a role is a mapping, not a property

The module creates one password per **slot**, `a` and `b`. The two are peers: neither slot
means "active", and neither resource knows its own role. The role lives in a **control
record**, and the outputs read it:

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

`active_slot` names the slot that is live. `generations` holds one counter per slot, and a
counter is the only trigger for a new password. The two fields are one record with one
writer, the `pwctl` tool.

Every requirement follows from that one separation — the password in a slot, the role in
the control record:

| Requirement | Mechanism | Applies |
| --- | --- | --- |
| Create two passwords | one `random_password` per slot | 1 |
| Rotate the backup password only | raise the generation counter of one slot. `keepers` replaces that instance, and only that instance. Aiming at the standby slot is the tool's job, not the module's. | 1 |
| Swap the roles | flip `active_slot`. **No** resource changes. Only the output mapping changes, so no password is generated. | 1 |
| Idempotence | `keepers` is a pure function of the input. An unchanged control record produces an empty plan. | 0 |
| Substrate-agnostic | `hashicorp/random` only. The module returns values and owns no sink. | — |
| At most two applies | a full credential rotation is two phases: rotate, then swap. Each phase is one apply. | 2 |

The two phases are the point, not a limitation. Phase one creates the next password while
the current one stays valid. Phase two promotes it, and the previous password stays
available as the backup. No phase invalidates a password that consumers still use.

## Use

Terraform 1.6 or newer (the floor for `terraform test`) and `hashicorp/random` 3.5 or newer.
`pwctl` needs `bash` and `jq`.

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

### Inputs

`control` is the rotation control record, an object of `active_slot` and `generations`. It
defaults to slot `a` active with both counters at 1. Terraform rejects a record where
`active_slot` is not `a` or `b`, where `generations` does not hold exactly those two keys, or
where a counter is not an integer of 1 or more. `pwctl` owns this value.

`password_spec` shapes both passwords, and both slots share one shape. Every field is
optional:

| Field | Default | Note |
| --- | --- | --- |
| `length` | `32` | at least 16, and at least the sum of the four minimums |
| `upper`, `lower`, `numeric`, `special` | `true` | which character classes may appear |
| `min_upper`, `min_lower`, `min_numeric`, `min_special` | `1` | `min_special` must be 0 when `special` is false |
| `override_special` | `null` | replaces the provider's set of special characters |

### Outputs

| Output | Purpose |
| --- | --- |
| `active_password` | the password that consumers must use (sensitive) |
| `backup_password` | the password that consumers must still accept (sensitive) |
| `active_slot`, `backup_slot` | the current mapping. Read this instead of a resource address. |
| `generations` | the counter per slot. It rises by one per rotation. |
| `fingerprints` | a stable identity per slot, to prove what was regenerated |
| `active_fingerprint`, `backup_fingerprint` | the same identity per role, to see what is live |

The fingerprints make an operation observable without printing a secret. `fingerprints` is
keyed by slot, so a rotation changes one entry and a swap changes nothing at all: read it to
prove what was regenerated. The role views follow the roles: read them to see what is live.
Every value is a truncated SHA-256 over the slot name, the generation, and the password, and
why that is safe to log is in [Security notes](#security-notes).

## Operate

`pwctl` writes the control record, by convention rather than by control. One command is one
operation. Nothing stops a person from editing the file instead, and the last entry under
[Limits](#limits-and-next-steps) says what that costs.

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
   apply. `pwctl` then refuses the new operation and exits with code 3. A rotation and a swap
   therefore do not land in the same apply, for as long as the guard is on. It has an
   off switch, and the paragraph below says so.

Rule 3 has to be external, and this is the interesting part. Terraform evaluates the
configuration against the prior state, but the configuration cannot **read** that prior
state. A `validation`, `precondition`, or `check` block sees the new control record only.
It cannot see that the record already moved once since the last apply. The rule needs a
component that compares the desired state with the applied state, which is exactly what a
plan does. So the guard runs a plan and reads its exit code.

`pwctl` refuses an operation before the first apply as well, because the initial create is
a pending change. Apply first, then operate. `PWCTL_SKIP_PLAN_CHECK=1` exists for a broken
state, and it prints a warning.

`tools/pwctl_test.sh` covers this guard against a real state: it applies a throwaway root
module, rotates, and asserts that the next operation exits with code 3 until the apply has
run. That test is the only one that leaves the switch on.

`pwctl` never reads, writes, or logs a password. It only edits counters and one slot name.
It keeps every other variable in the control file, and it replaces the file with an atomic
rename.

`pwctl` has no flags. `CONTROL_FILE`, `TERRAFORM`, `LOCK_DIR` and `PWCTL_SKIP_PLAN_CHECK`
cover the knobs, `cd` picks the working directory, and `pwctl` without an argument prints the
rest. It exits 3 when it refuses because an apply is missing.

## Test

```bash
terraform test          # 17 cases, 28 checks, no credentials, no cloud
tools/pwctl_test.sh     # 22 assertions over the record logic, the write, the lock, and the guard
```

The Terraform tests prove the behaviour instead of describing it:

| File | Proof |
| --- | --- |
| `creation.tftest.hcl` | the first apply creates one password per slot |
| `idempotence.tftest.hcl` | a second and a third apply keep both fingerprints |
| `rotation.tftest.hcl` | a rotation changes the backup fingerprint and keeps the active one |
| `swap.tftest.hcl` | a swap changes the roles, keeps both slot fingerprints, and makes the role views trade |
| `two_apply_rotation.tftest.hcl` | rotate plus swap promotes the new password in two applies, and the old password stays the backup |
| `validation.tftest.hcl` | a broken control record fails before a password exists |

Both suites run in CI. `.github/workflows/ci.yml` runs the format check, the validation,
the Terraform tests, `shellcheck`, and the guard tests on every push. The pipeline needs no secret and no
cloud account, because the module talks to no cloud API.

## Rejected designs

Seven designs were tried and dropped: fixed roles moved with `moved` blocks or
`terraform state mv`, fixed roles that copy the value across on a swap, a ring of N slots
with a moving pointer, a time-based trigger, and three simpler guards — the tool owning the
apply, a diff check in the pipeline, and an append-only operation log.
[DECISIONS.md](DECISIONS.md) carries each one with the error message or the plan summary it
produces.

## Security notes

- Both passwords are in the Terraform state, in clear text. This is true for every
  `random_*` resource. Use an encrypted remote backend with strict access, for example S3
  with SSE-KMS, DynamoDB locking, and no public read.
- The two password outputs are marked `sensitive`, so a plan or an apply prints
  `<sensitive>` in their place. The other six outputs are plain on purpose. A root module
  that exposes the passwords must mark its own outputs as well.
- The three fingerprint outputs are safe to log. What protects them is the entropy of the
  password, not the salt: `slot:generation` is predictable, and it only keeps the
  fingerprints of one value distinct across slots and generations. Even the weakest shape
  this module accepts, 16 characters from a single character class, carries about 2^75
  possibilities. The hash is truncated to 64 bits, which is enough to compare two
  fingerprints, so "equal fingerprints, equal password" holds with probability 1 - 2^-64
  rather than absolutely.
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
- **A hand edit can still break the pair. This is open.** `pwctl` is the only writer of the
  control record by convention, not by control. Terraform keeps rejecting an invalid
  record, so the slot names and the counters stay sound, but it cannot reject an invalid
  *transition*: raising the counter of the active slot replaces the live password, lowering
  any counter replaces a password as well, because the keeper compares for equality and not
  for growth, and moving both fields in one edit puts a rotation and a swap in one apply. A
  lowered counter costs twice: a credential is gone, and two different passwords then carry
  the same generation number, so the audit trail lies. Every rule beyond validity compares the
  desired record with the applied one, and a configuration cannot read the prior state. The fix belongs on the path that applies rather than in the tool: a job
  before the apply that compares `terraform output` with the file and refuses a transition
  that no single operation could produce. It is not implemented here.
- `pwctl` locks the working directory, and only that. Two checkouts take two locks: one
  runner stages a rotation while another stages a swap, and both succeed. In a pipeline the
  guarantee therefore needs the state lock of the backend, so let the pipeline own both steps
  of a phase.
- A rotation schedule belongs in the pipeline, not in the module. That is not the time-based
  trigger rejected in [DECISIONS.md](DECISIONS.md). A scheduler outside Terraform produces an
  explicit input change: a commit on the control record that a person reviews and merges, so
  the outcome of a plan never depends on the clock. With `time_rotating` the clock is part of the configuration;
  here it is part of the trigger. Terraform stays idempotent, and the scheduler is what
  moves.
