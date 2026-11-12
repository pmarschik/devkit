#!/usr/bin/env bash
# Tests for mise/go/release/cog-check against throwaway git repositories.
#
# A fake cog stands in for cocogitto: it records what it saw of the
# extensions.relativeWorktrees key while it ran, then exits or sleeps as told.
# The real cocogitto is exercised by hand (see docs/go/RELEASING.md), because
# the failure it works around needs libgit2 1.9.2, not a fake.
#
# CHECK overrides the script under test, which is how the mutation proof runs
# a copy with the restore trap removed.
set -uo pipefail
# Job control: a background job then gets its own process group and keeps
# SIGINT, which a non-interactive shell would otherwise ignore for it and the
# script under test could not trap.
set -m

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK="${CHECK:-${ROOT}/mise/go/release/cog-check}"
KEY="extensions.relativeWorktrees"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cog-check-test.XXXXXX")
trap 'rm -rf "${TMP}"' EXIT

FAKE="${TMP}/bin/cog"
mkdir -p "${TMP}/bin"
cat > "${FAKE}" <<'EOF'
#!/usr/bin/env bash
# Seen while running: the key's value, or <absent>.
git config --local --get extensions.relativeWorktrees > "${FAKE_COG_SEEN}" 2>/dev/null \
  || echo "<absent>" > "${FAKE_COG_SEEN}"
echo "$*" > "${FAKE_COG_SEEN}.args"
[[ -n "${FAKE_COG_SLEEP:-}" ]] && { touch "${FAKE_COG_SEEN}.started"; sleep "${FAKE_COG_SLEEP}"; }
exit "${FAKE_COG_EXIT:-0}"
EOF
chmod +x "${FAKE}"
export COG="${FAKE}"

# Keep the user's git config out of it: no signing prompts, no hooks, no
# global settings that would change what a fresh repo looks like.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

