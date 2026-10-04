"""Verify shared modules preserve each preset and copied configurations stand alone."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs)

configs = json.loads(run('nix', 'eval', '--impure', '--json', '--file', str(ROOT / 'tests/templates.nix')))
for name, config in configs.items():
    assert not config['failures'], (name, config['failures'])
    assert config['system'] == ('aarch64-linux' if name == 'base-arm' else 'x86_64-linux'), name
    assert set(config['grub']) == ({'nodev'} if name in ('base-arm', 'azure') else {'/dev/sda'}), name
    assert config['biosPartition'] == (name != 'base-arm'), name
    assert config['desktop'], name
    assert config['azure'] == (name == 'azure'), name
    assert config['earlyoom'] and config['zram'], name
    assert all(p in config['packages'] for p in ('vim', 'ripgrep')), name
    print(f'{name}: architecture, boot, desktop, packages and safeguards passed', flush=True)

with tempfile.TemporaryDirectory(prefix='ryra-copied-template-') as directory:
    copied = Path(directory)
    # Exercise the actual Nix template API, not an in-repository relative import.
    run('nix', 'flake', 'init', '--template', f'path:{ROOT}#default', cwd=copied)
    (copied / 'hostname').write_text('detached\n')
    (copied / 'modules/generated.nix').write_text('{ ... }: { environment.variables.RYRA_COPY_TEST = "present"; }\n')
    run('nix', 'flake', 'lock', '--override-input', 'ryra-template', f'path:{ROOT}', cwd=copied)
    output = json.loads(run('nix', 'eval', '--json', '--override-input', 'ryra-template', f'path:{ROOT}',
        f'path:{copied}#nixosConfigurations.detached.config', '--apply',
        'c: { host = c.networking.hostName; generated = c.environment.variables.RYRA_COPY_TEST; system = c.nixpkgs.hostPlatform.system; }'))
    assert output == {'host': 'detached', 'generated': 'present', 'system': 'x86_64-linux'}, output
    lock = json.loads((copied / 'flake.lock').read_text())
    root_inputs = lock['nodes'][lock['root']]['inputs']
    assert 'nixpkgs' in root_inputs and 'ryra-template' in root_inputs
    shared = lock['nodes'][root_inputs['ryra-template']]
    assert shared['inputs']['nixpkgs'] == ['nixpkgs']
    assert not any(path.is_symlink() for path in copied.rglob('*'))
    print('Detached template: hostname, generated modules and nixpkgs update compatibility passed')
