# freebuffed

## Purpose

This repository is a fork of the Freebuff CLI. The Freebuff CLI is the
Codebuff CLI compiled with the flag `FREEBUFF_MODE=true`.

The fork adds features that are not in the upstream CLI. It can include
upstream pull requests before the upstream team merges them.

## Relationship with upstream

The upstream repository is a public mirror of a private source tree. The
upstream team ports accepted public contributions into the private tree.
The upstream team exports the tree back to the public mirror as "Sync public
snapshot" commits.

This fork tracks the upstream `main` branch. It adds our own changes on top.
It can also include upstream pull requests that are still open.

We send our changes back upstream as pull requests against the upstream
repository.

### Upstream synchronization

A sync means upstream synchronization.
The workflow is `sync-upstream.yml`.
It runs every 15 minutes.
It also runs after a push to `main`.
A maintainer can start it manually.
The workflow checks the upstream mirror for new commits.
When it finds new commits, it opens or updates a pull request on
`sync/upstream`.

A merged sync pull request pushes to `main`.
That push starts the workflow.
The marker then matches the upstream commit.
The workflow does not create another sync commit.

The sync uses a marker.
`UPSTREAM_SHA` records the upstream commit that the fork last examined.
`UPSTREAM_VERSION` records the Freebuff version at that commit.
The sync reads the version from `freebuff/cli/release/package.json` in the
synced commit.
The marker advances after every sync that finds new upstream commits.
If upstream changes only excluded paths, the sync creates a marker-only
commit.
That commit records the upstream checkpoint.
Without it, each run would examine the same upstream commits again.
If no new upstream commit exists, the workflow performs only the upstream
check.

The sync preserves fork-local files.
It does not import upstream changes to these paths:

- `.github/`
- `.coderabbit.yaml`
- `FORK.md`
- `README.md` and `README.zh-CN.md`
- `release-please-config.json` and `.release-please-manifest.json`
- `CHANGELOG.md`

The sync manages `UPSTREAM_SHA` and `UPSTREAM_VERSION`.
It rewrites both files when it advances the marker.
It does not import upstream changes to these files.

The sync applies a three-way merge when upstream and the fork changed the
same file.
Git leaves conflict markers when it cannot resolve the change.
The sync opens or updates the pull request as a draft.
The diff shows the conflict markers.
One bot comment lists the conflicted files.
The sync updates that comment on each run.
It does not post a second comment for a later conflict.
The `Conflict markers` check fails when a changed file contains unresolved
markers.
Resolve the markers and push a follow-up commit.
The next sync marks the pull request ready when the files are clean.

The sync updates a comment only when its first line is the exact conflict
marker.
The comment author must match the account authenticated by `SYNC_TOKEN`.
The sync leaves other comments unchanged.

The sync uses the state label `upstream-conflict`.
The label identifies pull requests that the sync drafted because of
conflicts.
Create it once with `gh label create upstream-conflict`.
The sync fails when the label is missing.
It also fails when it cannot add or remove the label.
A conflicted pull request cannot remain a draft without the label.

Set `SYNC_CONFLICT_LABEL` only when the repository uses another label.
The sync reads the label collection.
It compares the label name as data.
It rejects labels with commas or control characters.

The sync script has integration tests in
`.github/scripts/sync-upstream_test.sh`.
The conflict-marker check has focused tests in
`.github/scripts/check-conflict-markers_test.sh`.
CI runs both suites on every pull request and every push to `main`.
Set `TESTS` to a space- or comma-separated list of test function names to run
a subset of the sync tests.
The suite runs all tests when `TESTS` is not set.

The sync test uses the standalone GitHub CLI fake
`.github/scripts/test-support/gh-stub.py`. It models GraphQL node IDs and
numeric REST comment IDs separately.

The sync preserves `sync/upstream` only while its pull request is open.
If the branch tip is already in `main`, the sync bases the local branch on
current `main`.
It uses a plain fast-forward push.
This covers merge commits and fast-forward merges.

If the branch tip is not in `main`, the sync reads the pull request state.
It appends only to an open pull request.
It preserves manual commits on that branch.
If the pull request is merged, the sync bases the next branch on current
`main`.
It retires the old remote branch.
It creates `sync/upstream` again after the new commit is ready.
The sync does not force-push.

If the pull request is closed, the sync fails before it reuses the branch.
If the GitHub API cannot return the pull request state, the sync also fails.
The sync leaves the remote branch unchanged in both cases.
Reopen the pull request or remove the branch before the next sync.
If the GitHub API cannot return the open pull-request list after the sync
commit is pushed, the branch remains available.
The next run retries the PR update.
Git rejects the normal push if the remote branch changes after the fetch.
If the branch is up to date, the run is a no-op.

The sync needs the secret `SYNC_TOKEN`.
The token needs Contents and Pull requests write access on this repository.
The workflow fails when a sync is due and the token is absent.

The root `README.md` is fork-specific.
The sync preserves it.

## Licensing and builds

The whole codebase is licensed under the Apache License 2.0. See the file
[LICENSE](LICENSE). The file [NOTICE](NOTICE) credits the upstream authors.
You must preserve both files in any redistribution.

**Trademarks.** The Apache License does not grant trademark rights. We do not
ship under the names "Freebuff" or "Codebuff". We do not use their artwork.
This project is `freebuffed`. It is a separate project. Do not present it as
the official product.

### Releases

Release-please opens a release pull request for every conventional commit on
`main`. While the version is below 1.0.0, `feat` and breaking changes bump
the minor version; every other type bumps the patch version. After 1.0.0,
breaking changes bump the major version. The `Release artifacts` workflow
then builds native binaries and attaches them to the release.

When you sync from upstream, record the sync as a conventional commit (for
example `chore(upstream): sync freebuff <version>`).

The file `UPSTREAM_VERSION` records the Freebuff version that the current
snapshot is based on. Update it on each sync from upstream.

The release version combines the two. The binary reports
`<tag>+freebuff.<upstream>` (for example `1.2.3+freebuff.0.0.146`). Release
assets are named `freebuffed-<tag>-freebuff-<upstream>-<platform>-<arch>`.

We do not publish to npm yet. We may publish under a distinct package name in
the future.

### Build from source

Requirements:

- [bun](https://bun.sh), version per [.bun-version](.bun-version).

Commands:

```bash
bun install --frozen-lockfile
bun run build:sdk
FREEBUFF_MODE=true bun cli/scripts/build-binary.ts freebuffed <version>
```

The command produces the file `cli/bin/freebuffed`.

## Known upstream mirror gaps

The public mirror excludes internal code. The directory `packages/internal`
is absent. It contains environment and secret-management helpers. The upstream
team excludes it by design. See [their
CONTRIBUTING.md](https://github.com/CodebuffAI/freebuff/blob/main/CONTRIBUTING.md).

The cli unit-test suite imports `packages/internal` at module scope. It cannot
start from a fresh mirror checkout. The fork CI does not run the cli suite.

We restored two files that mirror syncs dropped while the code still
references them:

- `test/setup-scm-loader.ts`
- `agents-graveyard/researcher/researcher.ts`
