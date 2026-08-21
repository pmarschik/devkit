#!/usr/bin/env bash
# Shared helpers for every task in this include. Source this file; do not
# execute it directly. Tasks at the include root reach it as
# "$(dirname "$0")/_lib.sh" and tasks in release/ as "$(dirname "$0")/../_lib.sh".
#
# The release/* tasks release a Go workspace repo: one commit carries the root
# tag vX.Y.Z and a <subdir>/vX.Y.Z tag for every other module in go.work. A
# module reaches its users through the Go module proxy, so the release is
# finished when the tags are on GitHub and the proxy serves them. GoReleaser,
# if the repo runs it, only adds binaries on top of that.
#
# What the consuming repo must provide:
#   go.work                 the module list (discover_modules reads it)
#   .config/dprint.json     extending devkit's dprint/go.json
#   .config/golangci.yml    the linter config fmt and lint pass with -c
#   .config/cliff.toml      with tag_pattern = "^v[0-9]" so a submodule tag
#                           never wins the "latest tag" race (release only)
#   CHANGELOG.md            written by git cliff, formatted by hk (release only)
#   gh                      authenticated, for the GitHub release (release only)
#
# See the devkit README for the include line and the pinning policy.

bold='\033[1m'; cyan='\033[36m'; green='\033[32m'; yellow='\033[33m'; red='\033[31m'; reset='\033[0m'
info()    { echo -e "  ${cyan}${bold}❯${reset}  $*"; }
success() { echo -e "  ${green}✔${reset}  $*"; }
warn()    { echo -e "  ${yellow}⚠${reset}  $*"; }
die()     { echo -e "  ${red}✖${reset}  $*" >&2; exit 1; }
confirm() {
  [[ -t 0 ]] || return 0  # non-interactive: proceed automatically
  echo -e "  ${yellow}${bold}?${reset}  $1 ${bold}[y/N]${reset} \c"
  read -r answer
  [[ "${answer,,}" == "y" ]]
}

# Sets VCS=jj|git and JJ_HEAD (commit id for jj, empty for git).
detect_vcs() {
  if jj root &>/dev/null; then
    VCS=jj
    JJ_HEAD=$(jj log -r @ --no-graph --template 'commit_id' 2>/dev/null || true)
  elif git rev-parse --git-dir &>/dev/null; then
    VCS=git
    # shellcheck disable=SC2034 # consumed by scripts after sourcing _lib.sh
    JJ_HEAD=""
  else
    die "not in a git or jj repository"
  fi
}

# Fast-forward the main bookmark onto rev (jj only).
#
# Refuses to move it backwards or sideways: main sitting somewhere that is not
# an ancestor of the release means either the release commit is not on main or
# main has moved on since, and dragging the bookmark would paper over both. The
# tags still need pushing either way, so this warns rather than aborting.
advance_main_bookmark() {
  local rev="$1"
  if ! jj bookmark list main 2>/dev/null | grep -q '^main'; then
    jj bookmark set main -r "${rev}"
  elif jj log -r "main & ::${rev}" --no-graph --template 'commit_id' 2>/dev/null | grep -q .; then
    jj bookmark set main -r "${rev}"
  else
    warn "main is not an ancestor of ${rev} — leaving the bookmark where it is"
    return 0
  fi
  success "main → ${rev}"
}

# Echo the version a `chore(release): vX.Y.Z` commit was prepared for, empty if
# $1 (default @) is not one. jj only: release:prepare describes the commit, so
# the description — not git cliff, which would bump past it — is what push reads.
release_version_at() {
  jj log -r "${1:-@}" --no-graph --template 'description' 2>/dev/null \
    | sed -n '1s/^chore(release): \(v[0-9].*\)$/\1/p'
}

expected_release_tags() {
  local version="$1" mod
  RELEASE_TAGS=("${version}")
  for mod in "${MONOREPO_MODULES[@]}"; do
    [[ "$mod" == "${ROOT_MODULE}" ]] && continue
    RELEASE_TAGS+=("${mod#"${ROOT_MODULE}"/}/${version}")
  done
}

# Tag ${2} with vX.Y.Z for the root module and <subdir>/vX.Y.Z for every other
# workspace module. Every published module needs its own tag: `go get` resolves
# a submodule's version from the tag that carries its subdirectory, so a repo
# with ten modules writes ten tags onto one commit.
#
# release:push calls this, never release:prepare. Under jj a tag makes its
# commit immutable, which pushes the working copy onto a fresh empty child, so
# tagging during prepare would move the reviewer off the very commit they were
# asked to review and leave `jj diff` empty.
#
# Re-runnable: tags of the same name move onto ${2}, which covers a push that
# failed after tagging.
# Needs discover_modules to have run.
create_release_tags() {
  local version="$1" commit="$2" name
  expected_release_tags "${version}"

  if [[ "${VCS}" == "jj" ]]; then
    jj tag set "${RELEASE_TAGS[@]}" -r "${commit}" --allow-move
    jj tag track "${RELEASE_TAGS[@]}" --remote origin
  else
    git tag --no-sign -f -a "${version}" -m "${HIGHLIGHTS:-${version}}" "${commit}"
    for name in "${RELEASE_TAGS[@]:1}"; do
      git tag --no-sign -f "${name}" "${commit}"
    done
  fi
  success "Tagged: ${RELEASE_TAGS[*]}"
}

