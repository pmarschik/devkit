#!/usr/bin/env bash
# Under jj, release:prepare calls a release its first only when the repo has no
# vX.Y.Z tag, and a tag listing that fails stops the release rather than
# meaning "no tags".
#
# The real jj covers the first two cases. A wrapping jj then stands in for the
# two ways the listing has gone wrong: a jj that rejects the pattern outright,
# the way jj 0.47 rejects a bare glob:v[0-9]*, and an older jj that splits the
# pattern at the colon and so reads a quoted glob:"v[0-9]*" literally, quotes
# and all, and lists nothing. Every other jj call reaches the real one.
set -uo pipefail
# shellcheck source=_release_helpers.bash
source "$(dirname "$0")/_release_helpers.bash"
require jj git-cliff jq
fake cog
fake dprint

REAL_JJ=$(command -v jj)
WRAP="${TMP}/wrapped-jj"
mkdir -p "${WRAP}"

# wrap_jj <body>: a jj whose `tag list` runs <body> with the pattern in $3.
wrap_jj() {
  cat > "${WRAP}/jj" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == tag && "\$2" == list ]]; then
$1
fi
exec "${REAL_JJ}" "\$@"
EOF
  chmod +x "${WRAP}/jj"
}

headings() { grep -c "^## \[$2\]" "$1/CHANGELOG.md" 2>/dev/null; }
description() { (cd "$1" && jj log -r @ --no-graph -T 'description.first_line()'); }

tagged_repo() { # name — a jj repo released at v0.1.0 and v0.9.0, one feat since
  new_remote "$1"
  d="${TMP}/$1"; new_jj_repo "$d" "example.com/$1"
  (cd "$d" && jj tag set v0.1.0 -r main > /dev/null 2>&1)
  jj_change "$d" "fix: later"
  (cd "$d" && jj tag set v0.9.0 -r @- > /dev/null 2>&1)
  jj_change "$d" "feat: after nine"
}

echo "jj repo at v0.9.0: prepare bumps to v0.10.0"
tagged_repo at-nine
run_task "$d" prepare COG="${FAKES}/cog"
check_eq "prepare succeeds" 0 "${STATUS}"
check_lacks "not a first release" "first release" "${OUT}"
check_eq "bumped from v0.9.0" "chore(release): v0.10.0" "$(description "$d")"
check_eq "one 0.10.0 section" 1 "$(headings "$d" 0.10.0)"
check_eq "the old 0.1.0 section once" 1 "$(headings "$d" 0.1.0)"

echo "jj repo with only non-release v tags: a first release"
new_remote no-release
d="${TMP}/no-release"; new_jj_repo "$d" example.com/norelease
(cd "$d" && jj tag set vendor-sync sub/v1.0.0 -r main > /dev/null 2>&1)
jj_change "$d" "feat: more"
run_task "$d" prepare COG="${FAKES}/cog"
check_eq "prepare succeeds" 0 "${STATUS}"
check_contains "first release" "first release" "${OUT}"
check_eq "v0.1.0" "chore(release): v0.1.0" "$(description "$d")"

echo "jj tag list fails: prepare stops with jj's message and writes nothing"
tagged_repo list-fails
wrap_jj '  echo "Error: Failed to parse name pattern: Syntax error" >&2; exit 1'
run_task "$d" prepare COG="${FAKES}/cog" PATH="${WRAP}:${PATH}"
check_eq "prepare fails" 1 "${STATUS}"
check_contains "jj's own message" "Failed to parse name pattern" "${OUT}"
check_contains "says what failed" "jj tag list failed" "${OUT}"
check_lacks "not a first release" "first release" "${OUT}"
check_eq "no changelog written" "" "$(ls "$d/CHANGELOG.md" 2>/dev/null)"
check_eq "commit not described" "" "$(description "$d")"

echo "older jj, pattern split at the colon: the tags are still found"
tagged_repo old-jj
# shellcheck disable=SC2016 # expanded by the wrapper, not here
wrap_jj '  [[ "$3" == *\"* ]] && exit 0  # a quote matches nothing literally'
run_task "$d" prepare COG="${FAKES}/cog" PATH="${WRAP}:${PATH}"
check_eq "prepare succeeds" 0 "${STATUS}"
check_lacks "not a first release" "first release" "${OUT}"
check_eq "bumped from v0.9.0" "chore(release): v0.10.0" "$(description "$d")"

finish
