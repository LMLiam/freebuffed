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

This section uses *sync* to mean upstream synchronisation. The
`sync-upstream.yml` workflow runs every 15 minutes and after each push to
`main`. A maintainer can also start it manually. When the workflow finds new
upstream commits, it opens or updates a pull request from `sync/upstream`.

`UPSTREAM_SHA` records the upstream commit that the fork last examined.
`UPSTREAM_VERSION` records the Freebuff version at that commit. The sync reads
the version from `freebuff/cli/release/package.json` and requires a three-part
decimal version. A sync commit updates both marker files. If upstream changes
only excluded paths, the sync creates a marker-only commit. This commit stops
later runs from examining the same upstream commits again.

The sync does not import upstream changes to these fork-local paths:

- `.github/`
- `.coderabbit.yaml`
- `FORK.md`
- `README.md` and `README.zh-CN.md`
- `release-please-config.json` and `.release-please-manifest.json`
- `CHANGELOG.md`

The sync manages `UPSTREAM_SHA` and `UPSTREAM_VERSION`; it does not copy these
files from upstream.

If upstream and the fork change the same file, the sync applies a three-way
merge. If Git cannot resolve the change, the sync commits the conflict markers
and makes the pull request a draft. One bot comment lists the conflicted files.
The sync updates this comment for later conflicts. It fails if more than one
owned notice exists.

The `Conflict markers` check scans only pull requests from `sync/upstream`.
It fails when a changed text file contains an unresolved standard marker.
Resolve the markers and push a follow-up commit. The next sync marks the pull
request ready when the files are clean.

The sync owns a notice only when its first line contains the exact automation
marker and its author matches the account authenticated by `SYNC_TOKEN`. It
does not change comments from other users.

The `upstream-conflict` label identifies pull requests that the sync made
drafts because of conflicts. Create the label once with
`gh label create upstream-conflict`. The sync fails before Git changes if the
label is absent. Set `SYNC_CONFLICT_LABEL` only if the repository uses a
different label. The value must not contain commas or control characters.

The sync script has integration tests in
`.github/scripts/sync-upstream_test.sh`.
The conflict-marker check has focused tests in
`.github/scripts/check-conflict-markers_test.sh`.
CI runs both suites on every pull request and every push to `main`.
Set `TESTS` to a space- or comma-separated list of test function names to run
a subset of the sync tests.
The suite runs all tests when `TESTS` is not set.

The Python pull-request command owns typed GitHub state and pull-request
changes. The Bash command owns Git state, patch application, commits, and
pushes. The test fake stores a history of pull requests. It keeps GraphQL node
IDs separate from numeric Representational State Transfer (REST) comment IDs.

The sync appends to `sync/upstream` only when an open pull request matches the
observed branch tip. After a merged pull request, the sync starts the next
candidate from current `main`. It replaces the retained remote branch with one
atomic force-with-lease push. The lease must name the exact merged pull-request
head. If the branch or pull request changes, the push fails and preserves the
remote branch.

If pull-request creation failed after a sync push, a later run can recover the
preserved candidate. The branch must descend from current `main`, be ahead of
it, and contain valid sync markers for the fetched upstream range. The version
must match the marked upstream commit. The sync preserves additional manual
commits when it creates the missing pull request.

The sync does not reuse an unmatched branch that fails these checks. It also
does not reuse a branch for a closed pull request. The error identifies the
manual recovery action. A GitHub API failure remains distinct from a valid
lookup that finds no matching pull request.

The sync requires `SYNC_TOKEN` with Contents and Pull requests write access.
In GitHub Actions, the command validates the token before its first GitHub API
request. If no new upstream commit exists, the workflow performs only the
read-only upstream check.

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
