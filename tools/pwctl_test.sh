#!/usr/bin/env bash
# Tests for tools/pwctl. They need bash and jq, no Terraform and no network:
# PWCTL_SKIP_PLAN_CHECK turns off the one check that runs a plan.
set -euo pipefail

PWCTL=$(cd "$(dirname "$0")" && pwd)/pwctl
CONTROL=passwords.auto.tfvars.json
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

failures=0
valid='{"control":{"active_slot":"a","generations":{"a":1,"b":1}}}'

# A case directory with its own control file.
setup() {
  local directory=$WORKDIR/$1
  mkdir -p "$directory"
  printf '%s\n' "${2:-$valid}" >"$directory/$CONTROL"
  printf '%s' "$directory"
}

# The guard is off in tests, so pwctl warns on every call. Drop that noise; a
# failing assertion reports what it wanted and what it got anyway.
pwctl() { (cd "$1" && PWCTL_SKIP_PLAN_CHECK=1 "$PWCTL" "$2" 2>/dev/null); }

control_of() { jq -c .control "$1/$CONTROL"; }

mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

check() { # label, want, got
  if [[ $2 == "$3" ]]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"
    failures=$((failures + 1))
  fi
}

check_refused() { # label, directory, operation
  if pwctl "$2" "$3" >/dev/null 2>&1; then
    printf 'FAIL %s: pwctl accepted it\n' "$1"
    failures=$((failures + 1))
  else
    printf 'ok   %s\n' "$1"
  fi
}

t_rotate_raises_the_backup_generation_only() {
  local directory
  directory=$(setup rotate)
  pwctl "$directory" rotate >/dev/null
  check "rotate raises the backup counter and keeps the active one" \
    '{"active_slot":"a","generations":{"a":1,"b":2}}' "$(control_of "$directory")"
}

t_rotate_follows_the_active_slot() {
  local directory
  directory=$(setup rotate-after-swap)
  pwctl "$directory" swap >/dev/null
  pwctl "$directory" rotate >/dev/null
  check "rotate after a swap targets the other slot" \
    '{"active_slot":"b","generations":{"a":2,"b":1}}' "$(control_of "$directory")"
}

t_swap_exchanges_the_roles_and_keeps_every_generation() {
  local directory
  directory=$(setup swap '{"control":{"active_slot":"a","generations":{"a":1,"b":3}}}')
  pwctl "$directory" swap >/dev/null
  check "swap flips the pointer and touches no counter" \
    '{"active_slot":"b","generations":{"a":1,"b":3}}' "$(control_of "$directory")"
}

t_two_swaps_return_to_the_start() {
  local directory
  directory=$(setup two-swaps)
  pwctl "$directory" swap >/dev/null
  pwctl "$directory" swap >/dev/null
  check "two swaps return to the start" \
    '{"active_slot":"a","generations":{"a":1,"b":1}}' "$(control_of "$directory")"
}

t_status_prints_the_record() {
  local directory
  directory=$(setup status)
  check "status names both roles" \
    'active a, backup b, generations {"a":1,"b":1}' "$(pwctl "$directory" status)"
}

t_a_broken_record_is_refused() {
  check_refused "an unknown slot name is refused" \
    "$(setup broken-slot '{"control":{"active_slot":"c","generations":{"a":1,"b":1}}}')" rotate
  check_refused "a foreign slot name is refused" \
    "$(setup broken-keys '{"control":{"active_slot":"x","generations":{"x":1,"y":1}}}')" rotate
  check_refused "a missing counter is refused" \
    "$(setup broken-count '{"control":{"active_slot":"a","generations":{"a":1}}}')" rotate
  check_refused "a generation below one is refused" \
    "$(setup broken-zero '{"control":{"active_slot":"a","generations":{"a":0,"b":1}}}')" rotate
  check_refused "an unknown command is refused" "$(setup broken-verb)" frobnicate
}

t_a_broken_record_leaves_the_file_alone() {
  local directory broken
  broken='{"control":{"active_slot":"c","generations":{"a":1,"b":1}}}'
  directory=$(setup untouched "$broken")
  pwctl "$directory" rotate >/dev/null 2>&1 || true
  check "a refused operation writes nothing" "$broken" "$(cat "$directory/$CONTROL")"
  check "a refused operation leaves no temporary file" \
    "1" "$(find "$directory" -maxdepth 1 -type f | wc -l | tr -d ' ')"
}

t_every_other_variable_survives() {
  local directory
  directory=$(setup siblings '{
  "password_spec": { "length": 48 },
  "control": { "active_slot": "a", "generations": { "a": 1, "b": 1 } },
  "other": "keep me"
}')
  pwctl "$directory" rotate >/dev/null
  check "a sibling variable survives the write" \
    '48' "$(jq -c .password_spec.length "$directory/$CONTROL")"
  check "the key order survives the write" \
    '["password_spec","control","other"]' "$(jq -c 'keys_unsorted' "$directory/$CONTROL")"
}

t_the_file_mode_survives() {
  local directory
  directory=$(setup mode)
  chmod 644 "$directory/$CONTROL"
  pwctl "$directory" rotate >/dev/null
  check "the control file keeps mode 644" "644" "$(mode_of "$directory/$CONTROL")"
}

t_the_lock_is_exclusive() {
  local directory
  directory=$(setup lock)
  mkdir "$directory/.pwctl.lock"
  check_refused "a held lock blocks a second run" "$directory" rotate
  rmdir "$directory/.pwctl.lock"
  pwctl "$directory" rotate >/dev/null
  check "the lock is released again" \
    '{"active_slot":"a","generations":{"a":1,"b":2}}' "$(control_of "$directory")"
}

for test in $(compgen -A function t_); do
  "$test"
done

if ((failures > 0)); then
  printf '\n%d assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall assertions passed\n'
