# freebuffed

**Freebuffed is an improved build of the [Freebuff CLI](https://freebuff.com).**
It is Freebuff, buffed: the community's own build, with extra features and
upstream pull requests that the upstream team has not yet merged.

The project is a fork of the public Freebuff mirror. It tracks upstream
`main` and ships its own changes on top.

- **License:** Apache-2.0, same as upstream
- **Upstream relationship and versioning:** see [FORK.md](FORK.md)
- **Releases:** native binaries per release; the binary reports
  `<tag>+freebuff.<upstream>` (for example `1.2.3+freebuff.0.0.146`)

## Build from source

Requirements: [bun](https://bun.sh), version per [.bun-version](.bun-version).

```bash
bun install --frozen-lockfile
bun run build:sdk
FREEBUFF_MODE=true bun cli/scripts/build-binary.ts freebuffed <version>
```

The command produces the file `cli/bin/freebuffed`.

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE). The file
[NOTICE](NOTICE) credits the upstream authors. You must preserve both files in
any redistribution.
