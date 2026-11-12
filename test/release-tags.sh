#!/usr/bin/env bash
# The root tag carries the newest changelog section as its annotation, a
# regenerated changelog does not print that section twice, and signing follows
# the user's config: jj signs the release commit before the tag freezes it,
# git signs the tag when tag.gpgSign says so, and an unconfigured repo is never
# signed at all.
#
# The signing key is a throwaway ed25519 key made here, and every config the
# tasks read is the test's own; the user's keys and settings are never read.
set -uo pipefail
# shellcheck source=_release_helpers.bash
source "$(dirname "$0")/_release_helpers.bash"
require jj git-cliff go jq ssh-keygen
fake cog

KEY="${TMP}/signing-key"
ssh-keygen -q -t ed25519 -N '' -C test -f "${KEY}"

# The newest section of CHANGELOG.md as the test reads it, independently of
# the task's own helper: heading to the next heading, blank lines trimmed.
newest_section() { # file
  awk '/^## \[/{if(p) exit; p=1} p' "$1" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}
tag_message() { # tag — the annotation on the remote, header lines dropped
  git --git-dir="${REMOTE}" cat-file tag "$1" | sed '1,/^$/d' | sed '/^-----BEGIN SSH SIGNATURE-----$/,$d'
}
signed_commit() { # rev — "yes" when the remote's commit carries a signature
  if git --git-dir="${REMOTE}" cat-file commit "$1" | grep -q '^gpgsig'; then echo yes; else echo no; fi
}

echo "jj, unconfigured signing: annotated root tag, nothing signed"
new_remote plain
d="${TMP}/plain"; new_jj_repo "$d" example.com/plain
jj_change "$d" "feat: first thing"
run_task "$d" prepare usage_highlights="Big news"
check_eq "prepare succeeds" 0 "${STATUS}"
prepared=$(cd "$d" && jj log -r @ --no-graph -T commit_id)
run_task "$d" push usage_yes=true
check_eq "push succeeds" 0 "${STATUS}"
check_eq "root tag is an object" "tag" "$(git --git-dir="${REMOTE}" cat-file -t v0.1.0)"
check_eq "annotation is the newest section" "$(newest_section "$d/CHANGELOG.md")" "$(tag_message v0.1.0)"
check_contains "headings survive" "### Features" "$(tag_message v0.1.0)"
check_contains "highlights in it" "Big news" "$(tag_message v0.1.0)"
check_eq "tag on the prepared commit" "${prepared}" "$(git --git-dir="${REMOTE}" rev-parse 'v0.1.0^{commit}')"
check_lacks "no signing" "Signing the release commit" "${OUT}"
check_eq "commit unsigned" no "$(signed_commit v0.1.0)"

echo "jj, the next release regenerates the changelog without doubling it"
jj_change "$d" "feat: second thing"
run_task "$d" prepare usage_highlights="More news"
check_eq "prepare succeeds" 0 "${STATUS}"
log="$(cat "$d/CHANGELOG.md")"
check_eq "two release headings" 2 "$(grep -c '^## \[' "$d/CHANGELOG.md")"
check_eq "old highlight once" 1 "$(grep -c 'Big news' "$d/CHANGELOG.md")"
check_eq "new highlight once" 1 "$(grep -c 'More news' "$d/CHANGELOG.md")"
check_eq "two feature groups" 2 "$(grep -c '^### Features' "$d/CHANGELOG.md")"
check_contains "old entry kept" "First thing" "${log}"

echo "jj, signing configured: the release commit is signed before tagging"
new_remote signed
d="${TMP}/signed"; new_jj_repo "$d" example.com/signed
# Configured only now, so the commit already on origin went out unsigned.
cat >> "${JJ_CONFIG}" <<EOF
[signing]
backend = "ssh"
behavior = "drop"
key = "${KEY}"
[revsets]
git-sign-on-push = "~signed() & mine()"
EOF
jj_change "$d" "feat: thing"
run_task "$d" prepare
prepared=$(cd "$d" && jj log -r @ --no-graph -T commit_id)
run_task "$d" push usage_dry_run=true
check_contains "dry run says it would sign" "Would sign the release commit" "${OUT}"
check_eq "dry run signs nothing" "${prepared}" "$(cd "$d" && jj log -r main --no-graph -T commit_id)"
run_task "$d" push usage_yes=true
check_eq "push succeeds" 0 "${STATUS}"
check_contains "says it signs" "Signing the release commit" "${OUT}"
check_eq "tagged commit signed" yes "$(signed_commit 'v0.1.0^{commit}')"
check_eq "pushed main signed" yes "$(signed_commit main)"
check_eq "unpushed parent signed" yes "$(signed_commit main~1)"
check_eq "already pushed commit untouched" no "$(signed_commit main~2)"
check_eq "main is the tagged commit" "$(git --git-dir="${REMOTE}" rev-parse 'v0.1.0^{commit}')" "$(git --git-dir="${REMOTE}" rev-parse main)"
check_lacks "nothing skipped as immutable" "Skipped signing" "${OUT}"

echo "jj, backend set but no revset selecting the commit: not signed"
cat > "${JJ_CONFIG}" <<EOF
[user]
name = "test"
email = "test@example.invalid"
[signing]
backend = "ssh"
behavior = "drop"
key = "${KEY}"
EOF
new_remote norevset
d="${TMP}/norevset"; new_jj_repo "$d" example.com/norevset
jj_change "$d" "feat: thing"
run_task "$d" prepare
run_task "$d" push usage_yes=true
check_eq "push succeeds" 0 "${STATUS}"
check_eq "commit unsigned" no "$(signed_commit 'v0.1.0^{commit}')"

echo "git, tag.gpgSign: the root tag is signed and annotated, module tags are not"
git config --global gpg.format ssh
git config --global user.signingkey "${KEY}"
git config --global tag.gpgSign true
new_remote git-signed
d="${TMP}/git-signed"; new_git_repo "$d" example.com/gitsigned
mkdir -p "$d/sub"; printf 'module example.com/gitsigned/sub\n\ngo 1.21\n' > "$d/sub/go.mod"
printf 'go 1.21\n\nuse (\n\t.\n\t./sub\n)\n' > "$d/go.work"
git -C "$d" add -A && git -C "$d" commit -q -m "feat: sub"
run_task "$d" prepare
check_eq "prepare succeeds" 0 "${STATUS}"
run_task "$d" push usage_yes=true
check_eq "push succeeds" 0 "${STATUS}"
check_contains "root tag signed" "BEGIN SSH SIGNATURE" "$(git --git-dir="${REMOTE}" cat-file tag v0.1.0)"
check_eq "annotation is the newest section" "$(newest_section "$d/CHANGELOG.md")" "$(tag_message v0.1.0)"
check_eq "module tag lightweight" "commit" "$(git --git-dir="${REMOTE}" cat-file -t sub/v0.1.0)"

echo "git, no tag.gpgSign: the root tag is annotated and unsigned"
git config --global --unset tag.gpgSign
new_remote git-plain
d="${TMP}/git-plain"; new_git_repo "$d" example.com/gitplain
git_change "$d" "feat: thing"
run_task "$d" prepare
run_task "$d" push usage_yes=true
check_eq "push succeeds" 0 "${STATUS}"
check_eq "root tag is an object" "tag" "$(git --git-dir="${REMOTE}" cat-file -t v0.1.0)"
check_lacks "root tag unsigned" "BEGIN SSH SIGNATURE" "$(git --git-dir="${REMOTE}" cat-file tag v0.1.0)"

finish
