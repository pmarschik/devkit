<!-- read_when: cutting a release -->

# Releasing

The release tasks come from [devkit](https://github.com/pmarschik/devkit). Its
README explains the tag layout, the jj and git differences, and why each step
happens. This file is the sequence.

One release commit carries the root tag `vX.Y.Z`, annotated with its changelog
section, and a `<subdir>/vX.Y.Z` tag for every other module in `go.work`. A
single-module repo gets the root tag alone and nothing pinned.

## Before you start

- `main` is current and the working copy holds nothing you have not committed.
- Every commit since the last `vX.Y.Z` tag follows Conventional Commits:
  `release:prepare` runs `cog check` over that range — the whole history
  before the first release — and `mise run release:cog-check` names the
  commits that fail.
- No other git or jj command touches this repository's worktrees while
  `release:prepare` runs. If the repo config sets
  `extensions.relativeWorktrees`, which cocogitto cannot read, the check unsets
  it for the few seconds `cog` runs and then restores it. A worktree command
  in that window would see a repository without the extension.
- `mise run check` passes.

## Cut the release

```bash
mise run release:prepare

# review the changelog and the pinned versions
jj diff                 # under jj
git diff                # under git

mise run release:push --dry-run
mise run release:push   # confirms first, then needs a hardware key touch
```

Without a terminal `release:push` and `release:rollback` refuse to run. Pass
`--yes` (or `--non-interactive`, or set `DEVKIT_NON_INTERACTIVE=1`) only when
you mean it; pushing is yours to start, never an agent's.

`release:prepare` writes `CHANGELOG.md` and pins every intra-repo `require` to
the new version. Under jj it also describes the release commit, which stays
mutable, so you can amend it and run `release:prepare` again. Under git the
changes stay uncommitted until `release:push`. Either way a second
`release:prepare` re-prepares the same version instead of bumping past it.

`release:push` signs the release commit first when your jj signing config asks
for it, tags the commit, pushes the branch, pushes the root tag on its own, then
pushes the module tags. On a `github.com` origin it also updates the GitHub
release notes, and for several modules there it waits for the module proxy and
commits the tidied `go.sum` files. Elsewhere it stops after the tags.

## When something goes wrong

| Symptom                                                | Fix                                           |
| ------------------------------------------------------ | --------------------------------------------- |
| The prepared release is wrong, nothing has been pushed | `mise run release:rollback`                   |
| `release:prepare` died partway through                 | Restore the release files, then prepare again |
| `cog-check: a previous run (pid …) died holding …`     | Run the `git config` and `rm` lines it prints |
| The proxy was still catching up                        | `mise run release:post-tidy`                  |
| No Actions run appeared                                | `gh workflow run release.yml -f tag=vX.Y.Z`   |

The devkit README explains what causes each of those.

## Adding a module

The tasks read `go.work`, so a new module joins the next release once the
workspace lists it. Give it a `go.mod` and add it to `go.work`.
