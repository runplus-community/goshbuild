# dist-demo-app

Review surface for the packed demo app.
`demo-app/` stays source-only.

## Files

- `github_com_example_demo-app.run.sh` - the generated runner
- `github_com_example_demo-app.run.sh.test.sh` - the generated acceptance test
- `github_com_example_demo-app.run.corrupt.sh` - the intentionally broken copy used to prove checksum rejection

## Runner Diagram

```text
github_com_example_demo-app.run.sh
+-------------------------------------------------------------+
| shell wrapper                                               |
| __PAYLOAD_B64__ marker                                      |
| checksum verify                                             |
| base64 decode tar.gz                                        |
| extract source tree                                         |
| build Go binary                                             |
| exec with original args                                     |
+-------------------------------------------------------------+
```

## Notes

- The `.run.sh` file is the file to inspect first.
- The `.run.sh.test.sh` file shows the acceptance path.
- The `.run.corrupt.sh` file proves checksum rejection.
- You can run the generated shell scripts directly with `bash`.
- Trace artifacts live under `demo-app/conversions/` and `.con/` in the repo root.
