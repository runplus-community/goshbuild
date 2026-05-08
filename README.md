# goshbuild

`goshbuild` packages a Go module into a self-contained shell runner.

The bundle preserves the module source and build inputs, then emits a single
`sh` or `ps1` entry point that extracts, verifies, builds, and executes the
Go program at runtime.

It sits between two delivery models:

- binary-only distribution
- source-only repository delivery

`goshbuild` keeps the source tree intact and ships one runnable file per target
platform.

Root-level entry points:

- `goshbuild.sh` for bash-compatible Unix shells
- `goshbuild.ps1` for PowerShell on Windows
- `gobuild.ps1` as a thin Windows alias for people who prefer the shorter name

## Quick Start

```bash
chmod +x goshbuild.sh
./goshbuild.sh pack ./demo-app ./demo-app/demo-app.run.sh
./demo-app/demo-app.run.sh --help
```

```powershell
powershell -ExecutionPolicy Bypass -File .\gobuild.ps1 pack .\demo-app .\demo-app\demo-app.run.sh
.\demo-app\demo-app.run.sh --help
```

## Output

`pack` creates:

- `<name>.run.sh` - the self-contained runner
- `<name>.run.sh.test.sh` - acceptance tests for the runner

The generated runner embeds a tarball of the module source, verifies the
payload hash, extracts into a cache directory, builds the Go binary, and then
`exec`s the binary with the original arguments.

## Packing Flow

```text
+----------------------+        +------------------------+
| Go module source     | -----> | goshbuild pack         |
| go.mod, *.go, assets |        | vendor / tar / hash    |
+----------------------+        | base64                 |
                                 +-----------+------------+
                                             |
                                             v
                                 +-----------+------------+
                                 | generated runner       |
                                 | <name>.run.sh / .ps1   |
                                 | stub + payload + hash  |
                                 +-----------+------------+
                                             |
                                             v
                                   runtime execution
                          +------------------+------------------+
                          | first run: verify -> extract ->     |
                          | build -> exec                       |
                          +------------------+------------------+
                          | later runs: cache hit -> exec      |
                          +-------------------------------------+
```

## Behavior

- Any Go module can be delivered as a single `sh` or `ps1` entry point.
- The source tree remains multi-file and inspectable, while the handoff artifact stays single-file.
- The first run in a new environment performs a build; later runs reuse the cached binary when the cache key matches.
- Payload verification happens before extraction, which provides a corruption check before any source is unpacked.
- Cache keys include module identity, `GOOS/GOARCH`, Go version, and payload hash.
- Go compile time is low enough that first-run builds remain practical in CI.
- Unix-like environments use `goshbuild.sh`; Windows uses `goshbuild.ps1` or `gobuild.ps1`.

## Use Cases

### 1. CI/CD helper

A repository needs a build helper, release step, or test shim that must run on GitHub Actions Ubuntu and macOS without extra bootstrap work. `goshbuild` packages that helper into one runner file.

With a warm cache, the runner becomes a direct `exec` into the compiled Go binary.

### 2. Repeated internal automation

Teams often run the same internal utility repeatedly: code generation, repo-wide rewrites, validation passes, or maintenance commands. Because Go compiles quickly and the cache key includes the payload hash and toolchain details, repeat runs stay fast while still rebuilding when the source changes.

Go compile time stays low enough that first-run builds are practical and repeat runs are cache hits.

### 3. Support and incident-response bundle

An ops or support team can package a recovery tool, ship it as a single `.run.sh` or `.ps1`, and run it on a locked-down machine without installing Go or pulling dependencies from the network.

The checksum check provides an integrity gate before extraction.

### 4. Release handoff

The source project may remain split across many files, packages, and build steps, but the handoff artifact is still one runnable file.

The tradeoff is explicit: many files stay in the repository, one file is delivered to do the job.

## Demo app

`demo-app/` contains a tiny Go module plus a manual test script. It exists so you can see the packer work against a real module without inventing your own example first.

```bash
chmod +x goshbuild.sh
./goshbuild.sh pack ./demo-app ./demo-app/demo-app.run.sh
./demo-app/demo-app.run.sh --help
bash ./demo-app/demo-app.run.sh.test.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File .\gobuild.ps1 pack .\demo-app .\demo-app\demo-app.run.sh
.\demo-app\demo-app.run.sh --help
bash .\demo-app\demo-app.run.sh.test.sh
```

## Validation

Current workspace validation:

- `bash -n goshbuild.sh`
- PowerShell parse of `goshbuild.ps1`
- PowerShell parse of `gobuild.ps1`
- `powershell -ExecutionPolicy Bypass -File .\gobuild.ps1 pack .\demo-app .\demo-app\demo-app.run.sh`
- `bash goshbuild.sh pack ./demo-app ./demo-app/demo-app.run.sh`
- `bash ./demo-app/demo-app.run.sh.test.sh`
- Windows pack/run validation passed through the `gobuild.ps1` path
- GitHub Actions CI workflow added at [.github/workflows/ci.yml](.github/workflows/ci.yml)

The demo test suite passed `15/15` in this workspace.

## Usage

### Bash

```bash
chmod +x goshbuild.sh
./goshbuild.sh pack ./my-go-app ./my-go-app.run.sh
./my-go-app.run.sh --help
bash ./my-go-app.run.sh.test.sh
```

### PowerShell

```powershell
powershell -ExecutionPolicy Bypass -File .\gobuild.ps1 pack .\my-go-app .\my-go-app.run.sh
.\my-go-app.run.sh --help
bash .\my-go-app.run.sh.test.sh
```

## Requirements

- `go`
- `tar`
- `base64`
- `bash` for the generated runner

## Release Notes

- [CHANGELOG.md](CHANGELOG.md)
- [RELEASE.md](RELEASE.md)

## License

MIT. See [LICENSE](LICENSE).
