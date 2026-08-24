# Design decisions

Why the module looks the way it does, and what each rejected design does instead. Every error
message and plan summary here comes from a run against real state.

Back to the [README](README.md).

## The design

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
creation time instead of lagging one step behind: after two rotations the backup is two
generations old and nothing reports it, which is worse than no backup at all. Rejected.

**A ring of N slots with a moving pointer.** One operation, "advance", moves the pointer and
regenerates the slot that falls off the back. With three slots or more the overlap window gets
*longer* than the two-slot design allows: the password that was active stays valid as the first
backup, so a consumer that lags a deploy cycle still holds a value that is accepted.
Operationally that is the stronger design.

It is rejected on scope, not on merit. The brief asks for rotation and swap as two separate
operations, and it asks that they cannot run at the same time. "Advance" fuses them, so the
bonus requirement is not met but voided: nothing is left to exclude. Had the requirement been
an N-way rotation with history, this is what the module would be.

Two slots therefore stay on purpose. Going to N is not a one-line change either: both hardcoded
validations have to move, `one()` stops resolving `backup_slot`, and the singular backup outputs
lose their meaning, which is a change to the output contract.

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

A counter is explicit and auditable: `1 → 2` says "second rotation of this slot", where an
opaque token says only that something changed. Rejected — although a schedule is what a
production rotation wants, and this brief rules it out.

## The guard

The pending-change guard runs a plan and reads one exit code. Three simpler designs
exist. Each one trades something away.

**Let the tool own the apply.** `pwctl rotate` edits the control record and runs the apply in
one command. One command is then one operation and one apply, so the rule stops being a check
and becomes a property of the workflow, which is always the stronger form. The apply leaves the
hands of the reviewer, and a pipeline usually wants a plan before a credential changes. It also
does nothing about a hand edit: whoever writes the file and applies it directly passes this
design and the shipped guard alike.

**Check the rule in the pipeline.** The control record lives in the repository, so a merge
request can carry the rule: read the record from the target branch and judge the transition.
About fifteen lines of `jq` reject every transition that no single operation could produce — a
swap together with a rotation, more than one counter moving, a counter that jumps by two or
falls, and a rotation that targets the active slot instead of the standby one. No local tool is
needed at all.

Neither guard dominates the other. The local one binds whoever runs `pwctl`, and a hand edit
followed by a direct apply never reaches it. The pipeline one binds whatever goes through a
merge request, and two merges before one apply still stack. Only a check on the path that
applies, comparing `terraform output` with the file, binds every route; the last entry under
[Limits](README.md#limits-and-next-steps) says why that one is missing here.

**Make the control record a log.** One input, an append-only list of operations, for example
`["rotate", "swap", "rotate"]`. The module replays it: the parity of the `swap` entries gives
the active slot, and a `rotate` at position *i* hits the slot that was not active at that point.
The replay is about ten lines of HCL and it works — that log yields `active=b` with generations
`{a: 2, b: 2}`.

It buys the strongest property in this document: which slot a rotation hits is derived, not
supplied, so "rotate the active password" has no representation in the input at all. It is not
checked, it is unexpressible. The log doubles as an audit trail.

The costs are real. The replay lives in HCL, the record grows without bound, and editing history
instead of appending to it re-derives everything after the edited entry: changing the first entry
plans `1 to add, 0 to change, 1 to destroy`, so tampering announces itself by destroying a
credential. One rule also survives. Appending `"rotate"` and `"swap"` in one go puts a freshly
generated password straight into the active role in a single apply, with no propagation window.
