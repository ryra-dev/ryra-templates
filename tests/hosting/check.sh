#!/usr/bin/env bash
set -euo pipefail
[[ "$(hostname)" == ryra-hosting-check && "$EUID" == 0 ]] || {
  echo 'Run this check only as root inside the disposable hosting VM.' >&2
  exit 1
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'printf "Hosting check failed at line %s\n" "$LINENO" >&2; for log in "$work"/linkding*.log; do if [[ -f "$log" ]]; then tail -n 20 "$log" >&2; fi; done; systemctl show restic-backups-linkding.service -p ActiveState -p Result >&2; journalctl --no-pager -n 30 -u restic-backups-linkding.service >&2' ERR
start=$SECONDS
if [[ ${1:-} == cron-firstinstall ]]; then
  for _ in {1..300}; do
    state=$(systemctl show nextcloud-cron.service -p ActiveState --value)
    if [[ "$state" == inactive || "$state" == failed ]]; then break; fi
    sleep 1
  done
  systemctl show nextcloud-cron.service -p ActiveState -p Result -p ExecMainStatus -p ExecMainStartTimestampMonotonic
  systemctl show nextcloud-setup.service -p Result -p ExecMainStatus -p ExecMainExitTimestampMonotonic
  journalctl --no-pager -b -n 40 -u nextcloud-cron.service
  test "$(systemctl show nextcloud-cron.service -p ActiveState --value)" = inactive
  test "$(systemctl show nextcloud-cron.service -p Result --value)" = success
  test "$(systemctl show nextcloud-cron.service -p ExecMainStatus --value)" = 0
  test "$(systemctl show nextcloud-setup.service -p Result --value)" = success
  test "$(systemctl show nextcloud-setup.service -p ExecMainStatus --value)" = 0
  systemctl show nextcloud-cron.service -p Requires --value | grep -qw nextcloud-setup.service
  read -r signature trigger < <(busctl get-property org.freedesktop.systemd1 \
    /org/freedesktop/systemd1/unit/nextcloud_2dcron_2etimer org.freedesktop.systemd1.Timer LastTriggerUSecMonotonic)
  test "$signature" = t
  setup_exit=$(systemctl show nextcloud-setup.service -p ExecMainExitTimestampMonotonic --value)
  cron_start=$(systemctl show nextcloud-cron.service -p ExecMainStartTimestampMonotonic --value)
  test "$trigger" -gt 0
  test "$setup_exit" -gt "$trigger"
  test "$cron_start" -ge "$setup_exit"
  printf 'Expired timer triggered at %s; required setup completed at %s; actual cron.php began at %s and exited0.\n' "$trigger" "$setup_exit" "$cron_start"
  exit 0
fi
check_nextcloud_cron() {
  local failed=false
  if ! systemctl start --wait nextcloud-cron.service; then failed=true; fi
  systemctl show nextcloud-cron.service -p ActiveState -p Result -p ExecMainCode -p ExecMainStatus -p ExecMainStartTimestampMonotonic
  journalctl --no-pager -b -n 40 -u nextcloud-cron.service
  test "$failed" = false
  test "$(systemctl show nextcloud-cron.service -p Result --value)" = success
  test "$(systemctl show nextcloud-cron.service -p ExecMainStatus --value)" = 0
  test "$(systemctl show nextcloud-cron.service -p ExecMainStartTimestampMonotonic --value)" -gt 0
  echo 'Nextcloud cron: actual cron.php completed successfully after native occ ExecCondition.'
}
if [[ ${1:-} == cron-coldboot ]]; then
  check_nextcloud_cron
  exit 0
fi
backup_failure() {
  cat "$1" >&2
  systemctl status restic-backups-nextcloud.service --no-pager --lines=15 >&2 || true
  journalctl -u restic-backups-nextcloud.service --no-pager -n 30 >&2
  exit 1
}
assert_linkding_stopped() {
  if systemctl is-active --quiet linkding.service linkding-background-tasks.service; then
    echo 'A Linkding writer restarted before restore succeeded.' >&2
    exit 1
  fi
}
wait_for_health() {
  for _ in {1..30}; do
    if /etc/ryra/deploy/health > "$work/health.log" 2>&1; then return 0; fi
    sleep 1
  done
  cat "$work/health.log" >&2
  for log in "$work/tls.log" "$work/public.log" "$work/private.log"; do
    if [[ -f "$log" ]]; then tail -n 20 "$log" >&2; fi
  done
  return 1
}
base=$(readlink -f /run/current-system)
export SSL_CERT_FILE=/var/lib/pebble-trust/bundle.pem
wait_for_health
check_nextcloud_cron
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
  local host=$1 port=$2 expected served
  expected=$(openssl x509 -in "/var/lib/acme/$host/cert.pem" -noout -serial)
  for _ in $(seq 1 20); do
    served=$(openssl s_client -connect "127.0.0.1:$port" -servername "$host" </dev/null 2>/dev/null | openssl x509 -noout -serial)
    [[ "$served" == "$expected" ]] && return 0
    sleep 1
  done
  echo 'nginx did not load the issued certificate' >&2
  return 1
}

