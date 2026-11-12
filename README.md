<!-- read_when: wiring a repo to the shared tooling, or changing anything under mise/, dprint/, hk/ or golangci/ -->

# devkit

Shared development tooling for my repos. Each top-level directory holds one kind
of asset, and each consumer pulls it with the mechanism its own tool provides.

| Directory            | Holds                    | Consumed by                             |
| -------------------- | ------------------------ | --------------------------------------- |
| `mise/go`            | Module and release tasks | `[task_config] includes` in `mise.toml` |
| `dprint/`            | Formatter base config    | `extends` in `.config/dprint.json`      |
| `hk/`                | Git-hook config          | `amends` in `.config/hk.pkl`            |
| `golangci`           | Linter config            | `mise run sync-golangci` composes it    |
| `.github/workflows/` | Reusable CI and release  | `uses:` in a caller workflow            |
| `github/go/`         | The caller workflows     | Copied into `.github/workflows/`        |
| `docs/go/`           | Release runbook          | Copied into a consumer's `docs/`        |

The tasks, the two configs and the reusable workflows are referenced, so a
consumer holds a one-line file and the content stays here. Three assets are
generated or copied instead. golangci-lint has no config inheritance — neither
`extends` nor `include` is in its schema — so `sync-golangci` composes that one.
A GitHub Actions caller workflow cannot live in another repo, so `github/go/`
holds two stubs to copy once. And a release runbook belongs in the repo it
releases, so `docs/go/RELEASING.md` gets copied too, pointing back here for the
reasoning.

Every asset here is Go-only today, and the naming says where a second language
would go. A referenced asset is named by its URL, so the language sits in the
filename: `dprint/go.json`, `hk/go.pkl`, `.github/workflows/go-ci.yml`. A copied asset keeps the filename it lands under
in the consumer, so the language sits in the directory instead: `github/go/`,
`docs/go/`.

## mise task sets

mise clones an included directory and treats it the way it treats a local
`.config/mise/tasks`. A file at the root of the include becomes a bare task
name, and a subdirectory becomes the task prefix. The include path itself
contributes nothing to the name.

That is why the release tasks sit one level deeper than the include points:

```
mise/go/                  <- the include path
├── _lib.sh               <- not executable, so not a task
├── fmt                   <- bare task names
├── ci
├── lint
├── test
├── tidy
├── typos
├── setup
├── build
├── sync-golangci
├── check/                <- a task prefix
│   ├── _default          <- check, not check:_default
│   └── changed           <- check:changed
└── release/
    ├── prepare           <- release:prepare
    ├── push
    ├── rollback
    └── post-tidy
```

Flatten `release/` and you get a top-level task called `push`, which is both
wrong and dangerous.

**The executable bit is what makes a file a task, not its name.** mise skips a
file with no `+x` and registers every file that has one, at any depth. A shared
helper like `_lib.sh` stays `0644` and the leading underscore is a convention
for the reader. Make it `0755` and it turns into a task — a helper under
`release/` surfaces as `release:_lib`, which is how you find out.

The underscore does carry meaning in one name. A file called `_default` becomes
its directory's own task, so `check/_default` answers to `check` and its
siblings get the `check:` prefix. A file called `default` does not — that one
becomes `check:default`.

Wire it into `.config/mise/config.toml`:

```toml
[task_config]
includes = [
  "git::https://github.com/pmarschik/devkit.git//mise/go?ref=v1",
  ".config/mise/tasks",
]
```

Rules for that list:

- Setting `includes` replaces the default task discovery, so the local
  directory needs its own entry.
- The last include wins on a name clash. Keep the local directory last and a
  repo can shadow one shared task without forking the set.
- **An include mise cannot parse is skipped in silence.** There is no warning,
  no error and no exit code — the tasks simply do not appear. After you change
  the list, run `mise tasks ls` and confirm you can see them.

The URL form is strict. mise matches it against a regex that accepts `https://`
and `ssh://` only, and the repository part must end in `.git`:

```
git::https://github.com/pmarschik/devkit.git//mise/go?ref=v1
git::ssh://git@github.com/pmarschik/devkit.git//mise/go?ref=v1
```

The scp form `git@github.com:pmarschik/devkit.git` does not match, and neither
does `file://`. Use the `https` line for a public repo and the `ssh` line when
the clone needs a key.

### Pinning

Consumers pin `?ref=v1`. The `v1` tag moves forward on every
backward-compatible change. A change that breaks a consumer becomes `v2`, and
repos move to it one at a time. The `dprint` and `hk` URLs carry the same major,
so one tag moves every asset together.

Move the tag after the change lands:

