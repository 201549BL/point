# Local builds and Screen Recording

For rebuilds installed in `/Applications/Point.app`, use `Scripts/install-local.sh`.
It enforces the production signing identity before replacing or launching Point.
For permission failures, signing changes, or changes to build/install/relaunch code,
read [the permission guide](docs/screen-recording-permissions.md) and run
`python3 Tests/InstallSigningTests.py` alongside `swift test`.

# GitHub Pages freshness

Before inspecting, editing, or previewing the website, run
`python3 Scripts/check-pages-source.py` from the target worktree. Proceed only
when it passes. It fetches the configured Pages source and checks that HEAD
contains both its latest commit and the last successful deployment.

On failure, preserve local changes and create a fresh `codex/` worktree from the
reported source ref; run the check there before continuing. Inspect the live URL
reported by the check and reproduce the issue on that current version. A local
preview alone does not establish which version is published.
