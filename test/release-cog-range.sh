#!/usr/bin/env bash
# The conventional-commit check covers the release being prepared and nothing
# older, and a jj repo that already has tags is never told it is cutting its
# first release.
#
# Two halves. A fake cog records the arguments cog-check hands it, which pins
# the range. The real cocogitto then proves the range means what it says: a
# non-conventional commit from before the last tag passes, one after it fails,
# and with no tag at all the old one fails too. The real half is skipped when
# cocogitto 7.0.0 is not installed.
set -uo pipefail
# shellcheck source=_release_helpers.bash
source "$(dirname "$0")/_release_helpers.bash"
require jj git-cliff

cat > "${FAKES}/cog" <<'EOF'
#!/usr/bin/env bash
echo "cog $*" >> "${CALLS}"
EOF
chmod +x "${FAKES}/cog"

cog_args() { grep '^cog ' "${CALLS}" | tail -1; }

echo "no v* tag: cog checks the whole history"
d="${TMP}/no-tag"; git init -q "$d"
git_change "$d" "old non-conventional commit"
: > "${CALLS}"
(cd "$d" && COG="${FAKES}/cog" bash "${TASKS}/cog-check") 2>"${TMP}/stderr"
check_eq "no range" "cog check" "$(cog_args)"
check_contains "says so" "no v* tag yet" "$(cat "${TMP}/stderr")"

echo "tags: the range starts at the newest reachable vX.Y.Z"
d="${TMP}/tags"; git init -q "$d"
git_change "$d" "feat: one"; git -C "$d" tag v1.9.0
git_change "$d" "feat: two"; git -C "$d" tag v1.10.0
git -C "$d" tag v1                 # a moving major tag is not a release
git -C "$d" tag sub/v9.0.0         # nor is a module tag
git_change "$d" "fix: three"
git -C "$d" checkout -q -b side HEAD~1
git_change "$d" "feat: elsewhere"; git -C "$d" tag v3.0.0
git -C "$d" checkout -q main       # v3.0.0 is not reachable from here
: > "${CALLS}"
(cd "$d" && COG="${FAKES}/cog" bash "${TASKS}/cog-check") 2>"${TMP}/stderr"
check_eq "range since v1.10.0" "cog check v1.10.0..HEAD" "$(cog_args)"
check_contains "names the tag" "since v1.10.0" "$(cat "${TMP}/stderr")"

echo "explicit arguments go to cog unchanged"
: > "${CALLS}"
(cd "$d" && COG="${FAKES}/cog" bash "${TASKS}/cog-check" --from-latest-tag) 2>/dev/null
check_eq "passthrough" "cog check --from-latest-tag" "$(cog_args)"

echo "jj repo with v2.0.0: prepare bumps from it, not to a first release"
new_remote jj-tagged
d="${TMP}/jj-tagged"; new_jj_repo "$d" example.com/jjtagged
(cd "$d" && jj tag set v2.0.0 -r main > /dev/null 2>&1)
jj_change "$d" "feat: after two"
: > "${CALLS}"
run_task "$d" prepare COG="${FAKES}/cog"
check_eq "prepare succeeds" 0 "${STATUS}"
check_lacks "not a first release" "first release" "${OUT}"
check_eq "bumped from v2.0.0" "chore(release): v2.1.0" "$(cd "$d" && jj log -r @ --no-graph -T 'description.first_line()')"
check_eq "cog got the release range" "cog check v2.0.0..HEAD" "$(cog_args)"
check_eq "nothing pushed" "$(git --git-dir="${REMOTE}" rev-parse main)" "$(cd "$d" && jj log -r 'main@origin' --no-graph -T commit_id)"

echo "prepare stops on a failing cog check"
cat > "${TMP}/cog-fails" <<'EOF'
#!/usr/bin/env bash
echo "cog $*" >> "${CALLS}"
exit 1
EOF
chmod +x "${TMP}/cog-fails"
(cd "$d" && jj new > /dev/null 2>&1)
jj_change "$d" "feat: more"
run_task "$d" prepare COG="${TMP}/cog-fails"
check_eq "prepare fails" 1 "${STATUS}"
check_contains "says why" "cog check failed" "${OUT}"

# ── the real cocogitto ────────────────────────────────────────────────────────
# Looked up without the fakes on PATH, or it finds the fake cog.
REAL_COG="${REAL_COG:-$(cd "${TMP}" && PATH="${PATH#"${FAKES}:"}" mise x cocogitto@7.0.0 -- sh -c 'command -v cog' 2>/dev/null || true)}"
[[ "${REAL_COG}" == "${FAKES}/"* ]] && REAL_COG=""
if [[ -z "${REAL_COG}" ]]; then
  echo "  skip: cocogitto 7.0.0 not installed, real-cog cases not run"
else
  echo "real cog: an old non-conventional commit before the tag passes"
  d="${TMP}/real"; git init -q "$d"
  git_change "$d" "old non-conventional commit"
  git_change "$d" "feat: one"
  (cd "$d" && COG="${REAL_COG}" bash "${TASKS}/cog-check") > /dev/null 2>&1
  check_eq "no tag: whole history fails" 1 "$?"
  git -C "$d" tag v1.0.0
  git_change "$d" "fix: two"
  (cd "$d" && COG="${REAL_COG}" bash "${TASKS}/cog-check") > /dev/null 2>&1
  check_eq "tagged: passes" 0 "$?"
  git_change "$d" "another bad one"
  (cd "$d" && COG="${REAL_COG}" bash "${TASKS}/cog-check") > "${TMP}/real-out" 2>&1
  check_eq "bad commit after the tag fails" 1 "$?"
  check_contains "names the new commit" "another bad one" "$(cat "${TMP}/real-out")"
  check_lacks "not the old one" "old non-conventional" "$(cat "${TMP}/real-out")"
fi

finish
