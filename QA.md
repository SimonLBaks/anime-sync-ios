# Validation

Run `python3 -m unittest discover -s tools -p 'test_*.py'` for build/export/profile checks.
On macOS, run `bash tools/test-simulator.sh` for the exact app-hosted unit and UI test selection.
`QA_FOCUS=fixtures` excludes the separately reported live public website check; it does not count that check as passed.
The result gate requires every selected test method, zero failures and zero skips.

Public CI uses disposable fixture preferences and fake transports. Personal accounts, device recordings and watch-history evidence are not included.
External providers can change or require human verification; confirm real playback separately on a device.
