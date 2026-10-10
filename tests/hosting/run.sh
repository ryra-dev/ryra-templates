#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 && -r /dev/kvm && -w /dev/kvm ]] || {
  echo 'Run this check on a Linux x86-64 host with access to /dev/kvm.' >&2
  exit 1
}
for command in nix ssh ssh-keygen ss setsid; do command -v "$command" >/dev/null; done
if ss -ltnH | awk '{print $4}' | grep -q ':22259$'; then
  echo 'Test SSH port 22259 is already in use. No VM was started.' >&2
  exit 1
fi
export RYRA_HOSTING_TEMPLATES
RYRA_HOSTING_TEMPLATES=$(cd "$(dirname "$0")/../.." && pwd)
export RYRA_HOSTING_SOURCE="${1:-}"
work=$(mktemp -d /var/tmp/ryra-hosting.XXXXXX)
runner=
cleanup() {
  if [[ -n "$runner" ]]; then
    kill -- "-$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
umask 077
mkdir "$work/keys" "$work/runtime"
export RYRA_HOSTING_KEYS="$work/keys"
nix_args=(--extra-experimental-features 'nix-command flakes')
toolset=$(nix "${nix_args[@]}" build --impure --no-link --print-out-paths --expr '
  let f = builtins.getFlake ("path:" + builtins.getEnv "RYRA_HOSTING_TEMPLATES");
      pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  in pkgs.symlinkJoin { name = "hosting-test-tools"; paths = [ pkgs.age pkgs.sops ]; }')
ssh-keygen -q -t ed25519 -N '' -C ryra-disposable-hosting-check -f "$work/keys/ssh"
"$toolset/bin/age-keygen" -o "$work/keys/age-key.txt"
recipient=$("$toolset/bin/age-keygen" -y "$work/keys/age-key.txt")
"$toolset/bin/sops" --config /dev/null --encrypt --age "$recipient" --input-type yaml --output-type yaml /dev/stdin > "$work/keys/secrets.yaml" <<'SECRETS'
linkding-admin: |
  LD_SUPERUSER_NAME=hosting-check
  LD_SUPERUSER_PASSWORD=only-for-this-disposable-guest
nextcloud-adminpass: only-for-this-disposable-guest
restic-linkding: only-for-this-disposable-guest
restic-nextcloud: only-for-this-disposable-guest
SECRETS
nix "${nix_args[@]}" build --impure --out-link "$work/vm" --expr '
  import (builtins.getEnv "RYRA_HOSTING_TEMPLATES" + "/tests/hosting/vm.nix") {
    secretsDirectory = builtins.getEnv "RYRA_HOSTING_KEYS";
    serviceSource = let source = builtins.getEnv "RYRA_HOSTING_SOURCE";
      in if source == "" then null else source;
  }'
cd "$work"
USE_TMPDIR=1 TMPDIR="$work/runtime" setsid "$work/vm/bin/run-ryra-hosting-check-vm" > "$work/console.log" 2>&1 < /dev/null &
runner=$!
guest=(ssh -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$work/keys/known_hosts" -i "$work/keys/ssh" -p 22259 root@127.0.0.1)
ready=false
for attempt in $(seq 1 150); do
  if "${guest[@]}" -n /etc/ryra/deploy/health > "$work/ready.log" 2>&1; then ready=true; break; fi
  kill -0 "$runner" 2>/dev/null || break
  sleep 2
done
if [[ "$ready" != true ]]; then cat "$work/ready.log" >&2; tail -40 "$work/console.log" >&2; exit 1; fi
"${guest[@]}" bash -s < "$RYRA_HOSTING_TEMPLATES/tests/hosting/check.sh"
boot=$("${guest[@]}" -n cat /proc/sys/kernel/random/boot_id)
"${guest[@]}" -n reboot || [[ "$?" == 255 ]]
ready=false
for attempt in $(seq 1 90); do
  current=$("${guest[@]}" -n cat /proc/sys/kernel/random/boot_id 2>/dev/null) || current=
  if [[ -n "$current" && "$current" != "$boot" ]] && "${guest[@]}" -n /etc/ryra/deploy/health > "$work/ready.log" 2>&1; then ready=true; break; fi
  sleep 2
done
[[ "$ready" == true ]] || { cat "$work/ready.log" >&2; exit 1; }
"${guest[@]}" -n "curl -fsS --user 'admin:only-for-this-disposable-guest' http://127.0.0.1:8082/remote.php/dav/files/admin/hosting-check.txt" | grep -qx 'Ryra VM persistence check'
echo 'Cold boot and restored file persistence: passed'
