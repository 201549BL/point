#!/usr/bin/env python3
"""Reject stale Pages worktrees before website work. Requires git and gh auth."""
import json
import pathlib
import subprocess
import sys


def run(root, *args):
    return subprocess.check_output(args, cwd=root, text=True, stderr=subprocess.PIPE).strip()


def check_ancestry(root, source_ref, deployed_sha):
    for label, ref in [('Pages source', source_ref), ('successful deployment', deployed_sha)]:
        result = subprocess.run(
            ['git', 'merge-base', '--is-ancestor', ref, 'HEAD'], cwd=root,
            capture_output=True, text=True,
        )
        if result.returncode == 1:
            raise RuntimeError(
                f'Stale checkout: HEAD does not contain {label} {ref}. '
                f'Preserve local changes; create a new codex/ worktree from {source_ref}.'
            )
        if result.returncode:
            raise RuntimeError(result.stderr.strip())


def main():
    root = pathlib.Path(run(pathlib.Path.cwd(), 'git', 'rev-parse', '--show-toplevel'))
    repo = run(root, 'gh', 'repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner')
    pages = json.loads(run(root, 'gh', 'api', f'repos/{repo}/pages'))
    source = pages.get('source')
    if pages.get('build_type') != 'legacy' or not source:
        raise RuntimeError('Pages uses a workflow deployment; inspect its source workflow before editing.')
    branch = source['branch']
    source_ref = f'refs/remotes/origin/{branch}'
    run(root, 'git', 'fetch', 'origin', f'+refs/heads/{branch}:{source_ref}')
    builds = json.loads(run(root, 'gh', 'api', f'repos/{repo}/pages/builds?per_page=100'))
    deployed = next((build['commit'] for build in builds if build['status'] == 'built'), None)
    if not deployed:
        raise RuntimeError('No successful Pages build found; verify the deployment before editing.')
    print(f"Live: {pages['html_url']}\nSource: {source_ref}:{source['path']}\nDeployed: {deployed}", flush=True)
    check_ancestry(root, source_ref, deployed)
    print(f"PASS: HEAD {run(root, 'git', 'rev-parse', '--short', 'HEAD')} contains the current Pages source and deployment.")


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError, KeyError, ValueError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) else str(error)
        print(f'Pages source check failed: {detail}', file=sys.stderr)
        sys.exit(1)
