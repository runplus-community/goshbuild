# goshbuild v0.1.0

## Summary

`goshbuild` packages a Go module into a self-contained shell runner while
preserving the full source tree inside the bundle.

## Highlights

- single-file delivery for Go modules
- source-preserving artifact format
- verification before extraction
- build caching per environment
- `goshbuild.sh` and `goshbuild.ps1`
- bundled `demo-app/` for quick validation

## Tested in this workspace

- `bash -n goshbuild.sh`
- PowerShell parse of `goshbuild.ps1`
- `powershell -ExecutionPolicy Bypass -File .\goshbuild.ps1 pack .\demo-app .\demo-app\demo-app.run.sh`
- `bash goshbuild.sh pack ./demo-app ./demo-app/demo-app.run.sh`
- `bash ./demo-app/demo-app.run.sh.test.sh`
- Windows pack/run path validated through `goshbuild.ps1`
- CI workflow added at `.github/workflows/ci.yml`

## Notes

- The demo runner acceptance suite passed `15/15`.
- First run in a new environment performs a build, then later runs reuse the cached binary when the cache key matches.
