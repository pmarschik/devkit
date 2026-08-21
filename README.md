<!-- read_when: wiring a repo to the shared tooling, or changing anything under mise/ -->

# devkit

Shared development tooling for my repos. Each top-level directory holds one
kind of asset, and each consumer pulls it with the mechanism its own tool
provides.

| Directory         | Consumed by                             |
| ----------------- | --------------------------------------- |
| `mise/go-release` | `[task_config] includes` in `mise.toml` |

## mise task sets

mise clones an included directory and treats it the way it treats a local
`.config/mise/tasks`. A file at the root of the include becomes a bare task
name, and a subdirectory becomes the task prefix. The include path itself
contributes nothing to the name.

That is why the tasks sit one level deeper than the include points:

```
mise/go-release/          <- the include path
└── release/              <- the task prefix
    ├── _lib.sh           <- leading underscore, so not a task
    ├── prepare           <- release:prepare
    ├── push
    ├── rollback
    └── post-tidy
```

Flatten that and you get a top-level task called `push`, which is both wrong
and dangerous.

Wire it into `.config/mise/config.toml`:

```toml
[task_config]
includes = [
  "git::https://github.com/pmarschik/devkit.git//mise/go-release?ref=v1",
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

The URL form is strict. mise matches it against a regex that accepts
`https://` and `ssh://` only, and the repository part must end in `.git`:

```
git::https://github.com/pmarschik/devkit.git//mise/go-release?ref=v1
git::ssh://git@github.com/pmarschik/devkit.git//mise/go-release?ref=v1
```

The scp form `git@github.com:pmarschik/devkit.git` does not match, and neither
does `file://`. Use the `https` line for a public repo and the `ssh` line when
the clone needs a key.

### Pinning

Consumers pin `?ref=v1`. The `v1` tag moves forward on every
backward-compatible change. A change that breaks a consumer becomes `v2`, and
repos move to it one at a time.

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

## mise/go-release

Releases a Go workspace repo. One commit carries the root tag `vX.Y.Z` and a
`<subdir>/vX.Y.Z` tag for every other module in `go.work`.

| Task                | What it does                                                     |
| ------------------- | ---------------------------------------------------------------- |
| `release:prepare`   | Writes the changelog, pins the module versions, commits and tags |
| `release:push`      | Verifies the prepared release, pushes it, then tidies `go.sum`   |
| `release:rollback`  | Undoes a local `release:prepare` that you have not pushed        |
| `release:post-tidy` | Redoes the `go.sum` step when the proxy was still catching up    |

Run `mise run release:push --dry-run` to check the prepared state and print
what would be pushed. It reaches no remote and changes nothing locally.

The tasks work under jj and under git. Under jj `release:prepare` commits and
tags, because both are local and reversible there. Under git those steps wait
until `release:push`, where an unwanted commit costs a reset.

### What a consuming repo must provide

- `go.work` — the module list. `discover_modules` reads it and skips
  directories matching its exclude glob, `example/*` by default.
- `.config/cliff.toml` with `tag_pattern = "^v[0-9]"`. Without it a submodule
  tag such as `parsers/toml/v0.5.0` wins the "latest tag" race and every
  `go.mod` gets pinned to that name. Both tasks guard against the result.
- `CHANGELOG.md`, written by `git cliff` and formatted by `hk`.
- `gh`, authenticated, for the GitHub release.
- The tools themselves in `[tools]`: `git-cliff`, `hk`, `cocogitto`, `go`.

Repos that use this set: `kongfig`, `adfast`.
