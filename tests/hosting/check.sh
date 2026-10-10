#!/usr/bin/env bash
set -euo pipefail
[[ "$(hostname)" == ryra-hosting-check && "$EUID" == 0 ]] || {
  echo 'Run this check only as root inside the disposable hosting VM.' >&2
  exit 1
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'printf "Hosting check failed at line %s\n" "$LINENO" >&2' ERR
start=$SECONDS
base=$(readlink -f /run/current-system)
export SSL_CERT_FILE=/var/lib/pebble-trust/bundle.pem
/etc/ryra/deploy/health
test "$(jq -r '.linkding.access' /etc/ryra/apps.json)" = private
test "$(jq -r '.nextcloud.access' /etc/ryra/apps.json)" = private
curl -fsS http://127.0.0.1:8082/status.php | jq -e '.installed and (.maintenance | not)' >/dev/null

login() {
  local url=$1 authority=$2 origin=$3
  curl -fsS -H "Host: $authority" -c "$work/cookies" "$url/login/" -o "$work/login.html"
  local csrf status
  csrf=$(sed -n 's/.*name="csrfmiddlewaretoken" value="\([^"]*\)".*/\1/p' "$work/login.html" | head -1)
  test -n "$csrf"
  status=$(curl -sS -H "Host: $authority" -H "Origin: $origin" \
    -b "$work/cookies" -c "$work/cookies" --data-urlencode "csrfmiddlewaretoken=$csrf" \
    --data-urlencode 'username=hosting-check' --data-urlencode 'password=only-for-this-disposable-guest' \
    -o "$work/login-result.html" -w '%{http_code}' "$url/login/")
  if [[ "$status" != 302 ]]; then
    cat "$work/login-result.html" >&2
    echo "Linkding login failed: HTTP $status" >&2
    exit 1
  fi
}

wait_for_certificate() {
  local expected served
  expected=$(openssl x509 -in /var/lib/acme/bookmarks.example.test/cert.pem -noout -serial)
  for attempt in $(seq 1 20); do
    served=$(openssl s_client -connect 127.0.0.1:443 -servername bookmarks.example.test </dev/null 2>/dev/null | openssl x509 -noout -serial)
    [[ "$served" == "$expected" ]] && return 0
    sleep 1
  done
  echo 'nginx did not load the issued certificate' >&2
  return 1
}

# The SSH forward has a different browser port from nginx's listening port.
login http://127.0.0.1:8081 127.0.0.1:18081 http://127.0.0.1:18081
echo 'Linkding browser login with a forwarded address: passed'
printf 'Ryra VM persistence check\n' > "$work/content"
curl -fsS --user 'admin:only-for-this-disposable-guest' --upload-file "$work/content" \
  http://127.0.0.1:8082/remote.php/dav/files/admin/hosting-check.txt
curl -fsS --user 'admin:only-for-this-disposable-guest' \
  http://127.0.0.1:8082/remote.php/dav/files/admin/hosting-check.txt | cmp "$work/content" -
echo 'Nextcloud authenticated upload and download: passed'

ryra-backup-nextcloud backup > "$work/backup.log" 2>&1 || { cat "$work/backup.log" >&2; exit 1; }
curl -fsS --user 'admin:only-for-this-disposable-guest' -X DELETE \
  http://127.0.0.1:8082/remote.php/dav/files/admin/hosting-check.txt
ryra-backup-nextcloud restore latest > "$work/restore.log" 2>&1 || { cat "$work/restore.log" >&2; exit 1; }
curl -fsS --user 'admin:only-for-this-disposable-guest' \
  http://127.0.0.1:8082/remote.php/dav/files/admin/hosting-check.txt | cmp "$work/content" -
echo 'Nextcloud file and database restore: passed'

"$base/specialisation/public/bin/switch-to-configuration" test > "$work/public.log" 2>&1 || {
  cat "$work/public.log" >&2; exit 1;
}
systemctl start acme-order-renew-bookmarks.example.test.service
wait_for_certificate
/etc/ryra/deploy/health
test "$(curl -sS -o /dev/null -w '%{http_code}' http://bookmarks.example.test/)" = 301
login https://bookmarks.example.test bookmarks.example.test https://bookmarks.example.test
before=$(openssl x509 -in /var/lib/acme/bookmarks.example.test/cert.pem -noout -serial)
systemctl is-active --quiet acme-renew-bookmarks.example.test.timer
# The test certificate has a deliberately early renewal threshold in vm.nix.
systemctl start acme-order-renew-bookmarks.example.test.service
after=$(openssl x509 -in /var/lib/acme/bookmarks.example.test/cert.pem -noout -serial)
test "$before" != "$after"
wait_for_certificate
curl -fsS https://bookmarks.example.test/login/ >/dev/null
echo 'ACME issuance, HTTPS login, certificate renewal and nginx reload: passed'

"$base/bin/switch-to-configuration" test > "$work/private.log" 2>&1 || { cat "$work/private.log" >&2; exit 1; }
/etc/ryra/deploy/health
if ss -ltnH | awk '{print $4}' | grep -Eq ':(80|443)$'; then
  echo 'Public listeners remain after restoring private access' >&2
  exit 1
fi
echo "Hosting VM check passed in $((SECONDS-start))s"
