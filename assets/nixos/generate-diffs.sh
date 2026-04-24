#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

mapfile -t directories < <(find . -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort)

previous=""
for current in *; do
    if [[ ! -d "$current" ]]; then continue ; fi
    if [[ -n "$previous" ]]; then
        diff --label old --label new -u "$previous/flake.nix" "$current/flake.nix" > "$current/flake.nix.diff" || true
    fi
    previous="$current"
done
