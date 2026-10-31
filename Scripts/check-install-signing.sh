#!/bin/zsh
set -euo pipefail

candidate="${1:?Usage: check-install-signing.sh candidate.app [installed.app]}"
installed="${2:-}"
requirement='identifier "com.eirikbjorndal.point" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "DNPD2D9266"'

if ! codesign --verify --deep --strict --test-requirement "=$requirement" "$candidate"; then
    print -u2 -- "Installation requires Point's Developer ID signature (team DNPD2D9266)."
    print -u2 -- "Apple Development and ad-hoc builds must use the separate com.eirikbjorndal.point.dev identity."
    exit 1
fi

if [[ -d "$installed" ]]; then
    previous_requirement="$(codesign --display --requirements - "$installed" 2>&1 | sed -n 's/^designated => //p')"
    if [[ -z "$previous_requirement" ]] || ! codesign --verify --test-requirement "=$previous_requirement" "$candidate"; then
        print -u2 -- "The new build does not satisfy the installed app's signing requirement. Nothing was replaced."
        print -u2 -- "For an intentional signing migration, use Scripts/install-local.sh --repair-permissions."
        exit 1
    fi
fi
