#!/usr/bin/env bash
# Shared helpers for every task in this include. Source this file; do not
# execute it directly. Tasks at the include root reach it as
# "$(dirname "$0")/_lib.sh" and tasks in release/ as "$(dirname "$0")/../_lib.sh".
#
# The release/* tasks release a Go repo: one commit carries the root tag vX.Y.Z
# and a <subdir>/vX.Y.Z tag for every other module in go.work. A module reaches
# its users through the Go module proxy, so a multi-module release on GitHub is
# finished when the tags are pushed and the proxy serves them. GoReleaser, if
# the repo runs it, only adds binaries on top of that.
#
# The module set decides the shape of the release, with no switch to set. A repo
# whose go.work lists more than one module of its own gets per-module tags, its
# intra-repo requires pinned in every go.mod and go.work, and — on github.com —
# the wait for the proxy and the go.sum tidy afterwards. A repo with a single
# module, at the root and with or without a go.work, gets the root tag alone:
# nothing to pin, no proxy to wait for, no go.sum to re-tidy. The GitHub
# release notes follow the remote rather than the module count: they are
# written for a github.com origin and skipped anywhere else, where the forge's
# own CI owns the release page.
#
# What the consuming repo must provide:
#   .config/dprint.json     extending devkit's dprint/go.json
#   .config/golangci.yml    the linter config fmt and lint pass with -c
#   .config/cliff.toml      with tag_pattern = "^v[0-9]" so a submodule tag
#                           never wins the "latest tag" race (release only)
#   CHANGELOG.md            written by git cliff, formatted by dprint with
#                           .config/dprint.json, or by hk without it (release only)
#   gh                      authenticated, for the GitHub release notes, on a
#                           github.com origin only (release only)
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
#
# The root tag is annotated with the newest CHANGELOG.md section, heading and
# all, so `git show vX.Y.Z` and any forge reading the tag show the release
# notes. --cleanup=verbatim keeps it whole: git's default cleanup takes every
# line starting with # for a comment and would strip the very headings. Whether
# the tag is signed is the user's tag.gpgSign — nothing here forces it either
# way. jj cannot write an annotated tag, so under jj `jj tag set` places every
# tag and git, in the backing repository, then replaces the root one with the
# annotated object at the same commit; jj imports it on its next command, and
# `jj git push --tag` sends the object.
#
# The module tags stay lightweight and unsigned (--no-sign): they exist so
# `go get` can find each module, carry no notes, and with tag.gpgSign set a
# lightweight tag would demand a message and a signature — ten of them, each a
# hardware-key touch, on one commit.
create_release_tags() {
  local version="$1" commit="$2" name notes
  expected_release_tags "${version}"

  notes=$(mktemp)
  changelog_section > "${notes}"
  [[ -s "${notes}" ]] || printf '%s\n' "${version}" > "${notes}"

  if [[ "${VCS}" == "jj" ]]; then
    jj tag set "${RELEASE_TAGS[@]}" -r "${commit}" --allow-move
    git --git-dir="$(jj git root)" tag -f -a --cleanup=verbatim -F "${notes}" "${version}" "${commit}" > /dev/null \
      || { rm -f "${notes}"; die "could not annotate ${version} (output above)"; }
    jj git import > /dev/null 2>&1 || true
    jj tag track "${RELEASE_TAGS[@]}" --remote origin
  else
    git tag -f -a --cleanup=verbatim -F "${notes}" "${version}" "${commit}" \
      || { rm -f "${notes}"; die "could not create ${version} (output above)"; }
    for name in "${RELEASE_TAGS[@]:1}"; do
      git tag --no-sign -f "${name}" "${commit}"
    done
  fi
  rm -f "${notes}"
  success "Tagged: ${RELEASE_TAGS[*]}"
}

# Echo the newest release section of CHANGELOG.md: from its "## [x.y.z]"
# heading to the next one, without the link reference definitions a footer
# puts after the last section, and without blank lines at either end.
changelog_section() {
  awk '/^## \[/{if(p) exit; p=1} p' CHANGELOG.md 2>/dev/null \
    | { grep -vE '^\[[^]]+\]: ' || true; } \
    | sed -e '/./,$!d' \
    | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}

# The jq filter release:prepare runs over the git cliff context. A release
# whose tag message is a whole changelog section (create_release_tags writes
# those) gets its highlights back — the lines between the heading and the first
# "### " group, null when there are none. A message that is only the version, as
# older tags carry, becomes null. Anything else is a real highlight and stays.
# shellcheck disable=SC2016,SC2034 # jq, not shell; read by release:prepare
CHANGELOG_CONTEXT_FILTER='
def highlights:
  split("\n") | .[1:]
  | (map(startswith("### ")) | index(true)) as $i
  | (if $i == null then . else .[:$i] end)
  | join("\n") | gsub("^\\s+|\\s+$"; "")
  | if . == "" then null else . end;
