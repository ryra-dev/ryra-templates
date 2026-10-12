#!/usr/bin/env bash
set -euo pipefail
while IFS= read -r variable; do
  case "$variable" in
    HERDR_*|RYRA_HERDR_*|*_PANE_ID|*_SESSION_ID|*_TAB_ID|*_WORKSPACE_ID|DBUS_SESSION_BUS_ADDRESS) unset "$variable" ;;
  esac
done < <(compgen -e)
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
export RYRA_HOSTING_MANAGED="${2:-}"
[[ -z "$RYRA_HOSTING_MANAGED" || "$RYRA_HOSTING_MANAGED" == managed || "$RYRA_HOSTING_MANAGED" == cron ]] || { echo 'Unknown hosting fixture.' >&2; exit 2; }
work=$(mktemp -d /var/tmp/ryra-hosting.XXXXXX)
runner=
guest=()
cleanup() {
  if [[ "$?" != 0 && ${#guest[@]} != 0 ]]; then
    "${guest[@]}" -n 'systemctl show ryra-auth-credentials ryra-auth-bootstrap authelia-main lldap grafana nextcloud-oidc linkding-oidc acme-order-renew-apps.example.test -p Id -p ActiveState -p SubState -p Result -p ExecMainStatus; journalctl --no-pager -n 70 -u ryra-auth-credentials -u ryra-auth-bootstrap -u authelia-main -u lldap -u grafana -u nextcloud-oidc -u linkding-oidc; journalctl --no-pager -n 35 -u acme-order-renew-apps.example.test' \
      | sed -E 's/authelia_at_[a-zA-Z0-9._-]+/[redacted access token]/g' >&2 || true
  fi
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
  in pkgs.symlinkJoin { name = "hosting-test-tools"; paths = [ pkgs.age pkgs.sops pkgs.openssl ]; }')
ssh-keygen -q -t ed25519 -N '' -C ryra-disposable-hosting-check -f "$work/keys/ssh"
"$toolset/bin/age-keygen" -o "$work/keys/age-key.txt"
recipient=$("$toolset/bin/age-keygen" -y "$work/keys/age-key.txt")
cat > "$work/secrets-plain.yaml" <<'SECRETS'
linkding-admin: |
  LD_SUPERUSER_NAME=hosting-check
  LD_SUPERUSER_PASSWORD=only-for-this-disposable-guest
nextcloud-adminpass: only-for-this-disposable-guest
grafana-secret-key: only-for-this-disposable-guest-encryption-key
restic-linkding: only-for-this-disposable-guest
restic-nextcloud: only-for-this-disposable-guest
restic-grafana: only-for-this-disposable-guest
authelia-admin: |
  INITIAL_USERNAME=hosting-person
  INITIAL_EMAIL=hosting-person@example.test
  INITIAL_PASSWORD=initial-$literal-fixture-password
restic-authelia: only-for-this-disposable-guest
SECRETS
if [[ "$RYRA_HOSTING_MANAGED" == managed ]]; then
  printf 'grafana-adminpass: %s\n' "$("$toolset/bin/openssl" rand -hex 32)" >> "$work/secrets-plain.yaml"
else
  printf 'grafana-adminpass: only-for-this-disposable-guest\n' >> "$work/secrets-plain.yaml"
fi
"$toolset/bin/sops" --config /dev/null --encrypt --age "$recipient" --input-type yaml --output-type yaml "$work/secrets-plain.yaml" > "$work/keys/secrets.yaml"
rm "$work/secrets-plain.yaml"
nix "${nix_args[@]}" build --impure --out-link "$work/vm" --expr '
  import (builtins.getEnv "RYRA_HOSTING_TEMPLATES" + "/tests/hosting/vm.nix") {
    secretsDirectory = builtins.getEnv "RYRA_HOSTING_KEYS";
    managedAuth = builtins.getEnv "RYRA_HOSTING_MANAGED" == "managed";
    cronOrdering = builtins.getEnv "RYRA_HOSTING_MANAGED" == "cron";
    serviceSource = let source = builtins.getEnv "RYRA_HOSTING_SOURCE";
      in if source == "" then null else source;
  }'
cd "$work"
USE_TMPDIR=1 TMPDIR="$work/runtime" setsid "$work/vm/bin/run-ryra-hosting-check-vm" > "$work/console.log" 2>&1 < /dev/null &
runner=$!
guest=(ssh -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$work/keys/known_hosts" -i "$work/keys/ssh" -p 22259 root@127.0.0.1)
ready=false
for _ in $(seq 1 300); do
  if "${guest[@]}" -n /etc/ryra/deploy/health > "$work/ready.log" 2>&1; then ready=true; break; fi
  kill -0 "$runner" 2>/dev/null || break
  sleep 2
done
if [[ "$ready" != true ]]; then cat "$work/ready.log" >&2; tail -40 "$work/console.log" >&2; exit 1; fi
if [[ "$RYRA_HOSTING_MANAGED" == managed ]]; then
  "${guest[@]}" bash -s < "$RYRA_HOSTING_TEMPLATES/tests/hosting/managed-check.sh"
elif [[ "$RYRA_HOSTING_MANAGED" == cron ]]; then
  "${guest[@]}" bash -s -- cron-firstinstall < "$RYRA_HOSTING_TEMPLATES/tests/hosting/check.sh"
else
  "${guest[@]}" bash -s < "$RYRA_HOSTING_TEMPLATES/tests/hosting/check.sh"
fi
boot=$("${guest[@]}" -n cat /proc/sys/kernel/random/boot_id)
"${guest[@]}" -n reboot || [[ "$?" == 255 ]]
ready=false
for _ in $(seq 1 90); do
  current=$("${guest[@]}" -n cat /proc/sys/kernel/random/boot_id 2>/dev/null) || current=
  if [[ -n "$current" && "$current" != "$boot" ]] && "${guest[@]}" -n /etc/ryra/deploy/health > "$work/ready.log" 2>&1; then ready=true; break; fi
  sleep 2
done
[[ "$ready" == true ]] || { cat "$work/ready.log" >&2; exit 1; }
if [[ "$RYRA_HOSTING_MANAGED" == managed ]]; then
  "${guest[@]}" bash -s -- coldboot < "$RYRA_HOSTING_TEMPLATES/tests/hosting/managed-check.sh"
elif [[ "$RYRA_HOSTING_MANAGED" == cron ]]; then
  "${guest[@]}" bash -s -- cron-firstinstall < "$RYRA_HOSTING_TEMPLATES/tests/hosting/check.sh"
else
  "${guest[@]}" bash -s -- cron-coldboot < "$RYRA_HOSTING_TEMPLATES/tests/hosting/check.sh"
  "${guest[@]}" -n "curl -fsS --user 'admin:only-for-this-disposable-guest' http://127.0.0.1:8082/remote.php/dav/files/admin/hosting-check.txt" | grep -qx 'Ryra VM persistence check'
  echo 'Cold boot and restored file persistence: passed'
fi
