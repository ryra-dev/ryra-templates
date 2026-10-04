set -euo pipefail
script=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
export STATE_DIRECTORY="$work/state" CREDENTIALS_DIRECTORY="$work/credentials"
export RYRA_CURRENT_SYSTEM="$work/current" RYRA_SYSTEM_PROFILE="$work/profile"
export TEST_EVENTS="$work/events"
mkdir -p "$work/bin" "$STATE_DIRECTORY" "$CREDENTIALS_DIRECTORY"
ssh-keygen -q -t ed25519 -N '' -f "$CREDENTIALS_DIRECTORY/git"
printf 'test@example.invalid %s\n' "$(cat "$CREDENTIALS_DIRECTORY/git.pub")" > "$work/signers"
git init -q --bare --initial-branch=main "$work/origin"
git clone -q "$work/origin" "$work/source"
printf '{}\n' > "$work/source/flake.lock"
printf 'reviewed configuration\n' > "$work/source/flake.nix"
git -C "$work/source" add .
git -C "$work/source" commit -qm initial
git -C "$work/source" push -q origin main
cp -r "$work/source" "$work/reviewed"
rm -rf "$work/reviewed/.git"
export TEST_WRITER="$work/source"
jq -n --arg repository "$work/origin" --arg source "$work/reviewed" '{
  repository: $repository, source: $source, branch: "main", directory: ".",
  configuration: "machine", inputs: ["nixpkgs", "ryra-template"], authorName: "Test",
  authorEmail: "test@example.invalid", versions: {postgresql: "17.1"}, versionsExpression: "test"
}' > "$work/settings.json"
cat > "$work/bin/nix" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  flake)
    [[ "$2 $3 $4 $5" == 'update nixpkgs ryra-template --flake' ]]
    printf '%s\n' "${TEST_LOCK:-{\"updated\":true}}" > "$6/flake.lock"
    ;;
  eval)
    if [[ " $* " == *' --raw '* ]]; then
      printf '%s\n' "$$" > "$STATE_DIRECTORY/evaluator-pid"
      [[ "${EVAL_STATUS:-0}" == 0 ]] || exit 137
      printf '%s\n' "${TEST_DERIVATION:-/nix/store/00000000000000000000000000000000-system.drv}"
    else
      printf '{"postgresql":"%s"}\n' "${TEST_VERSION:-17.2}"
    fi
    ;;
  build)
    ! kill -0 "$(cat "$STATE_DIRECTORY/evaluator-pid")" 2>/dev/null
    [[ "${!#}" == '/nix/store/00000000000000000000000000000000-system.drv^out' ]]
    [[ " $* " == *' --max-jobs 1 '* && " $* " == *' --cores 2 '* ]]
    printf 'build\n' >> "$STATE_DIRECTORY/builds"
    [[ "${BUILD_STATUS:-0}" == 0 ]] || exit 1
    if [[ "${TEST_RACE:-0}" == 1 ]]; then
      git -C "$TEST_WRITER" pull -q --ff-only
      git -C "$TEST_WRITER" commit -q --allow-empty -m concurrent
      git -C "$TEST_WRITER" push -q
    fi
    printf '%s\n' "$RYRA_UPDATE_TEST_TARGET"
    ;;
  *) exit 2 ;;
esac
MOCK
cat > "$work/bin/nix-env" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --profile && "$3" == --set ]]
ln -sfn "$4" "$2"
MOCK
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"
ln -s "$RYRA_UPDATE_TEST_TARGET" "$RYRA_CURRENT_SYSTEM"
ln -s "$RYRA_UPDATE_TEST_TARGET" "$RYRA_SYSTEM_PROFILE"
head() { git --git-dir="$work/origin" rev-parse main; }
run() { bash "$script" "$1" "$work/settings.json"; }
refused() {
  local before
  before=$(head)
  rm -f "$STATE_DIRECTORY/expected"
  if run prepare; then echo 'Unsafe update was accepted' >&2; exit 1; fi
  [[ "$(head)" == "$before" && ! -f "$STATE_DIRECTORY/expected" ]]
}

run prepare
[[ "$(git --git-dir="$work/origin" rev-list --count main)" == 2 ]]
git --git-dir="$work/origin" -c gpg.ssh.allowedSignersFile="$work/signers" verify-commit main
run verify
[[ -f "$STATE_DIRECTORY/last-success" && ! -f "$STATE_DIRECTORY/expected" ]]
before=$(head)
run prepare
[[ "$(head)" == "$before" ]]
run verify

export TEST_VERSION=18.0
refused
unset TEST_VERSION
before_builds=$(wc -l < "$STATE_DIRECTORY/builds")
export EVAL_STATUS=137
refused
unset EVAL_STATUS
export TEST_DERIVATION=$'/nix/store/one.drv\n/nix/store/two.drv'
refused
unset TEST_DERIVATION
[[ "$(wc -l < "$STATE_DIRECTORY/builds")" == "$before_builds" ]]
export BUILD_STATUS=1
refused
unset BUILD_STATUS
export PREFLIGHT_STATUS=1
refused
unset PREFLIGHT_STATUS
printf 'unreviewed change\n' >> "$work/reviewed/flake.nix"
refused
printf 'reviewed configuration\n' > "$work/reviewed/flake.nix"

export TEST_RACE=1
before=$(head)
if run prepare; then echo 'Concurrent push was overwritten' >&2; exit 1; fi
[[ "$(head)" != "$before" && ! -f "$STATE_DIRECTORY/expected" ]]
unset TEST_RACE

run prepare
export HEALTH_STATUS=1
if run verify; then echo 'Failed health check was accepted' >&2; exit 1; fi
[[ "$(cat "$TEST_EVENTS")" == rollback ]]
rm "$TEST_EVENTS"
ln -sfn /nix/store/manually-deployed-system "$RYRA_CURRENT_SYSTEM"
run rollback
[[ ! -e "$TEST_EVENTS" ]]
echo 'Updater: signed changes, no-op, source drift, major versions, evaluator exit, evaluation/build/preflight failures, concurrent pushes, health and rollback guards passed.'
