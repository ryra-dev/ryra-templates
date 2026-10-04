# ryra-templates

One shared NixOS machine implementation, with small compatibility presets.
Start with `templates.default` (also named `base`) and edit `configuration.nix`:

```nix
{ ... }: {
  nixpkgs.hostPlatform = "x86_64-linux"; # Or aarch64-linux.
  ryra.desktop.enable = true;
  # ryra.tailscale.enable = true; # Requires an enrollment secret.
}
```

For Azure, import `ryraModules.azure` in that module. The existing `base`,
`base-arm`, `azure`, and `desktop` names retain their architecture and platform
choices. All include the GNOME Flashback remote desktop by default. They use the same modules;
there are no generated or separately maintained copies of the implementation.

The desktop starts on demand through `ryra desktop`. Set its per-user password
with `ryra desktop password`; the viewer is available only through the machine's
authenticated connection. Closing the viewer leaves the session running.
Set `ryra.desktop.enable = false` for a terminal-only machine.

Each copied machine owns its hostname, `configuration.nix`, generated login and
SOPS modules, and service settings. Its flake references this repository as the
`ryra-template` input. Commit the machine's `flake.lock` to pin that dependency:
upstream edits then take effect only through an explicit input update and deploy.
The copied configuration has no relative imports outside its directory, but it
uses pinned shared source rather than carrying a private copy of every module.

The top-level `nixpkgs` input remains available for Ryra's security-update command;
the shared input follows it. Updating `ryra-template` is a separate decision.

Maintain machine behavior in `modules/`, runtime packages in `agent-runtime/`,
and shared input versions in the root flake and lock. Add machine-specific
configuration in a copied machine's `configuration.nix` or `modules/` directory.
All `.nix` files under that directory are imported except service `settings.nix`,
which is consumed by the service module.

The shared defaults include zram, earlyoom, SSH scheduling and memory protection,
lower build scheduling weights, low-disk Nix garbage collection, a journal cap,
and daily pruning of deployment snapshots older than 30 days while retaining the
newest three per directory. Workloads have no hard CPU or RAM quotas.
See [Machine networking](NETWORKING.md) for optional Tailscale and private SSH.

Validation:

```sh
python3 tests/check_templates.py
python3 tests/check_access.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
nix flake check --no-build --all-systems path:.
```

The template check also initializes a configuration in a temporary directory and
verifies hostname selection, generated-module discovery, and the input structure
used by updates. Live boot, overload, and Tailscale enrollment tests still require
Linux machines. Existing machines made from older copied templates are unchanged.
