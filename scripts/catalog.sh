#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
temporary="$(mktemp catalog.json.XXXXXX)"
views="$(mktemp views.json.XXXXXX)"
trap 'rm -f "$temporary" "$views" "$views.next"' EXIT
# Views are not Nix, and machines evaluate `index`, so they join only the published catalog.
# A preview is a binary file, which `nix eval` cannot read and Ryra does not fetch beside
# catalog.json, so it goes in as base64.
echo '{}' > "$views"
for directory in views/*/; do
  name="$(basename "$directory")"
  [ -f "$directory/view.base" ] || continue
  entry="$(jq --arg directory "views/$name" --rawfile base "$directory/view.base" \
    '. + {directory: $directory, base: $base}' "$directory/view.json")"
  if [ -f "$directory/preview.png" ]; then
    entry="$(jq --rawfile preview <(base64 < "$directory/preview.png" | tr -d '\n') \
      '. + {preview: $preview}' <<< "$entry")"
  fi
  jq --arg name "$name" --argjson entry "$entry" '. + {($name): $entry}' "$views" > "$views.next"
  mv "$views.next" "$views"
done
nix eval --json --no-write-lock-file .#index | jq --slurpfile views "$views" '. + {views: $views[0]}' > "$temporary"
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