# The SSH forward has a different browser port from nginx's listening port.
login http://127.0.0.1:8081 127.0.0.1:18081 http://127.0.0.1:18081
echo 'Linkding browser login with a forwarded address: passed'

overlap=/run/ryra-backup-overlap
mkdir -m 0700 "$overlap"
for database in db.sqlite3 tasks.sqlite3; do
  sqlite3 "/var/lib/linkding/$database" "CREATE TABLE ryra_backup_canary(value TEXT); INSERT INTO ryra_backup_canary VALUES ('before-backup');"
done
printf 'before-backup\n' > /var/lib/linkding/ryra-backup-canary
ryra-backup-linkding backup > "$work/linkding-backup.log" 2>&1
test "$(stat -c %U:%a /run/ryra-backup-locks/linkding.lock)" = root:600
for database in db.sqlite3 tasks.sqlite3; do
  sqlite3 "/var/lib/linkding/$database" "UPDATE ryra_backup_canary SET value='after-backup';"
done
printf 'after-backup\n' > /var/lib/linkding/ryra-backup-canary
mkfifo "$overlap/restore-ready" "$overlap/restore-release"
ryra-backup-linkding restore latest > "$work/linkding-restore.log" 2>&1 &
restore_pid=$!
test "$(timeout 30 cat "$overlap/restore-ready")" = ready
assert_linkding_stopped
if ryra-backup-linkding backup > "$work/linkding-skipped-backup.log" 2>&1; then
  echo 'Skipped backup incorrectly reported success during restore.' >&2; exit 1
fi
grep -q 'Backup did not complete (exec-condition)' "$work/linkding-skipped-backup.log"
test "$(cat "$overlap/service-result")" = exec-condition
test "$(systemctl show restic-backups-linkding.service -p Result --value)" = exec-condition
assert_linkding_stopped
printf 'release\n' > "$overlap/restore-release"
wait "$restore_pid"
rm "$overlap/restore-ready" "$overlap/restore-release"
for database in db.sqlite3 tasks.sqlite3; do
  test "$(sqlite3 "/var/lib/linkding/$database" 'SELECT value FROM ryra_backup_canary;')" = before-backup
  test "$(sqlite3 -readonly "/var/lib/linkding/$database" 'PRAGMA integrity_check;')" = ok
done
grep -qx before-backup /var/lib/linkding/ryra-backup-canary
login http://127.0.0.1:8081 127.0.0.1:18081 http://127.0.0.1:18081
echo 'Restore-first overlap: actual SERVICE_RESULT=exec-condition, skipped cleanup left both Linkding writers stopped, SQLite/data/native login restored.'

mkfifo "$overlap/backup-ready" "$overlap/backup-release"
systemctl start --wait restic-backups-linkding.service > "$work/linkding-overlap-backup.log" 2>&1 &
backup_pid=$!
test "$(timeout 30 cat "$overlap/backup-ready")" = ready
test "$(systemctl show restic-backups-linkding.service -p ActiveState --value)" = activating
if ryra-backup-linkding restore latest > "$work/linkding-busy.log" 2>&1; then
  echo 'Restore incorrectly ran while backup was activating.' >&2; exit 1
