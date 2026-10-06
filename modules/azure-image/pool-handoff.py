"""One-way ownership handoff for a clean Azure Ryra image, run as root by waagent."""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

STATE = Path('/var/lib/ryra-pool')

def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout

def write(path, text, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.ryra-new')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, 'w') as stream:
        os.fchmod(stream.fileno(), mode)
        stream.write(text)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)

def payload(encoded):
    if len(encoded) > 100000:
        raise ValueError('Handoff is too large')
    data = json.loads(base64.b64decode(encoded, validate=True))
    if not re.fullmatch(r'[a-zA-Z0-9-]{1,100}', data['owner']):
        raise ValueError('Invalid owner')
    access = data['access']
    accounts = access['accounts']
    if len(set(accounts)) != len(accounts) or any(
        not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', name)
        or name in ('root', 'ryra-bootstrap') for name in accounts
    ):
        raise ValueError('Invalid account')
    keys = access['root_keys'] + ([access['trusted_ca']] if access.get('trusted_ca') else [])
    if not keys or any(len(key) > 8192 or '\n' in key or '\r' in key
                       or not key.startswith(('ssh-ed25519 ', 'ssh-rsa ')) for key in keys):
        raise ValueError('Invalid keys')
    return data

def erase_bootstrap():
    for home in ('/root', '/home/ryra-bootstrap'):
        Path(home, '.ssh/authorized_keys').unlink(missing_ok=True)
    Path('/etc/ssh/authorized_keys.d/ryra-bootstrap').unlink(missing_ok=True)
    Path('/etc/ssh/authorized_keys.d/root').unlink(missing_ok=True)

def handoff(encoded):
    data = payload(encoded)
    digest = hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()
    owner = STATE / 'owner'
    if owner.exists() and owner.read_text() != digest:
        raise ValueError('This computer already belongs to another purchase')
    if not (STATE / 'ready').exists():
        raise ValueError('The image has not passed its warm-pool check')
    # Persist ownership before the first access mutation. A partial failure can
    # resume only the exact same purchase; it can never become inventory again.
    if not owner.exists():
        for name in data['access']['accounts']:
            if subprocess.run(['id', '-u', name], capture_output=True).returncode == 0:
                raise ValueError('Customer account already exists in the base image')
    write(owner, digest)
    if (STATE / 'assigned').exists():
        return
    run('ryra-cloud-ready')
    erase_bootstrap()
    access = data['access']
    ca = access.get('trusted_ca')
    accounts = ['root'] + access['accounts']
    for name in accounts:
        if name != 'root':
            # Existing non-root identities would make this an unsafe base image.
            found = subprocess.run(['id', '-u', name], capture_output=True).returncode == 0
            if not found:
                run('useradd', '--create-home', '--shell', '/bin/bash', name)
            write('/etc/sudoers.d/ryra-pool-' + name, name + ' ALL=(ALL) NOPASSWD:ALL\n', 0o440)
        run('usermod', '--password', '*', name)
        run('chage', '-d', '1', '-M', '-1', '-E', '-1', name)
        run('loginctl', 'enable-linger', name)
        # Root-owned keys avoid relying on a guest account's writable home.
        keys = access['root_keys'] if name == 'root' or not ca else []
        write('/etc/ssh/authorized_keys.d/' + name, '\n'.join(keys) + '\n', 0o644)
        if ca:
            write('/etc/ssh/principals/' + name, name + '\n', 0o644)
    if ca:
        write('/etc/ssh/ryra_pool_ca.pub', ca + '\n', 0o644)
    config = ('PasswordAuthentication no\nKbdInteractiveAuthentication no\n'
              'PermitEmptyPasswords no\nPermitRootLogin prohibit-password\n'
              'AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u\n'
              'AllowUsers ' + ' '.join(accounts) + '\n'
              'TrustedUserCAKeys ' + ('/etc/ssh/ryra_pool_ca.pub' if ca else 'none') + '\n'
              'AuthorizedPrincipalsFile /etc/ssh/principals/%u\n')
    write('/etc/ssh/sshd_config.d/00-ryra-pool.conf', config, 0o644)
    run('sshd', '-t')
    effective = {}
    for line in run('sshd', '-T').splitlines():
        keyword, *values = line.split()
        effective.setdefault(keyword.lower(), []).extend(values)
    for keyword, values in {
        'passwordauthentication': ['no'],
        'kbdinteractiveauthentication': ['no'],
        'authorizedkeysfile': ['/etc/ssh/authorized_keys.d/%u'],
        'trustedusercakeys': ['/etc/ssh/ryra_pool_ca.pub' if ca else 'none'],
        'allowusers': accounts,
        'authorizedprincipalsfile': ['/etc/ssh/principals/%u'],
    }.items():
        if effective.get(keyword) != values:
            raise ValueError('SSH configuration did not apply: ' + keyword + ' ' + ' '.join(values))
    run('systemctl', 'restart', 'sshd')
    run('systemctl', 'is-active', '--quiet', 'sshd')
    write(STATE / 'assigned', digest)

def main():
    if os.geteuid() != 0:
        raise ValueError('Root is required')
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (STATE / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if sys.argv[1:] == ['--check']:
            if (STATE / 'owner').exists():
                raise ValueError('Assigned computers cannot return to the pool')
            run('cloud-init', 'status', '--wait')
            run('ryra-cloud-ready')
            erase_bootstrap()
            write(STATE / 'ready', '1')
        elif len(sys.argv) == 2:
            handoff(sys.argv[1])
            print(Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().strip())
        else:
            raise ValueError('Expected --check or purchase payload')

if __name__ == '__main__':
    main()
