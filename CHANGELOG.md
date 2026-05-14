# Changelog

## 1.0.0

Public v1 release of `goshbuild`.

### Changed

- standardized on `goshbuild.sh` as the reference packer
- simplified `dist-demo-app/` to a single runner diagram
- renamed the root demo harness to `test_goshbuild.sh`
- kept the demo app source-only and inspectable
- kept GitHub Actions CI for push and pull request verification

### Validation

- `bash -n goshbuild.sh`
- `bash ./test_goshbuild.sh`
- `bash ./dist-demo-app/github_com_example_demo-app.run.sh.test.sh` passed `15/15`
- GitHub Actions CI workflow added

## 0.1.0

Initial open-source release of `goshbuild`.

### Added

- `goshbuild.sh` for Unix-like shells
- source-preserving packaging of Go modules into a single runnable file
- payload verification before extraction
- per-environment build cache
- generated acceptance tests for the packaged runner
- bundled `demo-app/` example module

### Validation

- `bash -n goshbuild.sh`
- `bash goshbuild.sh pack ./demo-app ./demo-app/demo-app.run.sh`
- `bash ./demo-app/demo-app.run.sh.test.sh` passed `15/15`
- GitHub Actions CI workflow added