# Verify that release:prepare has already put the jj release state where push
# will publish it: the main bookmark has to sit on the release commit.
#
# The release tags are deliberately not checked, because push creates them a
# moment later. Only a tag left on the wrong commit by an earlier failed push
# matters, and create_release_tags moves those with --allow-move.
verify_jj_prepared_release() {
  local commit="$1" main_commit

  main_commit=$(jj log -r main --no-graph --template 'commit_id' 2>/dev/null || true)
  [[ "${main_commit}" == "${commit}" ]] \
    || die "main is not on the prepared release commit — run 'mise run release:prepare' again"
}

is_release_prepare_path() {
  case "$1" in
    CHANGELOG.md|go.mod|go.work|*/go.mod) return 0 ;;
    *) return 1 ;;
  esac
}

release_prepare_paths() {
  local dir modfile
  RELEASE_PREPARE_PATHS=(CHANGELOG.md go.mod)
  [[ -f go.work ]] && RELEASE_PREPARE_PATHS+=(go.work)
  for dir in "${MODULE_DIRS[@]}"; do
    [[ "$dir" == "." ]] && continue
    modfile="${dir}/go.mod"
    [[ -f "${modfile}" ]] && RELEASE_PREPARE_PATHS+=("${modfile}")
  done
}

stage_release_prepare_changes() {
  release_prepare_paths
  git add "${RELEASE_PREPARE_PATHS[@]}"
}

# Block until the module proxy serves ROOT_MODULE@$1, or return 1 after $2
# seconds (default 120). Callers decide whether a timeout is fatal.
wait_for_proxy() {
  local version="$1" max_wait="${2:-120}" elapsed=0
  until GOWORK=off GONOSUMDB="${ROOT_MODULE}" go mod download "${ROOT_MODULE}@${version}" 2>/dev/null; do
    elapsed=$((elapsed + 5))
    [[ ${elapsed} -ge ${max_wait} ]] && return 1
    sleep 5
  done
}

# Re-tidy every module's go.sum against the published version. GOWORK=off so Go
# sees each module's cross-deps as external and writes real checksums for them;
# inside the workspace they resolve locally and never get one. Needs
# discover_modules to have run.
tidy_go_sums() {
  info "Syncing go.work.sum…"
  GONOSUMDB="${ROOT_MODULE}" go work sync
  success "go.work.sum synced"

  info "Tidying go.sum files…"
  for dir in "${MODULE_DIRS[@]}"; do
    pushd "$dir" > /dev/null || return
    GOWORK=off GONOSUMDB="${ROOT_MODULE}" go mod tidy
    popd > /dev/null || return
  done
  success "go.sum files updated"
}

# Echo every module directory in go.work, one per line, as it is written there
# ("." for the root, "./sub/dir" for the rest).
#
# No exclusions, unlike discover_modules: fmt, lint, test and tidy cover the
# example modules too, and dropping them here would quietly stop linting and
# testing code that a reader expects to be covered.
workspace_module_dirs() {
  go work edit -json | sed -n 's/.*"DiskPath": *"\(.*\)".*/\1/p'
}

# Populate MONOREPO_MODULES (module paths) and MODULE_DIRS (relative dirs) from go.work.
# Also sets ROOT_MODULE to the root module path.
# Paths whose directory component matches EXCLUDE_GLOB (default: "example/*") are skipped.
discover_modules() {
  local exclude="${1:-example/*}"
  ROOT_MODULE=$(grep '^module ' go.mod | awk '{print $2}')
  MONOREPO_MODULES=()
  MODULE_DIRS=()

  while IFS= read -r entry; do
    local dir="${entry#./}"
    [[ -z "$dir" ]] && dir="."
    # shellcheck disable=SC2254
    case "$dir" in $exclude) continue ;; esac

    local modfile="$dir/go.mod"
    [[ "$dir" == "." ]] && modfile="go.mod"
    local mod
    mod=$(grep '^module ' "$modfile" 2>/dev/null | awk '{print $2}') || continue
    [[ -z "$mod" ]] && continue

    MONOREPO_MODULES+=("$mod")
    MODULE_DIRS+=("$dir")
  done < <(go work edit -json | grep '"DiskPath"' | sed 's/.*"DiskPath": *"\(.*\)".*/\1/')
}
