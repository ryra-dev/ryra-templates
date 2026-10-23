#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
[[ $(hostname) == ryra-hosting-check && $EUID == 0 ]] || exit 1
umask 077
export SSL_CERT_FILE=/var/lib/pebble-trust/bundle.pem
state=/var/lib/ryra-auth
persist=/var/lib/ryra-auth-test
work=$(mktemp -d)
phase='managed auth readiness'
cleanup() {
  status=$?
  if [[ $status != 0 ]]; then
    echo "Managed auth check failed during $phase at line ${BASH_LINENO[0]}." >&2
    systemctl show ryra-auth-credentials ryra-auth-bootstrap authelia-main lldap grafana nextcloud-oidc linkding-oidc \
      -p Id -p ActiveState -p SubState -p Result -p ExecMainStatus >&2
    journalctl --no-pager -n 60 -u ryra-auth-bootstrap -u authelia-main -u lldap >&2
  fi
  rm -rf "$work"
}
trap cleanup EXIT
issuer=https://apps.example.test:8445
hash_keys() {
  find "$state/keys/current" "$state/clients" -type f -print0 | sort -z | xargs -0 sha256sum
}
login_apps() {
  bash /etc/ryra/test/auth-smoke.sh "$issuer" https://apps.example.test:8444 grafana "$persist/human.json" hosting-person
  bash /etc/ryra/test/auth-smoke.sh "$issuer" https://apps.example.test:8443 nextcloud "$persist/human.json" hosting-person
  bash /etc/ryra/test/auth-smoke.sh "$issuer" https://apps.example.test:8446 linkding "$persist/human.json" hosting-person
}
denied() {
  local user=$1 password_file=$2
  jq -n --arg username "$user" --rawfile password "$password_file" \
    '{username:$username,password:$password,keepMeLoggedIn:false,targetURL:"https://apps.example.test:8444/"}' > "$work/denied.json"
  curl -sS --max-time 20 -H "Origin: $issuer" -H 'Content-Type: application/json' \
    --data-binary "@$work/denied.json" "$issuer/api/firstfactor" > "$work/denied-response"
  jq -e '.status == "KO"' "$work/denied-response" >/dev/null
}
directory_login() {
  jq -n --rawfile password "$state/keys/current/ldap-admin" '{username:"directory-admin",password:($password|rtrimstr("\n"))}' > "$work/ldap-login"
  curl -fsS -H 'Content-Type: application/json' --data-binary "@$work/ldap-login" \
    http://127.0.0.1:17170/auth/simple/login > "$work/ldap-response"
  jq -er '"Authorization: Bearer " + .token' "$work/ldap-response" > "$work/ldap-header"
}
graphql() {
  local query=$1 variables=${2:-'{}'}
  printf '%s' "$variables" | jq --arg query "$query" '{query:$query,variables:.}' > "$work/graphql"
  curl -fsS -H "@$work/ldap-header" -H 'Content-Type: application/json' \
    --data-binary "@$work/graphql" http://127.0.0.1:17170/api/graphql > "$work/graphql-response"
  jq -e '(.errors // [] | length) == 0 and .data != null' "$work/graphql-response" >/dev/null
  jq '.data' "$work/graphql-response"
}
change_password() {
  ldappasswd -x -H ldap://127.0.0.1:3890 -D 'uid=hosting-person,ou=people,dc=ryra,dc=internal' \
    -y "$1" -T "$2" 'uid=hosting-person,ou=people,dc=ryra,dc=internal' >/dev/null
}
systemctl start acme-order-renew-apps.example.test.service
/etc/ryra/deploy/health
nextcloud-occ security:certificates:import /var/lib/pebble-trust/root.pem
if [[ ${1:-} == coldboot ]]; then
  phase='cold boot keys and fresh OIDC login'
  hash_keys > "$work/after-hashes"
  cmp "$persist/keys.sha256" "$work/after-hashes"
  login_apps
  echo 'Managed auth cold boot: keys/client credentials retained and fresh OIDC login passed.'
  exit 0
fi
mkdir -p "$persist"
printf '%s' 'initial-$literal-fixture-password' > "$work/original-password"
jq -n --rawfile password "$work/original-password" '{username:"hosting-person",password:$password}' > "$persist/human.json"
phase='initial literal-dollar password and OIDC identity'
test "$(stat -c %U:%a "$state/clients/grafana/secret")" = root:600
systemctl show grafana -p Requires --value | grep -qw ryra-auth-credentials.service
login_apps
hash_keys > "$persist/keys.sha256"
phase='directory eligibility and internal account denial'
directory_login
graphql 'mutation { createUser(user:{id:"outsider",email:"outsider@example.test",displayName:"Outsider"}) { id } }' >/dev/null
printf '%s' 'outsider-$literal-password' > "$work/outsider-password"
ldappasswd -x -H ldap://127.0.0.1:3890 -D 'uid=directory-admin,ou=people,dc=ryra,dc=internal' \
  -y "$state/keys/current/ldap-admin" -T "$work/outsider-password" 'uid=outsider,ou=people,dc=ryra,dc=internal' >/dev/null
