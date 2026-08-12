# freebuffed

## Purpose

This repository is a fork of the Freebuff CLI. The Freebuff CLI is the
Codebuff CLI compiled with the flag `FREEBUFF_MODE=true`.

The fork provides a better Freebuff. It includes our own features and it
includes upstream pull requests that the upstream team has not yet merged.

The name plays on "Freebuff": buffed, and free.

## Relationship with upstream

The upstream repository is a public mirror of a private source tree. The
upstream team ports accepted public contributions into the private tree. They
then export the tree back to the public mirror as "Sync public snapshot"
commits.

This fork tracks the upstream `main` branch. It adds our own changes on top.
We also merge useful upstream pull requests that are still open.

We send our changes back upstream as pull requests against the upstream
repository.

### Syncing from upstream

The workflow `sync-upstream.yml` keeps the fork up to date. It runs every 15
minutes and after every merge to `main`, and checks the upstream mirror for
new commits. When it finds new commits, it opens or updates a pull request on
the branch `sync/upstream`. A sync merge does not re-trigger a sync: the
marker advances with the sync, so the immediate check after a sync merge is a
no-op.

The sync compares against a marker. The file `UPSTREAM_SHA` records the
upstream commit that the fork last synced. The file `UPSTREAM_VERSION`
records the Freebuff version at that point. The sync updates both files.

The sync preserves fork-local files. A sync never touches these paths:

- `.github/`
- `.coderabbit.yaml`
- `FORK.md`
- `README.md` and `README.zh-CN.md`
- `UPSTREAM_VERSION` and `UPSTREAM_SHA`
- `release-please-config.json` and `.release-please-manifest.json`
- `CHANGELOG.md`
- `scripts/sync-upstream.sh`

When upstream changes a file that the fork also changed, the sync cannot
apply automatically. The workflow stops and reports the conflict. Resolve it
manually with `bash scripts/sync-upstream.sh`, then push to `sync/upstream`.
The pull request then shows the resolved result.

The sync needs the secret `SYNC_TOKEN` (a fine-grained token with Contents
and Pull requests write access on this repository). Without it, the workflow
fails when a sync is due.

The root `README.md` is fork-specific. Preserve it across syncs from upstream.

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
