#!/usr/bin/env bash
# The module set and the remote decide the shape of a release, with no switch.
#
#   one module, any remote      one root tag, nothing pinned, no go.work edit,
#                               no proxy wait, no go.sum tidy
#   several modules             per-module tags and pinned intra-repo requires
#   github.com origin           gh writes the release notes; with several
#                               modules the proxy wait and the tidy follow
#   any other origin            gh is never called
#
# Each case runs the real prepare and push into a bare repository standing in
# for origin. A github.com origin is a bare repository under a directory named
# github.com, which is all the URL match looks at, so nothing leaves the
# machine. (A url.insteadOf rewrite would not do: jj and git both show origin
# with the rewrite applied.) go is wrapped: the
# commands that would reach the proxy are recorded and faked, the rest run.
set -uo pipefail
# shellcheck source=_release_helpers.bash
source "$(dirname "$0")/_release_helpers.bash"
require jj git-cliff go
fake cog

REAL_GO=$(PATH="${PATH#"${FAKES}:"}" command -v go)
cat > "${FAKES}/go" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "mod download" | "mod tidy" | "work sync") echo "go \$*" >> "\${CALLS}"; exit 0 ;;
esac
exec "${REAL_GO}" "\$@"
EOF
chmod +x "${FAKES}/go"

# gh as a GitHub with no release yet: view fails, create and edit succeed.
cat > "${FAKES}/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "${CALLS}"
[[ "$1 $2" == "release view" ]] && exit 1
exit 0
EOF
chmod +x "${FAKES}/gh"

remote_tags() { git --git-dir="${REMOTE}" tag -l | sort | tr '\n' ' '; }
calls_of() { grep -c "^$1" "${CALLS}" || true; }

# A second module under sub/ that requires the root one, joined by a go.work.
add_sub_module() { # dir root-module
  mkdir -p "$1/sub"
  printf 'module %s/sub\n\ngo 1.21\n\nrequire (\n\t%s v0.0.0\n)\n\nreplace %s => ../\n' "$2" "$2" "$2" > "$1/sub/go.mod"
  printf 'go 1.21\n\nuse (\n\t.\n\t./sub\n)\n' > "$1/go.work"
}

echo "jj, one module, a non-GitHub origin"
new_remote single
d="${TMP}/single"; new_jj_repo "$d" example.com/single
jj_change "$d" "feat: thing"
run_task "$d" prepare
check_eq "prepare succeeds" 0 "${STATUS}"
check_contains "says one tag" "Single module" "${OUT}"
check_eq "go.mod untouched" "" "$(cd "$d" && jj diff -r @ --summary -- go.mod)"
: > "${CALLS}"
run_task "$d" push usage_yes=true
check_eq "push succeeds" 0 "${STATUS}"; [[ ${STATUS} -eq 0 ]] || printf "%s\n" "${OUT}" | tail -15
check_eq "only the root tag" "v0.1.0 " "$(remote_tags)"
check_eq "main pushed" "$(cd "$d" && jj log -r 'v0.1.0' --no-graph -T commit_id)" "$(git --git-dir="${REMOTE}" rev-parse main)"
check_eq "gh never called" 0 "$(calls_of gh)"
check_eq "no proxy wait" 0 "$(calls_of 'go mod download')"
check_eq "no tidy" 0 "$(calls_of 'go mod tidy')"
check_contains "says why no notes" "not on github.com" "${OUT}"
check_contains "says why no tidy" "single module" "${OUT}"
check_contains "complete" "is complete" "${OUT}"

echo "post-tidy is a no-op there"
run_task "$d" post-tidy
check_eq "post-tidy succeeds" 0 "${STATUS}"
check_contains "post-tidy says why" "Nothing to do" "${OUT}"
check_eq "post-tidy waits for nothing" 0 "$(calls_of 'go mod download')"

echo "DEVKIT_POST_TIDY=1 forces the tidy back on"
run_task "$d" push usage_dry_run=true DEVKIT_POST_TIDY=1
check_contains "dry run would wait" "Would wait for the proxy" "${OUT}"