denied outsider "$work/outsider-password"
groups=$(graphql '{groups {id displayName}}')
group_id=$(printf '%s' "$groups" | jq -er '.groups[] | select(.displayName == "service_users") | .id')
for user in directory-admin authelia; do
  graphql 'mutation($user:String!,$group:Int!) { addUserToGroup(userId:$user,groupId:$group) {ok} }' \
    "$(jq -n --arg user "$user" --argjson group "$group_id" '{user:$user,group:$group}')" >/dev/null
done
denied directory-admin "$state/keys/current/ldap-admin"
denied authelia "$state/keys/current/ldap-bind"
echo 'Nonmember and internal directory identities were denied shared sign-in.'
phase='changed password survives bootstrap'
printf '%s' 'changed-$literal-fixture-password' > "$persist/changed-password"
change_password "$work/original-password" "$persist/changed-password"
jq -n --rawfile password "$persist/changed-password" '{username:"hosting-person",password:$password}' > "$persist/human.json"
systemctl restart ryra-auth-bootstrap.service
for _ in {1..30}; do
  if /etc/ryra/deploy/health >/dev/null 2>&1; then break; fi
  sleep 1
done
/etc/ryra/deploy/health
denied hosting-person "$work/original-password"
login_apps
phase='credential and application restarts'
systemctl restart ryra-auth-credentials.service authelia-main.service grafana.service nextcloud-oidc.service \
  linkding-oidc.service linkding-setup.service linkding.service linkding-background-tasks.service
for _ in {1..30}; do
  if /etc/ryra/deploy/health >/dev/null 2>&1; then break; fi
  sleep 1
done
hash_keys > "$work/restarted-hashes"
cmp "$persist/keys.sha256" "$work/restarted-hashes"
login_apps
phase='auth provider real repository backup'
ryra-backup-authelia backup
systemctl is-active --quiet grafana.service linkding.service
phase='post-backup directory, signing and client mutation'
printf '%s' 'post-backup-$literal-password' > "$work/mutated-password"
change_password "$persist/changed-password" "$work/mutated-password"
printf 'damaged fixture signing key\n' > "$state/keys/current/signing"
printf 'damaged fixture client secret\n' > "$state/clients/grafana/secret"
phase='auth provider repository restore and fresh identity'
ryra-backup-authelia restore latest
hash_keys > "$work/restored-hashes"
cmp "$persist/keys.sha256" "$work/restored-hashes"
login_apps
echo 'Managed auth generation, literal-dollar login, eligibility, retained changed password, stable keys/client credentials and local provider restore passed.'
base=$(readlink -f /run/current-system)
phase='custom Nextcloud OIDC beside managed Grafana'
install -m 0600 "$state/clients/nextcloud/secret" /run/ryra-nextcloud-custom-oidc
"$base/specialisation/customAuth/bin/switch-to-configuration" test > "$work/custom.log" 2>&1 || { cat "$work/custom.log" >&2; exit 1; }
login_apps
echo 'Nextcloud external OIDC result and runtime secret work beside managed Grafana.'
phase='switch OIDC apps to their own login'
"$base/specialisation/ownAuth/bin/switch-to-configuration" test > "$work/own.log" 2>&1 || { cat "$work/own.log" >&2; exit 1; }
systemctl is-active --quiet nextcloud-oidc grafana
nextcloud-occ user_oidc:provider --output=json | jq -e 'all(.[]; .identifier != "Ryra")' > /dev/null
phase='Nextcloud own login page and authenticated DAV'
curl -fsS https://apps.example.test:8443/login > "$work/nextcloud-own"
curl -fsS -u 'admin:only-for-this-disposable-guest' -X PROPFIND -H 'Depth: 0' \
  https://apps.example.test:8443/remote.php/dav/files/admin/ > /dev/null
phase='Grafana own password login'
jq -n --rawfile password /run/secrets/grafana-adminpass \
  '{user:"admin",password:($password|rtrimstr("\n"))}' > "$work/grafana-own.json"
curl -fsS -c "$work/grafana-cookies" -H 'Content-Type: application/json' \
  --data-binary "@$work/grafana-own.json" https://apps.example.test:8444/login | jq -e '.message == "Logged in"' > /dev/null
curl -fsS -b "$work/grafana-cookies" https://apps.example.test:8444/api/user | jq -e '.login == "admin" and .isGrafanaAdmin' > /dev/null
phase='Grafana disabled OAuth route'
redirect=$(curl -sS -o /dev/null -w '%{redirect_url}' https://apps.example.test:8444/login/generic_oauth)
[[ "$redirect" == https://apps.example.test:8444/login* ]]
phase='repeat own-login reconciliation'
systemctl restart nextcloud-oidc
nextcloud-occ user_oidc:provider --output=json | jq -e 'all(.[]; .identifier != "Ryra")' > /dev/null
phase='switch back to OIDC and sign in again'
"$base/bin/switch-to-configuration" test > "$work/oidc.log" 2>&1 || { cat "$work/oidc.log" >&2; exit 1; }
login_apps
echo 'Nextcloud and Grafana OIDC to own login, repeated cleanup, native authenticated access and OIDC re-enable passed.'