fi
grep -q 'Backup service is busy (activating)' "$work/linkding-busy.log"
systemctl is-active --quiet linkding.service
systemctl is-active --quiet linkding-background-tasks.service
printf 'release\n' > "$overlap/backup-release"
wait "$backup_pid"
rm "$overlap/backup-ready" "$overlap/backup-release"
if ryra-backup-linkding restore fixture-missing-snapshot > "$work/linkding-failed-restore.log" 2>&1; then
  echo 'Restore incorrectly accepted a missing snapshot.' >&2; exit 1
fi
assert_linkding_stopped
ryra-backup-linkding restore latest > "$work/linkding-recovery.log" 2>&1
login http://127.0.0.1:8081 127.0.0.1:18081 http://127.0.0.1:18081
rm -rf "$overlap"
echo 'Backup-first overlap refused before restore hooks; failed restore retained stopped writers; valid restore recovered native login.'
printf 'Ryra VM persistence check\n' > "$work/content"
curl -fsS --user 'admin:only-for-this-disposable-guest' --upload-file "$work/content" \
  http://127.0.0.1:8082/remote.php/dav/files/admin/hosting-check.txt
curl -fsS --user 'admin:only-for-this-disposable-guest' \
  http://127.0.0.1:8082/remote.php/dav/files/admin/hosting-check.txt | cmp "$work/content" -
cat "$work/content" | curl -fsS --user 'admin:only-for-this-disposable-guest' --upload-file - \
  http://127.0.0.1:8082/remote.php/dav/files/admin/hosting-streamed-check.txt
curl -fsS --user 'admin:only-for-this-disposable-guest' \
  http://127.0.0.1:8082/remote.php/dav/files/admin/hosting-streamed-check.txt | cmp "$work/content" -
echo 'Nextcloud authenticated finite and unknown-length streamed uploads: exact bytes passed before backup'

ryra-backup-nextcloud backup > "$work/backup.log" 2>&1 || backup_failure "$work/backup.log"
curl -fsS --user 'admin:only-for-this-disposable-guest' -X DELETE \
  http://127.0.0.1:8082/remote.php/dav/files/admin/hosting-check.txt
ryra-backup-nextcloud restore latest > "$work/restore.log" 2>&1 || backup_failure "$work/restore.log"
curl -fsS --user 'admin:only-for-this-disposable-guest' \
  http://127.0.0.1:8082/remote.php/dav/files/admin/hosting-check.txt | cmp "$work/content" -
echo 'Nextcloud file and database restore: passed'

"$base/specialisation/privateHttps/bin/switch-to-configuration" test > "$work/tls.log" 2>&1 || {
  cat "$work/tls.log" >&2; exit 1;
}
systemctl start acme-order-renew-apps.example.test.service
wait_for_certificate apps.example.test 8443
wait_for_certificate apps.example.test 8444
wait_for_health
test "$(getent ahostsv4 apps.example.test | awk '{print $1}' | sort -u)" = 127.0.0.1
openssl x509 -in /var/lib/acme/apps.example.test/cert.pem -noout -ext subjectAltName \
  | grep -qx '    DNS:apps.example.test'
guest_address=$(ip -4 -o address show scope global | awk 'NR == 1 {split($4,a,"/"); print a[1]}')
test -n "$guest_address"
challenge=/var/lib/acme/acme-challenge/.well-known/acme-challenge/ryra-private-fixture-token
printf 'private challenge only\n' > "$challenge"
curl -fsS --resolve "apps.example.test:80:$guest_address" http://apps.example.test/.well-known/acme-challenge/ryra-private-fixture-token \
  | grep -qx 'private challenge only'
rm -f "$challenge"
for path in / /login /status.php /api/user /remote.php/dav/ /.well-known/acme-challenge/missing; do
  test "$(curl -sS --resolve "apps.example.test:80:$guest_address" -o /dev/null -w '%{http_code}' "http://apps.example.test$path")" = 404
done
test "$(curl -sS -H 'Host: unrelated.example.test' -o /dev/null -w '%{http_code}' "http://$guest_address/")" = 404
for port in 443 8443 8444; do
  if timeout 3 bash -c "exec 3<>/dev/tcp/\$1/\$2" _ "$guest_address" "$port" 2>/dev/null; then
    echo "Private HTTPS leaked an application listener on $guest_address:$port" >&2
    exit 1
  fi