```bash
jj tag set v1 -r @- --allow-move
jj git push --tag v1
```

**A moved tag does not reach a consumer on its own.** mise clones the include
once, into `$(mise cache path)/remote-git-tasks-cache/<hash of the URL>`, and
pins that clone to the commit the ref named at the time. It never notices that
`v1` now points somewhere else, so the repo keeps running the old task with a
clean exit and no warning.

Clear the entry in each consumer after you move the tag:

```bash
rm -rf "$(mise cache path)/remote-git-tasks-cache"
mise tasks ls
```

`MISE_TASK_REMOTE_NO_CACHE=1` refetches for one invocation only. It leaves the
cache untouched, so the next plain `mise run` is stale again. Use it to try a
change out, and delete the directory to make the change stick.

## mise/go

### Module tasks

Every task walks the module list in `go.work`, including `example/*`, so a new
module joins as soon as the workspace lists it. A repo without a `go.work` is a
single module at the root, and every task treats it as a one-entry workspace.

A `use` line pointing outside the repo is skipped. That is the local-override
workspace — a gitignored `go.work` naming a sibling checkout, so the build reads
the dependency you are changing rather than the pinned release. The go commands
still see it, because `GOWORK` stays on. The module list does not, because
`fmt`, `lint` and `tidy` write files and would reformat somebody else's repo
under this repo's config.

| Task            | What it does                                             |
| --------------- | -------------------------------------------------------- |
| `check`         | `fmt`, `typos`, `test`, `lint`, then `check-extra`       |
| `check:changed` | `hk check`, so only the changed files                    |
| `ci`            | `typos`, `test`, `lint`, `check-extra` — no `fmt`        |
| `fmt`           | `golangci-lint fmt` per module, then `dprint fmt`        |
| `lint`          | `golangci-lint run` per module, then `dprint check`      |
| `test`          | `go test ./...` per module                               |
| `tidy`          | `go mod tidy` in every module, in parallel               |
| `typos`         | Spell check                                              |
| `setup`         | `go mod download` and `hk install`                       |
| `build`         | `go build ./...`                                         |
| `sync-golangci` | Composes `.config/golangci.yml` from here plus overrides |

`lint` and `test` forward extra arguments, and both take `--no-cache`.
`sync-golangci --diff-only` reports drift without writing.

#### Adding a gate of your own

`check` and `ci` end by running a task named `check-extra`, if the repo defines
one. Put it in `.config/mise/tasks/check-extra` and it runs last, after the
shared gates pass. A repo without one pays a `mise tasks info` lookup and
nothing else.

This exists so a repo never has to shadow `check` wholesale and restate the
shared list. A shadow forks in silence: add a gate here later and the shadowing
repo simply stops running it.

#### `fmt` formats, `lint` reports

`fmt` runs `golangci-lint fmt`, which applies only what the config's
`formatters:` block enables — gofumpt and goimports, both AST-preserving.

It deliberately does not run `golangci-lint run --fix`. That applies every
enabled linter's autofix. Measured on a two-field struct, it reordered the
fields and deleted the doc comments that sat on them (govet/fieldalignment) and
rewrote a call site (perfsprint), while reporting `0 issues.` A task called
`fmt`, and a commit hook, must not do that unasked. `lint` still reports those
findings; applying them stays a decision somebody makes.

The hk steps follow the same split: `go_format` runs `golangci-lint fmt` rather
than the standalone gofumpt the hk builtin uses, because the two are different
binaries built against different Go releases and disagree about composite-literal
alignment — which is how a commit hook could rewrite a generated file into a
shape CI then rejected. A repo that does want the lint autofixes overrides the
`golangci_lint` step's `fix` command in its own `.config/hk.pkl`.

### The linter config

golangci-lint reads one file and inherits from nothing, so `.config/golangci.yml`
is generated and committed. `sync-golangci` writes it from `golangci/go.yml`
here, deep-merged with the consumer's optional
`.config/golangci.overrides.yml`. A repo with no overrides file gets the shared
config verbatim under a generated-by header.

A value in the overrides file wins, and an array is a value: writing `paths` or
`tagalign.order` there replaces the shared list instead of extending it. Restate
what you want to keep. `linters.enable` is the one exception, because adding a
single linter is the common case — the generated list is the union of both
files, minus everything under `linters.disable`. Drop a shared linter by naming
it under `disable`, which also works for a linter that arrives through
`default: standard` and is therefore in no `enable` list.

The task verifies the composed file with `golangci-lint config verify` before
writing it, so a bad override fails here rather than mid-lint. It resolves `yq`
through `mise exec`, so no consumer needs it in `[tools]`.

