# ryra/base

The NixOS machine Ryra installs, deploys and can roll back. There is one template:
what a machine runs on is not a choice. Ryra measures it and writes
`modules/ryra/hardware.json`, its architecture and, where it needs one, the
platform module (`azure`, `lima` or `qemu`), the way NixOS writes
`hardware-configuration.nix`.

The organization's root flake pins shared modules through the `ryra-template`
input; commit its root `flake.lock`. Generated logins, SOPS secrets and service
settings stay in this machine's own `modules/` directory.

Add local settings in `modules/machine.nix` or another `.nix` file anywhere under
`modules/`; these are imported automatically. `modules/ryra/settings.nix` is
consumed separately by the service module. Leave the generated hardware, login and
secret files to Ryra.

From the organization root, `ryra design . --host <name> --json` evaluates this machine locally,
including on macOS. Read the `eval` result before deploying.
