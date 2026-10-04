#!/bin/sh
# Run only in a disposable Linux VM, with the rules from shared-folders.nix.
set -eu
test "${1:-}" = "--disposable-vm" && test "$(id -u)" = 0 || {
  echo "Requires root in a disposable VM and --disposable-vm RULES" >&2
  exit 1
}
rules=$2
for person in alice bob carol; do
  if id "$person" >/dev/null 2>&1; then
    echo "Refusing to touch existing account $person" >&2
    exit 1
  fi
done
test ! -e /srv/shared

groupadd ryra-shared-company
groupadd ryra-shared-research
for person in alice bob carol; do groupadd "$person"; done
useradd -m -g alice -G ryra-shared-company,ryra-shared-research -s /bin/sh alice
useradd -m -g bob -G ryra-shared-company -d '/home/bob work' -s /bin/sh bob
useradd -m -g carol -s /bin/sh carol
chmod 0700 /home/alice '/home/bob work' /home/carol

systemd-tmpfiles --create "$rules"
test "$(readlink /home/alice/Shared/Company)" = /srv/shared/company
test "$(readlink '/home/alice/Shared/Research notes')" = /srv/shared/research
test "$(readlink '/home/bob work/Shared/Company')" = /srv/shared/company
test ! -e /home/carol/Shared
test ! -e '/home/bob work/Shared/Research notes'

runuser -u alice -- sh -c 'umask 077; mkdir "$1/nested"; printf "alice\n" > "$1/nested/note"' sh /home/alice/Shared/Company
runuser -u bob -- sh -c 'printf "bob\n" >> "$1/nested/note"; printf "bob\n" > "$1/from-bob"' sh '/home/bob work/Shared/Company'
runuser -u alice -- sh -c 'printf "alice\n" >> "$1/from-bob"' sh /srv/shared/company
test "$(stat -c %a /srv/shared/company/nested/note)" = 660
test "$(stat -c %G /srv/shared/company/nested/note)" = ryra-shared-company
test "$(wc -l < /srv/shared/company/nested/note)" -eq 2

if runuser -u carol -- cat /srv/shared/company/nested/note; then exit 1; fi
if runuser -u bob -- ls /srv/shared/research; then exit 1; fi
if runuser -u bob -- ls /home/alice; then exit 1; fi
if runuser -u carol -- ls /srv/shared; then exit 1; fi
echo "Separate users: shared edits, inherited permissions and denied unrelated access passed"


# Re-activation preserves contents and does not redirect a user's existing item.
systemd-tmpfiles --create "$rules"
test "$(wc -l < /srv/shared/company/nested/note)" -eq 2
runuser -u bob -- sh -c 'rm "$1/Company"; mkdir "$1/Company"; printf "keep" > "$1/Company/personal"' sh '/home/bob work/Shared'
systemd-tmpfiles --create "$rules"
test ! -L '/home/bob work/Shared/Company'
test "$(cat '/home/bob work/Shared/Company/personal')" = keep
runuser -u bob -- sh -c 'rm "$1/Company/personal"; rmdir "$1/Company"; printf "keep-file" > "$1/Company"' sh '/home/bob work/Shared'
systemd-tmpfiles --create "$rules"
test "$(cat '/home/bob work/Shared/Company')" = keep-file
runuser -u bob -- sh -c 'rm "$1/Company"; ln -s /home/carol "$1/Company"' sh '/home/bob work/Shared'
systemd-tmpfiles --create "$rules"
test "$(readlink '/home/bob work/Shared/Company')" = /home/carol
echo "Re-activation and existing directories, files and symlinks are preserved"

# A user-controlled parent link must not redirect privileged directory setup.
runuser -u bob -- sh -c 'mv "$1/Shared" "$1/Shared-kept"; ln -s /srv/shared/research "$1/Shared"' sh '/home/bob work'
systemd-tmpfiles --create "$rules" || true
test "$(stat -c %U /srv/shared/research)" = root
test "$(stat -c %a /srv/shared/research)" = 2770
test ! -e /srv/shared/research/Company
if runuser -u bob -- ls /srv/shared/research; then exit 1; fi
echo "A replaced Shared parent cannot redirect setup into another team's space"

# Fresh sessions lose access when membership is withdrawn, even with a shortcut.
usermod -G '' bob
if runuser -u bob -- cat /srv/shared/company/nested/note; then exit 1; fi
runuser -u alice -- cat /srv/shared/company/nested/note >/dev/null
echo "Membership removal denies new sessions without deleting shared documents"