Hand edits to `.config/golangci.yml` are lost on the next sync. Run
`sync-golangci --diff-only` in CI to catch a repo that drifted.

`check` runs `lint` last rather than as a dependency, because two
golangci-lint runs in parallel collide on its lock.

### Release tasks

One commit carries the root tag `vX.Y.Z` and a `<subdir>/vX.Y.Z` tag for every
other module in `go.work`. In a single-module repo the root tag is the only one,
and there is no `go.work.sum` to sync.

| Task                | What it does                                                         |
| ------------------- | -------------------------------------------------------------------- |
| `release:prepare`   | Writes the changelog, pins the module versions, describes the commit |
| `release:push`      | Verifies the prepared release, tags it, pushes it, tidies `go.sum`   |
| `release:rollback`  | Undoes a local `release:prepare` that you have not pushed            |
| `release:post-tidy` | Redoes the `go.sum` step when the proxy was still catching up        |
| `release:cog-check` | `cog check`, unsetting `extensions.relativeWorktrees` around the run |

Run `mise run release:push --dry-run` to check the prepared state and print
what would be pushed. It reaches no remote and changes nothing locally.

`release:prepare` runs `cog check` through `release:cog-check`, over the
commits of the release being prepared: the range from the newest `vX.Y.Z` tag
reachable from `HEAD`, or the whole history before the first release. The range
goes to cog spelled out, so no `tag_prefix` is needed in `cog.toml`; history
from before a repo adopted Conventional Commits stays out of the check. Any
argument passed to `release:cog-check` replaces the default range. cocogitto 7.0.0 links libgit2 1.9.2, which refuses a repository whose
config sets `extensions.relativeWorktrees` — git writes that key for
`git worktree add --relative-paths` — and `GIT_CONFIG_*` overrides do not reach
it. The task unsets that one key with `git config --local` right before `cog`
runs and restores the exact previous value right after, from an `EXIT` trap, so
a failing check, Ctrl-C, `SIGTERM` and `SIGHUP` all leave the config as they
found it. A lock directory in the git common dir keeps two runs from restoring
each other's unset state. A repo that shadows `release:prepare` calls
`mise run release:cog-check -- <cog check args>` rather than `cog check`.

`release:push` pushes the branch, then the root tag alone, then the module tags.
On a `github.com` remote those go three at a time, because GitHub creates no
push event when more than three tags arrive in one push, and no event means no
workflow run — a repo with ten modules would otherwise silence its own release
workflow. Every other remote takes all of them in a single push, which is one
key touch instead of four.

`DEVKIT_TAG_BATCH` overrides the size. Set it to `3` on a GitHub Enterprise
host, which the URL check does not recognize, and to `0` to send every tag at
once.

The tasks work under jj and under git. Under jj `release:prepare` describes the
working copy and leaves it there, untagged and mutable, so `jj diff` shows the
release and you can amend it. `release:push` writes the tags, because a tag
freezes its commit under jj and would slide the working copy onto an empty
child mid-review.

Copy `docs/go/RELEASING.md` into the consumer's own `docs/`. It is the command
sequence and the recovery table, and it links back here for everything this
section explains.

### What a consuming repo must provide

- `go.work`, for a multi-module repo only — the module list. The tasks walk the
  part of it that lives in the repo, and `discover_modules` in the release tasks
  skips directories matching its exclude glob, `example/*` by default. A
  single-module repo needs no such file, and its root module is the whole list.
- `.config/dprint.json` extending `dprint/go.json` from here.
- `.config/golangci.yml`, which `sync-golangci` writes, plus
  `.config/golangci.overrides.yml` when the repo needs to diverge.
- `.config/cliff.toml` with `tag_pattern = "^v[0-9]"`. Without it a submodule
  tag such as `parsers/toml/v0.5.0` wins the "latest tag" race and every
  `go.mod` gets pinned to that name. Both release tasks guard against the
  result.
- `CHANGELOG.md`, written by `git cliff` and formatted by `hk`.
- `gh`, authenticated, for the GitHub release.
- The tools themselves in `[tools]`: `go`, `golangci-lint`, `dprint`, `hk`,
  `typos-cli`, `git-cliff`, `cocogitto`.

## dprint

`.config/dprint.json` in a consumer:

```json
{
  "extends": "https://raw.githubusercontent.com/pmarschik/devkit/v1/dprint/go.json",
  "includes": ["**/*.{json,yaml,yml,toml,md}"]
}
```

`plugins` and `excludes` merge with what the consumer adds, so a repo lists only
its own extra excludes. `includes` is the exception: dprint rejects it in an
extended file, so every consumer repeats the line above.

