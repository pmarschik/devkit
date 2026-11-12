# shellcheck shell=bash
# Shared setup for the release task tests. Source it; do not run it.
#
# Every test builds its own throwaway jj and git repositories under one temp
# directory, with a bare repository standing in for the remote, and never
# reads the repository it runs in. The user's jj and git configs stay out of
# it: no signing prompts, no hooks, no global settings that change what a
# fresh repository looks like.
#
# TASKS overrides the directory holding the release tasks, which is how a
# mutation proof runs a modified copy.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASKS="${TASKS:-${ROOT}/mise/go/release}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/devkit-release-test.XXXXXX")
TMP=$(cd "${TMP}" && pwd -P)
trap 'rm -rf "${TMP}"' EXIT

export JJ_CONFIG="${TMP}/jj-config.toml"
cat > "${JJ_CONFIG}" <<'EOF'
[user]
name = "test"
email = "test@example.invalid"
EOF
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig" GIT_CONFIG_NOSYSTEM=1
cat > "${GIT_CONFIG_GLOBAL}" <<'EOF'
[user]
	name = test
	email = test@example.invalid
[init]
	defaultBranch = main
EOF
export GOTOOLCHAIN=local GOPROXY=off GOFLAGS=
unset GOWORK DEVKIT_NON_INTERACTIVE DEVKIT_TAG_BATCH DEVKIT_POST_TIDY

# Fakes go first on PATH. Each one appends its arguments to ${CALLS}.
FAKES="${TMP}/bin"
CALLS="${TMP}/calls"
mkdir -p "${FAKES}"
: > "${CALLS}"
export PATH="${FAKES}:${PATH}" CALLS

# A fake that only records: fake <name> [exit status]
fake() {
  cat > "${FAKES}/$1" <<EOF
#!/usr/bin/env bash
echo "$1 \$*" >> "\${CALLS}"
exit ${2:-0}
EOF
  chmod +x "${FAKES}/$1"
}

# hk and gh are never the real ones in a test: hk would run the repo's whole
# hook suite and gh would talk to GitHub.
fake hk
fake gh 1

require() {
  local tool
  for tool in "$@"; do
    command -v "${tool}" > /dev/null || { echo "  skip: ${tool} is not installed"; exit 0; }
  done
}

failures=0
fail() { echo "  FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "  ok:   $*"; }
check_eq() { # name expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
check_contains() { # name needle haystack
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1 ('$2' not in output)"; printf '%s\n' "$3" | sed 's/^/        | /'; fi
}
check_lacks() { # name needle haystack
  if [[ "$3" != *"$2"* ]]; then pass "$1"; else fail "$1 ('$2' in output)"; printf '%s\n' "$3" | sed 's/^/        | /'; fi
}
finish() {
  echo ""
  if [[ ${failures} -gt 0 ]]; then
    echo "${failures} failure(s)"
    exit 1
  fi
  echo "all passed"
}

# The git-cliff config the consumers use, trimmed to what the tasks rely on:
# the tag message as the release headline, and only root tags as releases.
write_cliff_config() { # dir
  mkdir -p "$1/.config"
  cat > "$1/.config/cliff.toml" <<'EOF'
[changelog]
body = """
{% if version %}\
    ## [{{ version | trim_start_matches(pat="v") }}] - {{ timestamp | date(format="%Y-%m-%d") }}
{% else %}\
    ## Unreleased
{% endif %}\
{% if message %}

{{ message }}
{% endif %}\
{% for group, commits in commits | group_by(attribute="group") %}

### {{ group | striptags | trim | upper_first }}
{% for commit in commits %}
- {{ commit.message | upper_first }}
{%- endfor %}
{% endfor %}
"""

[git]
commit_parsers = [
  { message = "^feat", group = "Features" },
  { message = "^fix", group = "Bug Fixes" },
  { message = "^chore\\(release\\)", skip = true },
  { message = ".*", group = "Other" },
]
tag_pattern = "^v[0-9]"
EOF
}

# A bare repository as origin: new_remote <name> sets REMOTE to its path.
new_remote() {
  REMOTE="${TMP}/$1.git"
  git init -q --bare "${REMOTE}"
}

# A colocated jj repository with one Go module at the root, an origin, a
# cliff config and a pushed main: new_jj_repo <dir> <module path>
new_jj_repo() {
  local dir="$1" mod="$2"
  jj git init --colocate "${dir}" > /dev/null 2>&1
  write_cliff_config "${dir}"
  printf 'module %s\n\ngo 1.21\n' "${mod}" > "${dir}/go.mod"
  (
    cd "${dir}" || exit 1
    jj git remote add origin "${REMOTE}"
    jj commit -m "feat: initial" > /dev/null 2>&1
    jj bookmark set main -r @- > /dev/null 2>&1
    jj git push --bookmark main > /dev/null 2>&1
  )
}

# The same as a plain git repository: new_git_repo <dir> <module path>
new_git_repo() {
  local dir="$1" mod="$2"
  git init -q "${dir}"
  write_cliff_config "${dir}"
  printf 'module %s\n\ngo 1.21\n' "${mod}" > "${dir}/go.mod"
  git -C "${dir}" add -A
  git -C "${dir}" commit -q -m "feat: initial"
  git -C "${dir}" remote add origin "${REMOTE}"
  git -C "${dir}" push -q origin main 2> /dev/null
}

# Commit a change with a message, in whichever VCS the repo uses.
jj_change() { # dir message
  (cd "$1" && echo "$2" >> changes.txt && jj commit -m "$2" > /dev/null 2>&1)
}
git_change() { # dir message
  echo "$2" >> "$1/changes.txt"
  git -C "$1" add changes.txt
  git -C "$1" commit -q -m "$2"
}

# Run a release task in a directory: run_task <dir> <task> [VAR=value...]
# Output (both streams) lands in OUT, the status in STATUS. stdin is never a
# terminal here, which is the non-interactive case.
run_task() {
  local dir="$1" task="$2"
  shift 2
  # shellcheck disable=SC2034 # read by the test that sourced this file
  OUT=$(cd "${dir}" && env "$@" bash "${TASKS}/${task}" < /dev/null 2>&1)
  # shellcheck disable=SC2034
  STATUS=$?
}
