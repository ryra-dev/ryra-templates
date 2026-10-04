set -euo pipefail
umask 077

action=$1
settings=$2
state=${STATE_DIRECTORY:?}
current=${RYRA_CURRENT_SYSTEM:-/run/current-system}
profile=${RYRA_SYSTEM_PROFILE:-/nix/var/nix/profiles/system}
candidate="$state/candidate"
get() { jq -er ".$1" "$settings"; }
git_at() { git -C "$candidate" "$@"; }

rollback() {
  [[ -e "$state/expected" && -e "$state/previous" ]] || return 0
  # A later manual deployment owns the machine once its closure differs.
  [[ "$(readlink -f "$current")" == "$(cat "$state/expected")" ]] || return 0
  local previous
  previous=$(cat "$state/previous")
  [[ "$previous" == /nix/store/* && -x "$previous/bin/switch-to-configuration" ]]
  nix-env --profile "$profile" --set "$previous"
  "$previous/bin/switch-to-configuration" switch
  echo 'Update failed health checks; restored the previous generation.' >&2
}

verify() {
  [[ -f "$state/expected" ]] || return 0
  local expected
  expected=$(cat "$state/expected")
  if [[ "$(readlink -f "$current")" != "$expected" ]]; then
    echo 'Update is waiting for its scheduled reboot, or a manual deployment superseded it.'
    return 0
  fi
  if ! timeout 60 "$expected/etc/ryra/deploy/health"; then
    rollback
    return 1
  fi
  cp "$state/revision" "$state/last-success"
  rm "$state/expected"
  echo "Verified update $(cat "$state/last-success")"
}

prepare() {
  if [[ -f "$state/expected" ]]; then
    if [[ "$(readlink -f "$profile")" == "$(cat "$state/expected")" &&
          "$(readlink -f "$current")" != "$(cat "$state/expected")" ]]; then
      echo 'Reusing the built candidate while waiting for the reboot window.'
      return 0
    fi
    verify
    rm -f "$state/expected"
  fi

  local branch approved folder lock base derivation target expression versions name before after
  branch=$(get branch)
  approved=$(get source)
  folder=$(get directory)
  lock=flake.lock
  [[ "$folder" == . ]] || lock="$folder/flake.lock"
  git check-ref-format "refs/heads/$branch"
  rm -rf -- "$candidate"
  git clone --single-branch --branch "$branch" -- "$(get repository)" "$candidate"
  base=$(git_at rev-parse HEAD)
  # Restore the reviewed pins before comparing every other source file.
  cp "$approved/flake.lock" "$candidate/$lock"
  if ! diff -qr --no-dereference --exclude=.git "$approved" "$candidate/$folder"; then
    echo 'Repository configuration changed. Review and deploy it before automatic updates resume.' >&2
    return 1
  fi
  # Move only the explicitly selected inputs.
  local inputs=()
  while IFS= read -r name; do inputs+=("$name"); done < <(jq -r '.inputs[]' "$settings")
  nix flake update "${inputs[@]}" --flake "$candidate/$folder"
  git_at config user.name "$(get authorName)"
  git_at config user.email "$(get authorEmail)"
  git_at config gpg.format ssh
  git_at config user.signingkey "${CREDENTIALS_DIRECTORY:?}/git"
  git_at add -- "$lock"
  if ! git_at diff --cached --quiet; then
    git_at commit -S -m 'chore(deps): update NixOS inputs'
  fi
  # No generated source or additional lockfile may enter the build unnoticed.
  [[ -z "$(git_at status --porcelain --untracked-files=all)" ]]
  expression=$(get versionsExpression)
  versions=$(nix eval --no-write-lock-file --json "git+file://$candidate?dir=$folder#nixosConfigurations.$(get configuration)" --apply "$expression")
  while IFS= read -r name; do
    before=$(jq -er --arg name "$name" '.versions[$name]' "$settings")
    after=$(jq -er --arg name "$name" '.[$name]' <<< "$versions")
    if [[ ! "$before" =~ ^[0-9]+\. || ! "$after" =~ ^[0-9]+\. || "${before%%.*}" != "${after%%.*}" ]]; then
      echo "Manual migration required for $name: $before -> $after" >&2
      return 1
    fi
  done < <(jq -r '.versions | keys[]' "$settings")
  # Release the evaluator's heap before compilers start on the running machine.
  derivation=$(nix eval --no-write-lock-file --raw \
    "git+file://$candidate?dir=$folder#nixosConfigurations.$(get configuration).config.system.build.toplevel.drvPath")
  [[ "$derivation" =~ ^/nix/store/[a-z0-9]+-[a-zA-Z0-9.+_-]+\.drv$ ]] || {
    echo 'Nix did not return exactly one system derivation.' >&2
    return 1
  }
  target=$(nix build --out-link "$state/result" --print-out-paths --max-jobs 1 --cores 2 "$derivation^out")
  [[ "$target" == /nix/store/* && "$target" != *$'\n'* ]]
  [[ -x "$target/etc/ryra/deploy/health" ]]
  timeout 900 "$target/etc/ryra/deploy/preflight"
  git_at fetch origin "$branch"
  [[ "$(git_at rev-parse FETCH_HEAD)" == "$base" ]] || {
    echo 'Repository changed during the build; retry on the next run.' >&2
    return 1
  }
  if [[ "$(git_at rev-parse HEAD)" != "$base" ]]; then
    git_at push origin "HEAD:refs/heads/$branch"
  fi
  readlink -f "$current" > "$state/previous"
  git_at rev-parse HEAD > "$state/revision"
  printf '%s\n' "$target" > "$state/expected.next"
  mv "$state/expected.next" "$state/expected"
}

case "$action" in
  prepare) prepare ;;
  verify) verify ;;
  rollback) rollback ;;
  *) echo 'Expected prepare, verify, or rollback' >&2; exit 2 ;;
esac
