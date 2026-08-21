<!-- read_when: wiring a repo to the shared tooling, or changing anything under mise/, dprint/, hk/ or golangci/ -->

# devkit

Shared development tooling for my repos. Each top-level directory holds one kind
of asset, and each consumer pulls it with the mechanism its own tool provides.

| Directory            | Holds                       | Consumed by                             |
| -------------------- | --------------------------- | --------------------------------------- |
| `mise/go`            | Workspace and release tasks | `[task_config] includes` in `mise.toml` |
| `dprint/`            | Formatter base config       | `extends` in `.config/dprint.json`      |
| `hk/`                | Git-hook config             | `amends` in `.config/hk.pkl`            |
| `golangci`           | Linter config               | `mise run sync-golangci` copies it      |
| `.github/workflows/` | Reusable CI and release     | `uses:` in a caller workflow            |
| `github/`            | The caller workflows        | Copied into `.github/workflows/`        |

Everything except two files is referenced, so a consumer holds a one-line file
and the content stays here. golangci-lint has no remote-extends mechanism, so
that config is copied, and `sync-golangci` is how it gets copied. A GitHub
Actions caller workflow cannot live in another repo either, so `github/` holds
two stubs to copy once.

## mise task sets

mise clones an included directory and treats it the way it treats a local
`.config/mise/tasks`. A file at the root of the include becomes a bare task
name, and a subdirectory becomes the task prefix. The include path itself
contributes nothing to the name.

That is why the release tasks sit one level deeper than the include points:

```
mise/go/                  <- the include path
├── _lib.sh               <- leading underscore, so not a task
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

`_default` is the one underscore mise does read. A file by that name becomes the
directory's own task, so `check/_default` answers to `check` and its siblings
get the `check:` prefix. A file called `default` does not — that one becomes
`check:default`.

Wire it into `.config/mise/config.toml`:

```toml
[task_config]
includes = [
  "git::https://github.com/pmarschik/devkit.git//mise/go?ref=v2",
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
git::https://github.com/pmarschik/devkit.git//mise/go?ref=v2
git::ssh://git@github.com/pmarschik/devkit.git//mise/go?ref=v2
```

The scp form `git@github.com:pmarschik/devkit.git` does not match, and neither
does `file://`. Use the `https` line for a public repo and the `ssh` line when
the clone needs a key.

### Pinning

Consumers pin `?ref=v2`. The `v2` tag moves forward on every
backward-compatible change. A change that breaks a consumer becomes `v3`, and
repos move to it one at a time. The `dprint` and `hk` URLs carry the same major,
so one tag moves every asset together.

Move the tag after the change lands:

```bash
jj tag set v2 -r @- --allow-move
jj git push --tag v2
```

**A moved tag does not reach a consumer on its own.** mise clones the include
once, into `$(mise cache path)/remote-git-tasks-cache/<hash of the URL>`, and
pins that clone to the commit the ref named at the time. It never notices that
`v2` now points somewhere else, so the repo keeps running the old task with a
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

### Workspace tasks

Every task walks the module list in `go.work`, including `example/*`, so a new
module joins as soon as the workspace lists it.

| Task            | What it does                                            |
| --------------- | ------------------------------------------------------- |
| `check`         | `fmt`, `typos`, `test`, then `lint`                     |
| `check:changed` | `hk check`, so only the changed files                   |
| `ci`            | `typos`, `test`, then `lint` — the same gates, no `fmt` |
| `fmt`           | `golangci-lint run --fix` per module, then `dprint fmt` |
| `lint`          | `golangci-lint run` per module, then `dprint check`     |
| `test`          | `go test ./...` per module                              |
| `tidy`          | `go mod tidy` in every module, in parallel              |
| `typos`         | Spell check                                             |
| `setup`         | `go mod download` and `hk install`                      |
| `build`         | `go build ./...`                                        |
| `sync-golangci` | Copies `golangci/go-workspace.yml` to `.config/`        |

`lint` and `test` forward extra arguments, and both take `--no-cache`.
`sync-golangci --diff-only` reports drift without writing.

`check` runs `lint` last rather than as a dependency, because two
golangci-lint runs in parallel collide on its lock.

### Release tasks

One commit carries the root tag `vX.Y.Z` and a `<subdir>/vX.Y.Z` tag for every
other module in `go.work`.

| Task                | What it does                                                         |
| ------------------- | -------------------------------------------------------------------- |
| `release:prepare`   | Writes the changelog, pins the module versions, describes the commit |
| `release:push`      | Verifies the prepared release, tags it, pushes it, tidies `go.sum`   |
| `release:rollback`  | Undoes a local `release:prepare` that you have not pushed            |
| `release:post-tidy` | Redoes the `go.sum` step when the proxy was still catching up        |

Run `mise run release:push --dry-run` to check the prepared state and print
what would be pushed. It reaches no remote and changes nothing locally.

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

### What a consuming repo must provide

- `go.work` — the module list. The workspace tasks walk all of it, and
  `discover_modules` in the release tasks skips directories matching its
  exclude glob, `example/*` by default.
- `.config/dprint.json` extending `dprint/go.json` from here.
- `.config/golangci.yml`, which `sync-golangci` writes.
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
  "extends": "https://raw.githubusercontent.com/pmarschik/devkit/v2/dprint/go.json",
  "includes": ["**/*.{json,yaml,yml,toml,md}"]
}
```

`plugins` and `excludes` merge with what the consumer adds, so a repo lists only
its own extra excludes. `includes` is the exception: dprint rejects it in an
extended file, so every consumer repeats the line above.

## hk

`.config/hk.pkl` in a consumer:

```pkl
amends "https://raw.githubusercontent.com/pmarschik/devkit/v2/hk/go-workspace.pkl"
```

The file defines the `pre-commit`, `pre-push`, `fmt`, `lint`, `fix` and `check`
hooks. A consumer amending it can override any hook or add steps.

## GitHub Actions

`.github/workflows/` holds two reusable workflows. A consumer copies a caller
out of `github/` and the work stays here:

| Reusable         | Caller               | Runs                                                   |
| ---------------- | -------------------- | ------------------------------------------------------ |
| `go-ci.yml`      | `github/ci.yml`      | `mise run ci`, plus optional race, coverage and vuln   |
| `go-release.yml` | `github/release.yml` | GoReleaser on a root tag, for a repo shipping binaries |

`go-ci.yml` installs the repo's own tools with `jdx/mise-action` and then runs
`mise run ci`, so CI and a local run execute the same tasks. Its inputs turn the
extra jobs on and off:

```yaml
jobs:
  ci:
    uses: pmarschik/devkit/.github/workflows/go-ci.yml@v2
    with:
      race: true # default
      vuln: true # default
      coverage-floor: 75 # 0, the default, skips the job
```

A library needs no release workflow. `release:push` writes the tags and the
GitHub release notes, and the module proxy does the publishing.

Unlike a mise include, `uses:` resolves on every run, so a moved `v2` tag
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

| Task          | What it does                                             |
| ------------- | -------------------------------------------------------- |
| `check`       | shellcheck over everything under `mise/`                 |
| `upgrade`     | Bumps dprint plugins and hk, reports action-major drift  |
| `validate-hk` | Evaluates `hk/go-workspace.pkl` the way a consumer would |

Every shared config pins the versions it names, so a consumer gets the same
plugins whatever day it clones. `upgrade` is what moves those pins, and it runs
`validate-hk` after an hk bump: hk renames and retypes its builtins between
minors, and the shared pkl reaches into several of them.

After a change: `mise run check`, land it, move the major tag, then clear the
cache in each consumer.

Repos that use this set: `kongfig`, `adfast`.
