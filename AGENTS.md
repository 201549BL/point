# Local builds and Screen Recording

For rebuilds installed in `/Applications/Point.app`, use `Scripts/install-local.sh`.
It enforces the production signing identity before replacing or launching Point.
For permission failures, signing changes, or changes to build/install/relaunch code,
read [the permission guide](docs/screen-recording-permissions.md) and run
`python3 Tests/InstallSigningTests.py` alongside `swift test`.
