# Changelog

## 0.1.0

Initial open-source release of `goshbuild`.

### Added

- `goshbuild.sh` for Unix-like shells
- `goshbuild.ps1` for PowerShell
- `gobuild.ps1` alias for the Windows entry point
- source-preserving packaging of Go modules into a single runnable file
- payload verification before extraction
- per-environment build cache
- generated acceptance tests for the packaged runner
- bundled `demo-app/` example module

### Validation

- `bash -n goshbuild.sh`
- PowerShell parse of `goshbuild.ps1`
- PowerShell parse of `gobuild.ps1`
- `powershell -ExecutionPolicy Bypass -File .\gobuild.ps1 pack .\demo-app .\demo-app\demo-app.run.sh`
- `bash goshbuild.sh pack ./demo-app ./demo-app/demo-app.run.sh`
- `bash ./demo-app/demo-app.run.sh.test.sh` passed `15/15`
- Windows pack/run path validated through `gobuild.ps1`
- GitHub Actions CI workflow added