done
test "$(ss -ltnH | awk '$4 ~ /:844[34]$/ {print $4}' | sort)" = $'127.0.0.1:8443\n127.0.0.1:8444'
nc=https://apps.example.test:8443
grafana=https://apps.example.test:8444
curl -fsS -c "$work/nc-cookies" "$nc/login" > "$work/nc-login"
sed -n 's/.*data-requesttoken="\([^"]*\)".*/requesttoken: \1/p' "$work/nc-login" > "$work/nc-csrf"
test -s "$work/nc-csrf"
curl -fsS --location -b "$work/nc-cookies" -c "$work/nc-cookies" --header "@$work/nc-csrf" \
  --header "Origin: $nc" \
  --data-urlencode 'user=admin' --data-urlencode 'password=only-for-this-disposable-guest' \
  "$nc/login" > "$work/nc-authenticated"
curl -fsS -b "$work/nc-cookies" -H 'OCS-APIRequest: true' "$nc/ocs/v2.php/cloud/user?format=json" \
  | jq -e '.ocs.meta.statuscode == 200 and .ocs.data.id == "admin"' >/dev/null
awk '$6 == "oc_sessionPassphrase" && $4 == "TRUE" {found=1} END {exit !found}' "$work/nc-cookies"
printf '{"user":"admin","password":"only-for-this-disposable-guest"}' > "$work/grafana-login"
curl -fsS -c "$work/grafana-cookies" -H 'Content-Type: application/json' \
  --data-binary "@$work/grafana-login" "$grafana/login" > "$work/grafana-session"
curl -fsS -b "$work/grafana-cookies" "$grafana/api/user" | jq -e '.login == "admin" and .isGrafanaAdmin' >/dev/null
awk '$6 == "grafana_session" && $4 == "TRUE" {found=1} END {exit !found}' "$work/grafana-cookies"
printf '{"username":"admin","password":"only-for-this-disposable-guest"}' > "$work/grafana-admin"
RYRA_GRAFANA_RESTORE_FIXTURE=1 bash /etc/ryra/test/grafana-restore-smoke.sh "$grafana" "$work/grafana-admin"
before=$(openssl x509 -in /var/lib/acme/apps.example.test/cert.pem -noout -serial)
systemctl is-active --quiet acme-renew-apps.example.test.timer
systemctl start acme-order-renew-apps.example.test.service
after=$(openssl x509 -in /var/lib/acme/apps.example.test/cert.pem -noout -serial)
test "$before" != "$after"
wait_for_certificate apps.example.test 8443
wait_for_certificate apps.example.test 8444
curl -fsS "$nc/status.php" | jq -e '.installed and (.maintenance | not)' >/dev/null
curl -fsS "$grafana/api/health" | jq -e '.database == "ok"' >/dev/null
echo 'Private HTTPS: trusted CA, shared exact hostname, native secure-cookie logins, Grafana local repository restore, challenge-only ingress and renewal passed'

"$base/specialisation/public/bin/switch-to-configuration" test > "$work/public.log" 2>&1 || {
  cat "$work/public.log" >&2; exit 1;
}
systemctl start acme-order-renew-bookmarks.example.test.service
wait_for_certificate bookmarks.example.test 443
wait_for_health
test "$(curl -sS -o /dev/null -w '%{http_code}' http://bookmarks.example.test/)" = 301
login https://bookmarks.example.test bookmarks.example.test https://bookmarks.example.test
before=$(openssl x509 -in /var/lib/acme/bookmarks.example.test/cert.pem -noout -serial)
systemctl is-active --quiet acme-renew-bookmarks.example.test.timer
# The test certificate has a deliberately early renewal threshold in vm.nix.
systemctl start acme-order-renew-bookmarks.example.test.service
after=$(openssl x509 -in /var/lib/acme/bookmarks.example.test/cert.pem -noout -serial)
test "$before" != "$after"
wait_for_certificate bookmarks.example.test 443
curl -fsS https://bookmarks.example.test/login/ >/dev/null
echo 'ACME issuance, HTTPS login, certificate renewal and nginx reload: passed'

"$base/bin/switch-to-configuration" test > "$work/private.log" 2>&1 || { cat "$work/private.log" >&2; exit 1; }
wait_for_health
if ss -ltnH | awk '{print $4}' | grep -Eq ':(80|443)$'; then
  echo 'Public listeners remain after restoring private access' >&2
  exit 1
fi
echo "Hosting VM check passed in $((SECONDS-start))s"
