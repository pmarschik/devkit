<!-- read_when: wiring a repo to the shared tooling, or changing anything under mise/ -->

# devkit

Shared development tooling for my repos. Each top-level directory holds one
kind of asset, and each consumer pulls it with the mechanism its own tool
provides.

| Directory         | Consumed by                             |
| ----------------- | --------------------------------------- |
| `mise/go-release` | `[task_config] includes` in `mise.toml` |

## mise task sets

mise clones an included directory and runs the file tasks inside it. The
directory name becomes the task prefix, so `mise/go-release` gives you
`release:prepare`, `release:push` and the rest.

Wire it into `.config/mise/config.toml`:

```toml
[task_config]
includes = [
  "git::https://github.com/pmarschik/devkit.git//mise/go-release?ref=v1",
  ".config/mise/tasks",
]
```

Two rules for that list:

- Setting `includes` replaces the default task discovery, so the local
  directory needs its own entry.
- The last include wins on a name clash. Keep the local directory last and a
  repo can shadow one shared task without forking the set.

mise caches the clone under `$MISE_CACHE_DIR/remote-git-tasks-cache`. Set
`MISE_TASK_REMOTE_NO_CACHE=1` to force a refetch while you change a task here.

### Pinning

Consumers pin `?ref=v1`. The `v1` tag moves forward on every
backward-compatible change, so a fix reaches every repo on its next
`mise run`. A change that breaks a consumer becomes `v2`, and repos move to it
one at a time.

Move the tag after the change lands:

```bash
jj tag set v1 -r @- --allow-move
jj git push --tag v1
```

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