map(
  if ((.message // "") | startswith("## ")) then .message = (.message | highlights)
  elif .message == .version then .message = null
  else . end
)'

# Sign the jj release commit, and the unpushed commits under it, before the
# tag freezes them — when the user's jj config says their pushed commits get
# signed. Sets RELEASE_COMMIT to the release commit's id, which signing changes.
#
# jj signs on push only the mutable commits git-sign-on-push selects, and the
# tag makes the release commit and every ancestor immutable by then: jj says
# "Skipped signing N immutable commits" and pushes them unsigned. So the commits
# that push would have signed are signed here, while they still can be: the
# mutable ancestors of the release commit that git-sign-on-push selects, or —
# with signing.behavior own or force, which sign as they go — any of them still
# unsigned. Nothing happens unless signing.backend is set. The bookmark follows
# the rewrite.
sign_release_commit_if_configured() {
  local commit="$1" backend behavior revset change targets
  RELEASE_COMMIT="${commit}"
  backend=$(jj config get signing.backend 2>/dev/null || true)
  [[ -n "${backend}" && "${backend}" != "none" ]] || return 0

  behavior=$(jj config get signing.behavior 2>/dev/null || true)
  if [[ "${behavior}" == "own" || "${behavior}" == "force" ]]; then
    revset="all()"
  else
    revset=$(jj config get revsets.git-sign-on-push 2>/dev/null || true)
    [[ -n "${revset}" && "${revset}" != "none()" ]] || return 0
  fi
  targets="::${commit} & mutable() & ~signed() & (${revset})"
  [[ -n "$(jj log -r "${targets}" --no-graph -T 'commit_id' 2>/dev/null)" ]] || return 0

  if [[ "${SIGN_DRY_RUN:-false}" == "true" ]]; then
    info "Would sign the release commit and its unpushed ancestors (jj signing.backend=${backend})"
    return 0
  fi
  info "Signing the release commit and its unpushed ancestors (jj signing.backend=${backend})… (hardware key touch may be required)"
  change=$(jj log -r "${commit}" --no-graph -T 'change_id')
  jj sign -r "${targets}" || die "jj sign failed (output above)"
  RELEASE_COMMIT=$(jj log -r "${change}" --no-graph -T 'commit_id')
  success "Signed: ${RELEASE_COMMIT:0:12}"
}

# Echo the origin URL, empty when there is no origin.
remote_url() {
  if [[ "${VCS}" == "jj" ]]; then
    jj git remote list 2>/dev/null | awk '$1 == "origin" { print $2; exit }'
  else
    git remote get-url origin 2>/dev/null || true
  fi
}

# True when origin is on github.com. A GitHub Enterprise host under its own
# domain does not match; see DEVKIT_TAG_BATCH and DEVKIT_POST_TIDY.
github_remote() {
  [[ "$(remote_url)" == *github.com[:/]* ]]
}

# True when the release covers more than one module: per-module tags, pinned
# intra-repo requires and the post-release go.sum tidy. Needs discover_modules.
multi_module() {
  [[ ${#MONOREPO_MODULES[@]} -gt 1 ]]
}

# True when release:push should wait for the module proxy and re-tidy go.sum.
#
# The tidy exists for one thing: a module's go.sum entries for a sibling module
# at the new version, which only the proxy can supply once the tags are out. A
# single module has no sibling to record, and a module on a host other than
# github.com is typically private, so the public proxy can never serve it and
# the wait would time out after two minutes every release.
#
# DEVKIT_POST_TIDY=1 forces the step (a GitHub Enterprise host, a private proxy
# the toolchain is configured for) and DEVKIT_POST_TIDY=0 turns it off.
post_tidy_applies() {
  case "${DEVKIT_POST_TIDY:-}" in
    1 | true) return 0 ;;
    0 | false) return 1 ;;
  esac
  multi_module && github_remote
}

# Why post_tidy_applies said no, as a phrase.
post_tidy_skip_reason() {
  if [[ "${DEVKIT_POST_TIDY:-}" == "0" || "${DEVKIT_POST_TIDY:-}" == "false" ]]; then
    echo "DEVKIT_POST_TIDY=${DEVKIT_POST_TIDY}"
  elif ! multi_module; then
    echo "a single module has no sibling go.sum entries to fill in"
  else
    echo "origin is not on github.com, so the public proxy cannot serve it"
  fi
}

# Tags per push, 0 meaning "all of them in one push".
#
# GitHub creates no push event when more than three tags arrive in one push
# (https://docs.github.com/en/webhooks/webhook-events-and-payloads#push), and
# no event means no workflow run. A ten-module repo writes ten tags, so one
# push would silence the very workflow the release depends on.
#
# That quirk is GitHub's alone, so every other forge takes the tags in a single
# push and a single key touch. Three per push rather than one for the same
# reason: each push wants its own touch.
#
# A GitHub Enterprise host under its own domain does not match, so set
# DEVKIT_TAG_BATCH=3 in that repo. Setting it also overrides the batch size
# anywhere else, and DEVKIT_TAG_BATCH=0 turns batching off.
tag_batch_size() {
  if [[ -n "${DEVKIT_TAG_BATCH:-}" ]]; then
    echo "${DEVKIT_TAG_BATCH}"
  elif github_remote; then
    echo 3
  else
    echo 0
  fi
}

# Push tag names, batched for GitHub. Needs detect_vcs to have run.
#
# The batching covers the module tags too, even though no workflow watches them
# today: a repo that adds one later must not have to rediscover this.
push_tag_batch() {
  local name args=()
  if [[ "${VCS}" == "jj" ]]; then
    for name in "$@"; do args+=(--tag "${name}"); done
    jj git push "${args[@]}"
  else
    for name in "$@"; do args+=("refs/tags/${name}"); done
    HK=0 git push origin "${args[@]}"
  fi
  info "Pushed: $*"
}

push_tags() {
  local batch=() name size
  [[ $# -eq 0 ]] && return 0

  size=$(tag_batch_size)
  if [[ "${size}" -le 0 ]]; then
    push_tag_batch "$@"
    return 0
  fi

  for name in "$@"; do
    batch+=("${name}")
    if [[ ${#batch[@]} -eq ${size} ]]; then
      push_tag_batch "${batch[@]}"
      batch=()
    fi
  done
  [[ ${#batch[@]} -gt 0 ]] && push_tag_batch "${batch[@]}"
  return 0
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

# The files release:prepare writes. A single-module release touches only the
# changelog — go.mod is listed so a commit under git stays complete — and never
# a go.work, which in such a repo is often a gitignored local override.
release_prepare_paths() {
  local dir modfile
  RELEASE_PREPARE_PATHS=(CHANGELOG.md go.mod)
  multi_module || return 0
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
  # Nothing to sync without a workspace: a single module's go.sum is the whole
  # story, and `go work sync` fails outright when there is no go.work — or when
  # GOWORK=off hides the one that is there.
  if workspace_enabled; then
    info "Syncing go.work.sum…"
    GONOSUMDB="${ROOT_MODULE}" go work sync
    success "go.work.sum synced"
  fi

  info "Tidying go.sum files…"
  for dir in "${MODULE_DIRS[@]}"; do
    pushd "$dir" > /dev/null || return
    GOWORK=off GONOSUMDB="${ROOT_MODULE}" go mod tidy
    popd > /dev/null || return
  done
  success "go.sum files updated"
}

# True when the go commands these tasks run will read a workspace.
#
# GOWORK=off turns the workspace off for every one of them, so the module list
# has to follow. A repo sets it to keep a local go.work for the editor while the
# tasks stay on one module — without this the tasks walk into the sibling
# checkouts that workspace names and test somebody else's code.
workspace_enabled() {
  [[ "$(go env GOWORK)" != "off" && -f go.work ]]
}

# Echo every module directory in go.work that this repo owns, one per line, as
# it is written there ("." for the root, "./sub/dir" for the rest).
#
# A repo without a go.work is a single module at the root, and every task here
# treats it as a one-entry workspace rather than refusing to run. Plenty of
# repos never grow a second module, and they still want the same fmt, lint,
# test and release tasks.
#
# A `use` line pointing outside the repo is dropped. That is the local-override
# workspace — a gitignored go.work naming a sibling checkout so the build reads
# the dependency being changed rather than the pinned release. The go commands
# have to see it, which is why GOWORK stays on, but the module list must not:
# fmt, lint and tidy write files, so following that line would reformat, relint
# and re-tidy somebody else's repo under this repo's config.
#
# No other exclusions, unlike discover_modules: fmt, lint, test and tidy cover
# the example modules too, and dropping them here would quietly stop linting and
# testing code that a reader expects to be covered.
workspace_module_dirs() {
  if ! workspace_enabled; then
    echo "."
    return 0
  fi
  local root dir abs
  root=$(pwd -P)
  while IFS= read -r dir; do
    abs=$(cd "$dir" 2>/dev/null && pwd -P) || continue
    [[ "$abs" == "$root" || "$abs" == "$root"/* ]] || continue
    echo "$dir"
  done < <(go work edit -json | sed -n 's/.*"DiskPath": *"\(.*\)".*/\1/p')
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
  done < <(workspace_module_dirs)
}
