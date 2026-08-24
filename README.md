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

## Layout

```
.
├── main.tf, variables.tf, outputs.tf, versions.tf   the module
├── tests/                                           terraform test, 17 cases
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
| `fingerprints` | a stable identity per slot, to prove what was regenerated |
| `active_fingerprint`, `backup_fingerprint` | the same identity per role, to see what is live |

The fingerprints make an operation observable without printing a secret, and they answer
two different questions. `fingerprints` is keyed by slot, so an entry is stable for as long
as that password is: a rotation changes one entry, and a swap changes nothing at all.
`active_fingerprint` and `backup_fingerprint` are keyed by role, so they follow the roles: a
rotation changes the backup view only, and a swap makes the two views trade places. Read the
role views to see what is live, and the slot map to prove what was regenerated.

Every value is a truncated SHA-256 over the slot name, the generation, and the password. The
slot name and the generation act as a salt, so a fingerprint does not help an attack on the
password itself.

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

## Alternatives considered

**Fixed roles: `random_password.active` and `random_password.backup`.** The resource address
then carries the role, which reads well. It also makes the role a property of the resource,
so an exchange needs either state surgery or a new password. One is not reproducible, the
other destroys the credential it is meant to keep.

Neither mechanism holds up. `moved` blocks cannot express the exchange at all: a plan fails
with *"Moved object still exists"*, because a move means that the source address is gone from
the configuration, while a swap needs both addresses to stay. The way around it is a three-step
move through a temporary address, so three configuration edits and three applies, which busts
the two-apply requirement on its own.

`terraform state mv` does perform the exchange, and that is the trap. It is imperative state
surgery beside the plan and apply model: not reviewable in a diff, not idempotent, and unsafe
in a pipeline. Worse, the keeper values travel with the resources while the configuration keys
them by role, so the objects land at addresses whose keeper expressions no longer match. The
next plan — any plan, not the next rotation — then reports `2 to add, 0 to change, 2 to
destroy`. The swap succeeds and leaves a mine that destroys both credentials. Rejected.

**Fixed roles, copy the value across on a swap.** A `random_password` value is computed by the
provider, so it cannot be assigned. The design therefore needs a value-carrying resource, and
that resource holds a second copy of the secret: after one apply the same cleartext password
sits under two addresses in the state. The doubling is the mechanism here, not a side effect.

The invariant the design exists for — after a swap the backup holds the value that was active
before — cannot be expressed at all. A carrier can only mirror the current value. Reading its
own previous one fails with *"Self-referential block"*, and routing it through a second carrier
fails with *"Cycle"*. The configuration is a graph over the desired state, and "the value from
before this apply" is not a node in that graph.

`lifecycle { ignore_changes = [input] }` looks like the way out, but it freezes the carrier at
creation time instead of lagging one step behind. After two rotations the backup holds a value
that is two generations old, and nothing reports it. A backup that falls arbitrarily far behind
while looking healthy is worse than none. More parts, one more copy of every secret, and the
central invariant still unstated. Rejected.

**A ring of N slots with a moving pointer.** One operation, "advance", moves the pointer and
regenerates the slot that falls off the back. With three slots or more the overlap window gets
*longer* than the two-slot design allows: the password that was active stays valid as the first
backup, so a consumer that lags a deploy cycle still holds a value that is accepted.
Operationally that is the stronger design.

It is rejected on scope, not on merit. The brief asks for rotation and swap as two separate
operations, and it asks that they cannot run at the same time. "Advance" fuses them, so the
bonus requirement is not met but voided: nothing is left to exclude. Had the requirement been
an N-way rotation with history, this is what the module would be.

Two slots therefore stay on purpose, and going to N is not a one-line change. Both hardcoded
validations in `variables.tf` have to move; `backup_slot` then stops resolving, because `one()`
receives more than one candidate; and `backup_password`, `backup_slot` and `backup_fingerprint`
lose their meaning once "the backup" is no longer a single thing. That last part is a change to
the output contract, which is a change to the design.

**A timestamp or `time_rotating` as the trigger.** Time-based regeneration breaks the
idempotence requirement by construction, and it breaks it in the worst way. Inside the window a
plan reports `No changes`. Once the due date passes, the very same configuration replaces the
`time_rotating` resource, which changes the keeper, which replaces the password. Nobody
triggered anything; the clock moved. The requirement holds right up until it does not, so a
reviewer who applies twice sees an idempotence that is not there.

It also forces a decision about how many clocks to run. One shared time source rotates both
passwords at the same deadline and destroys the overlap the design exists for, in a single
apply. Avoiding that means one time source per slot with offset schedules: the two phases
rebuilt as a pair of cron jobs that must never coincide.

A monotonic counter per slot is explicit, readable in a diff, and auditable. `1 → 2` says
"second rotation of this slot". An opaque token works mechanically, but `f3a9… → 7c21…` says
only that something changed, which is little help in a merge request. Rejected — although a
schedule is what a production rotation wants, and this brief rules it out.

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
- **A hand edit can still break the pair. This is open.** `pwctl` is the only writer of the
  control record by convention, not by control. Terraform keeps rejecting an invalid
  record, so the slot names and the counters stay sound, but it cannot reject an invalid
  *transition*: raising the counter of the active slot replaces the live password, and
  moving both fields in one edit puts a rotation and a swap in one apply. Every rule beyond
  validity compares the desired record with the applied one, and a configuration cannot read
  the prior state. The fix belongs on the path that applies rather than in the tool: a job
  before the apply that compares `terraform output` with the file and refuses a transition
  that no single operation could produce. It is not implemented here.
- `pwctl` locks the working directory. In a pipeline, the same guarantee needs the state
  lock of the backend, so let the pipeline own both steps of a phase.
- A rotation schedule belongs in the pipeline, not in the module. `pwctl rotate` in a
  scheduled job plus a review of the diff keeps the trigger explicit and auditable.
