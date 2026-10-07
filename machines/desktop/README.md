# ryra/desktop

The x86-64 server preset with standard GNOME Shell on Wayland and automatic
sign-in through Ryra's private remote desktop connection.

Edit `configuration.nix` for architecture, desktop and networking choices.
The organization's root flake pins shared modules through the `ryra-template`
input; commit its root `flake.lock`. Generated logins, SOPS secrets and service
settings stay in this machine's own `modules/` directory.

The preset name does not bind an existing machine to future template edits.

Add local settings in `modules/machine.nix` or another `.nix` file anywhere under
`modules/`; these are imported automatically. `modules/ryra/settings.nix` is
consumed separately by the service module. Leave the generated login and secret
modules to Ryra.

From the organization root, `ryra design . --host <name> --json` evaluates this machine locally,
including on macOS. Read the `eval` result before deploying.