failures=0
fail() { echo "  FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "  ok:   $*"; }
check_eq() { # name expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# A repo shaped like the real ones: the ansible header, format version 1, the
# extension set (or not), and other keys that must survive untouched.
new_repo() { # dir [value]
  local dir="$1"
  git init -q "${dir}"
  git -C "${dir}" commit -q --allow-empty -m "feat: initial"
  {
    printf '#\n# WARNING: This file is managed by ansible, edit the template directly in ansible\n#\n'
    cat "${dir}/.git/config"
  } > "${dir}/.git/config.new"
  mv "${dir}/.git/config.new" "${dir}/.git/config"
  git -C "${dir}" config --local core.repositoryformatversion 1
  git -C "${dir}" config --local extensions.worktreeConfig true
  if [[ $# -ge 2 ]]; then
    git -C "${dir}" config --local "${KEY}" "$2"
  fi
}

value_of() { git -C "$1" config --local --get "${KEY}" 2>/dev/null || echo "<absent>"; }
others_of() { git -C "$1" config --local --list | grep -vi "^${KEY}=" | sort; }
header_of() { head -3 "$1/.git/config"; }

# Run the check in $1 and wait until the fake cog is running, then send $2 to
# the target ($3: group or script), wait, and leave the exit status in
# STATUS. Not called through $(...): job control is off in a subshell.
interrupt() { # dir signal target
  local dir="$1" sig="$2" target="$3" pid
  (cd "${dir}" && FAKE_COG_SLEEP=5 exec "${CHECK}") 2>"${TMP}/stderr" &
  pid=$!
  for _ in $(seq 50); do [[ -f "${FAKE_COG_SEEN}.started" ]] && break; sleep 0.1; done
  if [[ "${target}" == "group" ]]; then kill "-${sig}" -- "-${pid}"; else kill "-${sig}" "${pid}"; fi
  wait "${pid}"
  STATUS=$?
}

# Sets d to a fresh case directory. Not called through $(...), so the export
# reaches the cases.
case_dir() { rm -f "${TMP}"/seen*; export FAKE_COG_SEEN="${TMP}/seen"; d="${TMP}/$1"; }

echo "key set to true: unset while cog runs, restored after"
case_dir set-true; new_repo "$d" true
before_others=$(others_of "$d"); before_header=$(header_of "$d")
(cd "$d" && "${CHECK}" --from-latest-tag) 2>"${TMP}/stderr"; status=$?
check_eq "exit status" 0 "${status}"
check_eq "cog saw the key unset" "<absent>" "$(cat "${FAKE_COG_SEEN}")"
check_eq "cog got the arguments" "check --from-latest-tag" "$(cat "${FAKE_COG_SEEN}.args")"
check_eq "value restored" true "$(value_of "$d")"
check_eq "other keys untouched" "${before_others}" "$(others_of "$d")"
check_eq "ansible header kept" "${before_header}" "$(header_of "$d")"
check_eq "one stderr line" 1 "$(grep -c "${KEY} is unset while cog runs" "${TMP}/stderr")"
check_eq "lock released" no "$([[ -e "$d/.git/devkit-cog-check.lock" ]] && echo yes || echo no)"

echo "key set to another value: that exact value comes back"
case_dir set-false; new_repo "$d" false
(cd "$d" && "${CHECK}") 2>/dev/null
check_eq "value restored" false "$(value_of "$d")"

echo "key absent: config left byte for byte"
case_dir absent; new_repo "$d"
cp "$d/.git/config" "${TMP}/config.before"
(cd "$d" && "${CHECK}") 2>"${TMP}/stderr"; status=$?
check_eq "exit status" 0 "${status}"
check_eq "cog ran" "<absent>" "$(cat "${FAKE_COG_SEEN}")"
check_eq "config identical" same "$(cmp -s "${TMP}/config.before" "$d/.git/config" && echo same || echo changed)"
check_eq "no stderr line" 0 "$(grep -c "${KEY}" "${TMP}/stderr")"

echo "cog fails: its status propagates, value restored"
case_dir cog-fails; new_repo "$d" true
(cd "$d" && FAKE_COG_EXIT=3 "${CHECK}") 2>/dev/null; status=$?
check_eq "exit status" 3 "${status}"
check_eq "value restored" true "$(value_of "$d")"

echo "Ctrl-C (SIGINT to the process group) mid-check: value restored"
case_dir sigint; new_repo "$d" true
interrupt "$d" INT group; status=${STATUS}
check_eq "non-zero exit" yes "$([[ "${status}" -ne 0 ]] && echo yes || echo no)"
check_eq "cog was running with the key unset" "<absent>" "$(cat "${FAKE_COG_SEEN}")"
check_eq "value restored" true "$(value_of "$d")"
check_eq "lock released" no "$([[ -e "$d/.git/devkit-cog-check.lock" ]] && echo yes || echo no)"

echo "SIGTERM to the script alone mid-check: value restored"
case_dir sigterm; new_repo "$d" true
interrupt "$d" TERM script; status=${STATUS}
check_eq "non-zero exit" yes "$([[ "${status}" -ne 0 ]] && echo yes || echo no)"
check_eq "value restored" true "$(value_of "$d")"

echo "SIGHUP to the process group mid-check: value restored"
case_dir sighup; new_repo "$d" true
interrupt "$d" HUP group; status=${STATUS}
check_eq "non-zero exit" yes "$([[ "${status}" -ne 0 ]] && echo yes || echo no)"
check_eq "value restored" true "$(value_of "$d")"

echo "run from a linked worktree: the common config is the one edited"
case_dir worktree; new_repo "$d" true
git -C "$d" worktree add -q --relative-paths "${TMP}/worktree-linked" 2>/dev/null \
  || git -C "$d" worktree add -q "${TMP}/worktree-linked"
git -C "$d" config --local "${KEY}" true
(cd "${TMP}/worktree-linked" && "${CHECK}") 2>/dev/null; status=$?
check_eq "exit status" 0 "${status}"
check_eq "cog saw the key unset" "<absent>" "$(cat "${FAKE_COG_SEEN}")"
check_eq "value restored" true "$(value_of "$d")"

echo "two runs at once: the second waits, neither restores the wrong value"
case_dir concurrent; new_repo "$d" true
(cd "$d" && FAKE_COG_SLEEP=2 FAKE_COG_SEEN="${TMP}/seen-a" "${CHECK}") 2>/dev/null &
a=$!
for _ in $(seq 50); do [[ -f "${TMP}/seen-a.started" ]] && break; sleep 0.1; done
(cd "$d" && FAKE_COG_SEEN="${TMP}/seen-b" "${CHECK}") 2>"${TMP}/stderr-b" &
b=$!
wait "$a"; sa=$?
wait "$b"; sb=$?
check_eq "both succeed" "0 0" "${sa} ${sb}"
check_eq "second cog also saw the key unset" "<absent>" "$(cat "${TMP}/seen-b")"
# Only a second run that waited finds the key set again; one that slipped past
# the lock reads the first run's unset state and leaves the config alone.
check_eq "second run waited and found the key set" 1 "$(grep -c "${KEY} is unset while cog runs" "${TMP}/stderr-b")"
check_eq "value restored" true "$(value_of "$d")"

echo "stale lock from a killed run: refuse, touch nothing"
case_dir stale; new_repo "$d" true
mkdir "$d/.git/devkit-cog-check.lock"
sh -c 'echo $$' > "$d/.git/devkit-cog-check.lock/pid" # a pid that has exited
echo true > "$d/.git/devkit-cog-check.lock/value"
(cd "$d" && "${CHECK}") 2>"${TMP}/stderr"; status=$?
check_eq "exit status" 1 "${status}"
check_eq "cog never ran" no "$([[ -f "${FAKE_COG_SEEN}" ]] && echo yes || echo no)"
check_eq "says how to restore" 1 "$(grep -c "git config --local ${KEY} 'true'" "${TMP}/stderr")"
check_eq "value untouched" true "$(value_of "$d")"

echo "not a git repository: cog runs as is"
case_dir plain; mkdir -p "$d"
(cd "$d" && GIT_CEILING_DIRECTORIES="${TMP}" "${CHECK}") 2>/dev/null; status=$?
check_eq "exit status" 0 "${status}"
check_eq "cog ran" "check" "$(cat "${FAKE_COG_SEEN}.args")"

echo ""
if [[ ${failures} -gt 0 ]]; then
  echo "${failures} failure(s)"
  exit 1
fi
echo "all passed"
