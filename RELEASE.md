# goshbuild v1.0.0

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
- `test_goshbuild.sh` as the higher-order demo harness
- `dist-demo-app/` with a single runner diagram for review

## Tested in this workspace

- `bash -n goshbuild.sh`
- PowerShell parse of `goshbuild.ps1`
- `bash ./test_goshbuild.sh`
- `bash ./dist-demo-app/github_com_example_demo-app.run.sh.test.sh`
- Windows pack/run path validated through `goshbuild.ps1`
- CI workflow added at `.github/workflows/ci.yml`

## Notes

- The demo runner acceptance suite passed `15/15`.
- First run in a new environment performs a build, then later runs reuse the cached binary when the cache key matches.
- Generated review outputs can be inspected directly with `bash`.
