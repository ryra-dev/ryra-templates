"""Verify presets and the organization assembled from a template."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs)

run('nix', 'eval', '--impure', '--json', '--file', str(ROOT / 'tests/organization.nix'))
print('Organization: named machines, shared sources, SOPS paths and root updates passed', flush=True)

configs = json.loads(run('nix', 'eval', '--impure', '--json', '--file', str(ROOT / 'tests/templates.nix')))
for name, config in configs.items():
    assert not config['failures'], (name, config['failures'])
    assert config['system'] == ('aarch64-linux' if name in ('base-arm', 'lima') else 'x86_64-linux'), name
    assert set(config['grub']) == (set() if name.startswith('lima') else {'nodev'} if name in ('base-arm', 'azure') else {'/dev/sda'}), name
    assert config['biosPartition'] == (name not in ('base-arm', 'lima', 'lima-intel')), name
    assert config['lima'] == name.startswith('lima'), name
    if name.startswith('lima'):
        assert config['bootPaths'] == [{'path': '/boot-nixos', 'efiSysMountPoint': '/boot', 'devices': ['nodev']}], name
        assert config['rootFs'] == 'ext4' and config['espSize'] == '1G', name
        assert config['disk'] == '/dev/vda' and not config['snapshots'], name
    assert config['desktop'] == (not name.startswith('lima')), name
    assert config['azure'] == (name == 'azure'), name
    assert config['earlyoom'] and config['zram'], name
    assert config['buildJobs'] == 1 and config['buildCores'] == 2, name
    assert all(p in config['packages'] for p in ('vim', 'ripgrep')), name
    assert config['timeZone'] == 'UTC' and config['locale'] == 'en_US.UTF-8', name
    assert (ROOT / 'machines' / name / 'modules/machine.nix').is_file(), name
    print(f'{name}: architecture, boot, desktop, packages and safeguards passed', flush=True)

with tempfile.TemporaryDirectory(prefix='ryra-copied-template-') as directory:
    copied = Path(directory)
    # Exercise the actual Nix template API, not an in-repository relative import.
    machine = copied / 'machines/detached'
    machine.mkdir(parents=True)
    run('nix', 'flake', 'init', '--template', f'path:{ROOT}#default', cwd=machine)
    (machine / 'flake.nix').rename(copied / 'flake.nix')
    (copied / 'organization.toml').write_text('[org]\nname = "Test"\n[[machines]]\nname = "detached"\nfrom = "needed"\ntemplate = "ryra/base"\n')
    (machine / 'modules/machine.nix').write_text('{ ... }: { time.timeZone = "Europe/Oslo"; i18n.defaultLocale = "nb_NO.UTF-8"; }\n')
    (machine / 'modules/generated.nix').write_text('{ ... }: { environment.variables.RYRA_COPY_TEST = "present"; nix.settings.max-jobs = 3; nix.settings.cores = 4; }\n')
    nixpkgs = run('nix', 'eval', '--impure', '--raw', '--expr', f'(builtins.getFlake "path:{ROOT}").inputs.nixpkgs.outPath')
    run('nix', 'flake', 'lock', '--override-input', 'ryra-template', f'path:{ROOT}',
        '--override-input', 'nixpkgs', f'path:{nixpkgs}', cwd=copied)
    output = json.loads(run('nix', 'eval', '--json', '--override-input', 'ryra-template', f'path:{ROOT}',
        f'path:{copied}#nixosConfigurations.detached.config', '--apply',
        'c: { host = c.networking.hostName; generated = c.environment.variables.RYRA_COPY_TEST; system = c.nixpkgs.hostPlatform.system; timeZone = c.time.timeZone; locale = c.i18n.defaultLocale; buildJobs = c.nix.settings.max-jobs; buildCores = c.nix.settings.cores; }'))
    assert output == {'host': 'detached', 'generated': 'present', 'system': 'x86_64-linux', 'timeZone': 'Europe/Oslo', 'locale': 'nb_NO.UTF-8', 'buildJobs': 3, 'buildCores': 4}, output
    lock = json.loads((copied / 'flake.lock').read_text())
    root_inputs = lock['nodes'][lock['root']]['inputs']
    assert 'nixpkgs' in root_inputs and 'ryra-template' in root_inputs
    shared = lock['nodes'][root_inputs['ryra-template']]
    assert shared['inputs']['nixpkgs'] == ['nixpkgs']
    assert not any(path.is_symlink() for path in copied.rglob('*'))
    print('Organization template: named output, generated modules and root pins passed')
