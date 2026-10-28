#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
temporary="$(mktemp catalog.json.XXXXXX)"
trap 'rm -f "$temporary"' EXIT
nix eval --json --no-write-lock-file .#index | jq . > "$temporary"
case "${1:-}" in
  --check)
    if ! cmp -s catalog.json "$temporary"; then
      echo 'catalog.json is out of date. Run bash scripts/catalog.sh and commit it with the definitions.' >&2
      exit 1
    fi
    ;;
  '')
    chmod 644 "$temporary"
    mv "$temporary" catalog.json
    ;;
  *)
    echo 'Usage: bash scripts/catalog.sh [--check]' >&2
    exit 2
    ;;
esac