echo "jj, one module plus a go.work naming a sibling checkout"
new_remote override
d="${TMP}/override"; new_jj_repo "$d" example.com/override
mkdir -p "${TMP}/sibling"; printf 'module example.com/sibling\n\ngo 1.21\n' > "${TMP}/sibling/go.mod"
printf 'go 1.21\n\nuse (\n\t.\n\t../sibling\n)\n' > "$d/go.work"
(cd "$d" && echo /go.work > .gitignore && jj commit -m "chore: ignore go.work" > /dev/null 2>&1)
run_task "$d" prepare
check_eq "prepare succeeds" 0 "${STATUS}"
check_contains "still one module" "Single module" "${OUT}"
check_lacks "go.work not edited" "go.work updated" "${OUT}"

echo "jj, two modules, a non-GitHub origin"
new_remote multi
d="${TMP}/multi"; new_jj_repo "$d" example.com/multi
add_sub_module "$d" example.com/multi
jj_change "$d" "feat: sub module"
run_task "$d" prepare
check_eq "prepare succeeds" 0 "${STATUS}"
check_contains "pins the require" "example.com/multi v0.1.0" "$(cat "$d/sub/go.mod")"
check_lacks "drops the replace" "replace" "$(cat "$d/sub/go.mod")"
check_contains "pins go.work" "replace example.com/multi v0.1.0 => ." "$(cat "$d/go.work")"
: > "${CALLS}"
run_task "$d" push usage_yes=true
check_eq "push succeeds" 0 "${STATUS}"; [[ ${STATUS} -eq 0 ]] || printf "%s\n" "${OUT}" | tail -15
check_eq "root and module tags" "sub/v0.1.0 v0.1.0 " "$(remote_tags)"
check_eq "gh never called" 0 "$(calls_of gh)"
check_eq "no proxy wait off GitHub" 0 "$(calls_of 'go mod download')"
check_contains "says why no tidy" "public proxy cannot serve it" "${OUT}"

echo "jj, two modules, a github.com origin"
new_remote github.com/test/gh-multi
d="${TMP}/gh-multi"; new_jj_repo "$d" example.com/ghmulti
add_sub_module "$d" example.com/ghmulti
jj_change "$d" "feat: sub module"
run_task "$d" prepare
check_eq "prepare succeeds" 0 "${STATUS}"
: > "${CALLS}"
run_task "$d" push usage_yes=true
check_eq "push succeeds" 0 "${STATUS}"; [[ ${STATUS} -eq 0 ]] || printf "%s\n" "${OUT}" | tail -15
check_eq "root and module tags" "sub/v0.1.0 v0.1.0 " "$(remote_tags)"
check_contains "gh creates the release" "gh release create v0.1.0" "$(cat "${CALLS}")"
check_eq "waits for the proxy" 1 "$(calls_of 'go mod download')"
check_eq "tidies both modules" 2 "$(calls_of 'go mod tidy')"
check_eq "go.sum commit pushed" "chore: update go.sum after v0.1.0" "$(git --git-dir="${REMOTE}" log -1 --format=%s main)"

echo "jj, one module, a github.com origin"
new_remote github.com/test/gh-single
d="${TMP}/gh-single"; new_jj_repo "$d" example.com/ghsingle
jj_change "$d" "feat: thing"
run_task "$d" prepare
: > "${CALLS}"
run_task "$d" push usage_yes=true
check_eq "push succeeds" 0 "${STATUS}"; [[ ${STATUS} -eq 0 ]] || printf "%s\n" "${OUT}" | tail -15
check_contains "gh creates the release" "gh release create v0.1.0" "$(cat "${CALLS}")"
check_eq "no proxy wait for one module" 0 "$(calls_of 'go mod download')"
check_eq "only the root tag" "v0.1.0 " "$(remote_tags)"

echo "git, one module, a non-GitHub origin"
new_remote git-single
d="${TMP}/git-single"; new_git_repo "$d" example.com/gitsingle
git_change "$d" "feat: thing"
run_task "$d" prepare
check_eq "prepare succeeds" 0 "${STATUS}"
: > "${CALLS}"
run_task "$d" push usage_yes=true
check_eq "push succeeds" 0 "${STATUS}"; [[ ${STATUS} -eq 0 ]] || printf "%s\n" "${OUT}" | tail -15
check_eq "only the root tag" "v0.1.0 " "$(remote_tags)"
check_eq "release commit pushed" "chore(release): v0.1.0" "$(git --git-dir="${REMOTE}" log -1 --format=%s main)"
check_eq "gh never called" 0 "$(calls_of gh)"
check_eq "no proxy wait" 0 "$(calls_of 'go mod download')"

finish
