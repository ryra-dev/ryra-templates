"""Check Linux permissions in a disposable Apple Silicon Lima VM; always delete it."""
import json
from pathlib import Path
import platform
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


if platform.system() != "Darwin" or platform.machine() != "arm64":
    raise SystemExit("This runner requires Apple Silicon macOS with Lima; the runtime shell test runs on Linux.")

results = json.loads(subprocess.check_output(
    ["nix", "eval", "--impure", "--json", "--file", str(ROOT / "tests/shared-folders.nix")],
    text=True,
))
case = results["presets"]["lima"]["enabled"]
assert not case["failures"], case["failures"]
vm = "ryra-shared-test-" + uuid.uuid4().hex[:10]
existing = subprocess.check_output(["limactl", "list", "--json"], text=True)
assert all(json.loads(line)["name"] != vm for line in existing.splitlines() if line)
print(f"Disposable test VM: {vm}", flush=True)

with tempfile.TemporaryDirectory(prefix="ryra-shared-test-") as directory:
    temporary = Path(directory)
    spec = temporary / "vm.yaml"
    # A fresh image, never a clone or reconfiguration of a person's running VM.
    spec.write_text('''vmType: vz
arch: aarch64
images:
- location: https://github.com/nixos-lima/nixos-lima/releases/download/v0.2.1/nixos-lima-v0.2.1-aarch64.qcow2
  arch: aarch64
  digest: sha512:748c723b69dbdec40a9acaf78cc9070ae784dcb64b0856ab906efdac822d9abcc65565b8f8dfa4cf8b49cc6c12c372072e83bb5ed9247330a7c22675d9e141ce
cpus: 2
memory: 2GiB
disk: 10GiB
mounts: []
containerd:
  system: false
  user: false
''')
    rules = temporary / "shared.conf"
    rules.write_text("\n".join(case["rules"]) + "\n")
    try:
        run("limactl", "start", "--tty=false", "--name=" + vm, str(spec), timeout=300)
        for source, target in (
            (rules, "/tmp/ryra-shared.conf"),
            (ROOT / "tests/shared-folders-runtime.sh", "/tmp/ryra-shared-test.sh"),
        ):
            run("limactl", "copy", str(source), f"{vm}:{target}", timeout=30)
        run("limactl", "shell", vm, "sudo", "sh", "-x", "/tmp/ryra-shared-test.sh",
            "--disposable-vm", "/tmp/ryra-shared.conf", timeout=90)
    finally:
        # Includes partial creation/startup failure. Only the unique instance we
        # just named is eligible, never pre-existing VMs or cached base images.
        current = subprocess.check_output(["limactl", "list", "--json"], text=True)
        if any(json.loads(line)["name"] == vm for line in current.splitlines() if line):
            run("limactl", "delete", "--force", "--tty=false", vm, timeout=90)
            print(f"Deleted disposable test VM: {vm}", flush=True)
