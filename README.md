# Ryra templates

One repository for Ryra's machine templates, services and shared NixOS modules.
Fork it to maintain your own catalogue. There are no Git submodules or separate
service-repository pins.

- [machines/](machines/): copyable machine configurations, including the base template.
- [services/](services/): deployable applications, external accounts and adapters.
- [modules/](modules/): shared machine configuration.
- [lib/](lib/): service composition, authentication, secrets and backups.

An organization keeps its own declaration and machine configuration.
`lib.mkOrganization` composes those machines using this repository.
Whole organization starters can live here later; none are published today.

Register a fork once for both services and machines:

```sh
ryra catalog --org ORG --add-source team=github:TEAM/ryra-templates
ryra catalog --org ORG
ryra catalog --org ORG --templates
```

Use namespace `ryra` instead of `team` to replace the built-in source.
When forking, set `inputs.ryra-template.url` in
[machines/base/flake.nix](machines/base/flake.nix) to your fork.
Copied machines then share that repository's modules and services through the
organization's one `flake.lock`.

Add services under `services/NAME/default.nix` and machine templates under
`machines/NAME/`, with a `catalog.nix` describing each machine.
The flake discovers these directories and publishes `index.services`,
`index.machines`, `ryraServices` and Nix `templates`.
A fork may contain either kind or both.

Publish metadata after editing definitions:

```sh
bash scripts/catalog.sh
bash scripts/catalog.sh --check
nix eval --json .#validate
```

Commit `catalog.json` with the definitions. Ryra reads it without Nix, using Git
and its configured credentials for remote repositories. `--refresh` fetches a
new revision; Nix is needed when initializing templates or building software.
See the [machine guide](machines/README.md) and [service guide](services/README.md)
for configuration and checks.