## hk

`.config/hk.pkl` in a consumer is one line, and which line depends on whether
the repo has a `go.work`:

```pkl
amends "https://raw.githubusercontent.com/pmarschik/devkit/v1/hk/go.pkl"
amends "https://raw.githubusercontent.com/pmarschik/devkit/v1/hk/go-workspace.pkl"
```

`go.pkl` defines the `pre-commit`, `pre-push`, `fmt`, `lint`, `fix` and `check`
hooks. A consumer amending either file can override any hook or add steps.

`go-workspace.pkl` amends `go.pkl` and adds one setting:
`workspace_indicator = "go.work"` on the golangci-lint step. That makes hk run
the linter once from the repo root rather than once per module in parallel,
which collides on the golangci-lint lock. Naming the indicator in a repo that
has no `go.work` is worse than leaving it out, because **hk skips a step whose
indicator file is missing, in silence and with a clean exit** — the repo would
lose its lint step and never be told. Pick the line that matches the repo, and
switch it the day the repo gains a `go.work`.

## GitHub Actions

`.github/workflows/` holds two reusable workflows. A consumer copies a caller
out of `github/go/` and the work stays here:

| Reusable         | Caller                  | Runs                                                                 |
| ---------------- | ----------------------- | -------------------------------------------------------------------- |
| `go-ci.yml`      | `github/go/ci.yml`      | `mise run ci`, plus optional race, coverage, vuln and snapshot build |
| `go-release.yml` | `github/go/release.yml` | GoReleaser on a root tag, for a repo shipping binaries               |

`go-ci.yml` installs the repo's own tools with `jdx/mise-action` and then runs
`mise run ci`, so CI and a local run execute the same tasks. Its inputs turn the
extra jobs on and off:

```yaml
jobs:
  ci:
    uses: pmarschik/devkit/.github/workflows/go-ci.yml@v1
    with:
      race: true # default
      vuln: true # default
      coverage-floor: 75 # 0, the default, skips the job
      snapshot-build: true # false, the default, skips the job
      goreleaser-config: .config/goreleaser.yaml # default
```

`snapshot-build` is for a repo that ships binaries. `mise run ci` builds for the
runner and nothing else, so a Windows-only path or a Unix-only syscall compiles
clean on every push and breaks on the release tag. The job runs `goreleaser
build --snapshot`, which covers every target the release covers.

Reach for it rather than a build matrix in the caller. A matrix is a second list
of targets next to the goreleaser config, and two lists drift — the caller ends
up building a target the release ignores, or missing one it ships.

A library needs no release workflow. `release:push` writes the tags and the
GitHub release notes, and the module proxy does the publishing.

Unlike a mise include, `uses:` resolves on every run, so a moved `v1` tag
reaches a caller immediately. Nothing to clear. The third-party actions inside
the reusable workflows are pinned by major tag, and `upgrade` reports a new
major rather than writing it.

### When the release run never fired

GitHub creates no push event for more than three tags at once, so a release
that pushed its tags together has no run at all — and the Actions tab cannot
re-try a run that does not exist. `release:push` avoids that by sending the root
tag on its own, so the usual cause is a `jj git push` made around the task,
which carries the bookmark and every tag together. `jj op log` shows it: one
`push bookmark main, tags …` entry covering the lot.

Dispatch the run instead of re-trying it:

```bash
gh workflow run release.yml -f tag=vX.Y.Z
```

A dispatch reads the workflow from the default branch, so it also reaches a tag
whose own commit predates the `workflow_dispatch` trigger. It checks the tag out
and passes it as `GORELEASER_CURRENT_TAG`.

Give the consumer's goreleaser config `release.mode: keep-existing`. That is the
default, and spelling it out is what stops a dispatched re-run from replacing
the notes `release:push` wrote with the whole `CHANGELOG.md`.

## Maintaining this repo

| Task          | What it does                                            |
| ------------- | ------------------------------------------------------- |
| `check`       | shellcheck over `mise/` and `test/`, then `test`        |
| `test`        | Runs every `test/*.sh` against throwaway git repos      |
| `upgrade`     | Bumps dprint plugins and hk, reports action-major drift |
| `validate-hk` | Evaluates both `hk/*.pkl` the way a consumer would      |

Every shared config pins the versions it names, so a consumer gets the same
plugins whatever day it clones. `upgrade` is what moves those pins, and it runs
`validate-hk` after an hk bump: hk renames and retypes its builtins between
minors, and the shared pkl reaches into several of them.

After a change: `mise run check`, land it, move the major tag, then clear the
cache in each consumer.

Repos that use this set: `kongfig`, `adfast`.
