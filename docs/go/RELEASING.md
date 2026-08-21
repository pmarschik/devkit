<!-- read_when: cutting a release -->

# Releasing

The release tasks come from [devkit](https://github.com/pmarschik/devkit). Its
README explains the tag layout, the jj and git differences, and why each step
happens. This file is the sequence.

One release commit carries the root tag `vX.Y.Z` and a `<subdir>/vX.Y.Z` tag for
every other module in `go.work`.

## Before you start

- `main` is current and the working copy holds nothing you have not committed.
- Every commit since the last tag follows Conventional Commits. `cog check`
  names the ones that do not.
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

`release:prepare` writes `CHANGELOG.md` and pins every intra-repo `require` to
the new version. Under jj it also describes the release commit, which stays
mutable, so you can amend it and run `release:prepare` again. Under git the
changes stay uncommitted until `release:push`. Either way a second
`release:prepare` re-prepares the same version instead of bumping past it.

`release:push` tags the commit, pushes the branch, pushes the root tag on its
own, then pushes the module tags. It updates the GitHub release notes, waits for
the module proxy, and commits the tidied `go.sum` files.

## When something goes wrong

| Symptom                                                | Fix                                           |
| ------------------------------------------------------ | --------------------------------------------- |
| The prepared release is wrong, nothing has been pushed | `mise run release:rollback`                   |
| `release:prepare` died partway through                 | Restore the release files, then prepare again |
| The proxy was still catching up                        | `mise run release:post-tidy`                  |
| No Actions run appeared                                | `gh workflow run release.yml -f tag=vX.Y.Z`   |

The devkit README explains what causes each of those.

## Adding a module

The tasks read `go.work`, so a new module joins the next release once the
workspace lists it. Give it a `go.mod` and add it to `go.work`.
