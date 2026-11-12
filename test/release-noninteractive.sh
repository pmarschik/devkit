#!/usr/bin/env bash
# Without a terminal, release:push and release:rollback refuse to run unless
# told to: --yes, its alias --non-interactive, or DEVKIT_NON_INTERACTIVE=1. A
# refused push changes nothing, local or remote. prepare accepts the flags and
# still never pushes.
#
# mise hands a flag to the task as usage_<name>=true, which is how the cases
# below pass one.
set -uo pipefail
# shellcheck source=_release_helpers.bash
source "$(dirname "$0")/_release_helpers.bash"
require jj git-cliff go jq
fake cog

remote_main() { git --git-dir="${REMOTE}" rev-parse main; }
remote_tags() { git --git-dir="${REMOTE}" tag -l | tr '\n' ' '; }

echo "prepare takes the flags and pushes nothing"
new_remote ni
d="${TMP}/ni"; new_jj_repo "$d" example.com/ni
jj_change "$d" "feat: thing"
before=$(remote_main)
run_task "$d" prepare usage_yes=true usage_non_interactive=true
check_eq "prepare succeeds" 0 "${STATUS}"
check_eq "origin main unchanged" "${before}" "$(remote_main)"
check_eq "no tags on origin" "" "$(remote_tags)"

echo "push without a terminal and without --yes refuses"
prepared=$(cd "$d" && jj log -r @ --no-graph -T commit_id)
run_task "$d" push
check_eq "push fails" 1 "${STATUS}"
check_contains "says how to proceed" "pass --yes" "${OUT}"
check_eq "origin main unchanged" "${before}" "$(remote_main)"
check_eq "no tags on origin" "" "$(remote_tags)"
check_eq "no local tag" "" "$(cd "$d" && jj tag list)"
check_eq "release commit untouched" "${prepared}" "$(cd "$d" && jj log -r main --no-graph -T commit_id)"

echo "a dry run needs no confirmation"
run_task "$d" push usage_dry_run=true
check_eq "dry run succeeds" 0 "${STATUS}"

echo "rollback refuses the same way, and runs with --non-interactive"
run_task "$d" rollback
check_eq "rollback fails" 1 "${STATUS}"
check_contains "says how to proceed" "pass --yes" "${OUT}"
check_eq "still prepared" "chore(release): v0.1.0" "$(cd "$d" && jj log -r @ --no-graph -T 'description.first_line()')"
run_task "$d" rollback usage_non_interactive=true
check_eq "rollback succeeds" 0 "${STATUS}"
check_lacks "release description gone" "chore(release)" "$(cd "$d" && jj log -r @ --no-graph -T 'description')"

for how in usage_yes=true usage_non_interactive=true DEVKIT_NON_INTERACTIVE=1; do
  echo "push runs with ${how}"
  new_remote "ni-${how%%=*}"
  d="${TMP}/ni-${how%%=*}"; new_jj_repo "$d" "example.com/ni${how%%=*}"
  jj_change "$d" "feat: thing"
  run_task "$d" prepare
  run_task "$d" push "${how}"
  check_eq "push succeeds" 0 "${STATUS}"
  check_eq "tag on origin" "v0.1.0 " "$(remote_tags)"
done

finish
