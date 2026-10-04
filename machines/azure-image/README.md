# Azure prebuilt NixOS image

This preset builds a clean x86-64, Generation 2, fixed VHD directly from NixOS.
It uses the ordinary Ryra modules and disk layout, with Azure first-boot
provisioning and the existing warm-pool ownership handoff. No Debian install or
snapshot of an assigned machine is involved.

Initialize this template, commit its lockfile, then build on an x86-64 Linux
builder with KVM:

```sh
nix flake init -t github:ryra-dev/ryra-templates#azure-image
nix flake lock
nix build .#nixosConfigurations.machine.config.system.build.azureImage
```

The output contains `ryra.vhd` and QEMU's image metadata. Import the VHD into an
Azure Compute Gallery as a generalized Gen 2 Linux image. The default disk is
32 GiB; change `disko.devices.disk.main.imageSize` before building if needed.
No Azure resources are created by this template.

Keep accounts, keys, SOPS secrets and update credentials out of the image.
Boot a disposable VM, verify cloud-init, `ryra-cloud-ready`, the Azure guest
agent's Managed Run Command, and `ryra-pool-handoff --check` before marking a
gallery version ready. Verify two boots produce distinct host keys. The image
must pass Ryra's full ownership-handoff acceptance checks before use in a pool;
Nix evaluation alone does not prove Azure boot or guest-agent compatibility.

After assignment, the organization's machine uses the ordinary `azure` preset:
first-boot provisioning is disabled, generated accounts and secrets belong to
that declaration, and `services.ryra-update` can be enabled with its scoped
repository key. The image inherits the same rollback, health-check and update
modules; it does not contain an operator's infrastructure repository or key.

Image versions are rebuilt with reviewed dependency pins. Pool size, region,
running versus deallocated state, billing and replenishment belong to the
control plane, not to a guest template. Each `services.ryra-control.pools` entry
selects `stopped` or `running`; stopped Azure spares deallocate. Verify a deallocate/start cycle and ownership handoff
on Azure before enabling deallocated inventory.
