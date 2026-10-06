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
choices. All include the GNOME Shell remote desktop by default. The `lima`
(Apple Silicon) and `lima-intel` presets import `ryraModules.lima` for local macOS
VMs and keep their terminal-only defaults. They all use the same modules;
there are no generated or separately maintained copies of the implementation.

For pre-provisioned Azure computers, use the [azure-image](machines/azure-image/README.md)
preset to build a clean Gen 2 VHD with first-boot provisioning and ownership
handoff. It shares the machine modules above; assigned computers use `azure`.

The desktop starts on demand through `ryra desktop`, with automatic sign-in
through the machine's authenticated connection. Closing the viewer leaves the
session running. GNOME Shell runs on Wayland with a private VNC socket.
Set `ryra.desktop.enable = false` for a terminal-only machine.

Each copied machine owns its hostname, `configuration.nix`, generated login and
SOPS modules, and service settings. Its flake references this repository as the
`ryra-template` input. Commit the machine's `flake.lock` to pin that dependency:
upstream edits then take effect only through an explicit input update and deploy.
The copied configuration has no relative imports outside its directory, but it
uses pinned shared source rather than carrying a private copy of every module.

The top-level `nixpkgs` input remains available for Ryra's security-update command;
the shared input follows it. Opt-in automatic updates refresh both `nixpkgs` and
`ryra-template`, including the released Ryra runtime and shared machine modules.

Maintain machine behavior in `modules/`, runtime packages in `agent-runtime/`,
and shared input versions in the root flake and lock. Add machine-specific
configuration in a copied machine's `configuration.nix` or `modules/` directory.
All `.nix` files under that directory are imported except service `settings.nix`,
which is consumed by the service module.

The shared defaults include zram, earlyoom, SSH scheduling and memory protection,
lower build scheduling weights, low-disk Nix garbage collection, a journal cap,
and daily pruning of deployment snapshots older than 30 days while retaining the
newest three per directory. Nix defaults to one build job and two compiler cores;
dedicated builders can override `nix.settings.max-jobs` and `nix.settings.cores`.
Workloads have no hard CPU or RAM quotas.
See [Machine networking](NETWORKING.md) for optional Tailscale and private SSH.
See [Shared folders](SHARED-FOLDERS.md) for named company and project spaces with
individual membership and shortcuts under each person's `~/Shared` directory.

Validation:

```sh
python3 tests/check_templates.py
python3 tests/check_access.py
python3 tests/check_shared_folders.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
nix flake check --no-build --all-systems path:.
```

The template check also initializes a configuration in a temporary directory and
verifies hostname selection, generated-module discovery, and the input structure
used by updates. Live boot, overload, and Tailscale enrollment tests still require
Linux machines. Existing machines made from older copied templates are unchanged.

See [Service credentials and machine delivery](SECRETS.md) for how service setup
uses the generated SOPS/age module without duplicating required keys in templates.

Deployment checks are ordinary executable hooks under `/etc/ryra/deploy/`.
Ryra runs the candidate's `preflight` before activation and `health` before
cancelling rollback, including health verification when the generation is already
active. Existing service backup contracts run during preflight. Templates can add
`ryra.deployment.beforeSwitch`, `requiredUnits`, and `healthChecks`; those scripts
also remain usable without a Ryra account. A failed backup or health check is a
failed deployment, not a successful SSH connection.

## Automatic updates

Updates are opt-in and use NixOS's upgrade timer, Git and SOPS. No Ryra session,
GitHub API, or laptop scheduler is needed. In a copied machine configuration:

```nix
{ config, ... }: {
  sops.secrets.update-git = {}; # Add the scoped SSH key to the machine's SOPS file.
  services.ryra-update = {
    enable = true;
    repository = "ssh://git@forge.example/team/infrastructure.git";
    directory = "machines/server"; # Omit for a repository containing just this machine.
    gitKeyFile = config.sops.secrets.update-git.path;
    authorEmail = "updates@example.com";
  };
  programs.ssh.knownHosts."forge.example".publicKey = "ssh-ed25519 REPLACE_WITH_VERIFIED_HOST_KEY";
}
```

The key needs write access only to this repository. Register its public half for
SSH commit-signature verification on your forge. Only changed pins create a
commit. By default, `nixpkgs` and `ryra-template` update daily at 03:10 with up to ten minutes of
jitter; `herdr-pkgs` stays pinned. Set `inputs = [ "nixpkgs" ];` to retain the
current template and Ryra version. Each machine must have
its own flake directory and lockfile.
Like ryra-org, missed update windows do not trigger catch-up builds when a stopped
machine starts; updates wait for the next scheduled window.

Ryra's release workflows already update `modules/ryra-cli.nix` here after publishing:
`scripts/release-macos.sh templates` computes hashes from the release artifacts
and commits the versioned pin. Machines never fetch an unverified `latest` binary.
Existing deployments need a reviewed template update once to receive this updater
default; existing explicit `inputs` settings remain authoritative.

Only lockfile changes are automatic. Other source changes must first be reviewed
and deployed, after which the updater uses that deployed source as its baseline.
It checks protected package major versions, releases evaluation memory before
building, runs backup/preflight hooks,
and pushes without overwriting concurrent commits before NixOS activates the
candidate. PostgreSQL and Grafana major changes stop for manual migration;
`protectedPackages` can name additional package options.

Reboots are allowed between 01:00 and 06:00. Set `system.autoUpgrade.allowReboot`
or `rebootWindow` to change that policy. Health checks run after activation and
after boot; failure restores the previous system generation. A boot failure still
needs external recovery, and system rollback does not restore application data.

Validate the module and its Git/health guards without changing a machine:

```sh
nix eval --impure --json --file tests/updates.nix
nix eval --impure --json --file tests/azure-image.nix
nix build --impure --no-link --file tests/update-runtime.nix
```
