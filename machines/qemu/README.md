# ryra/qemu

A local x86-64 NixOS guest using KVM and the normal Ryra machine modules.
Build `nixosConfigurations.<name>.config.system.build.vm` from the organization
flake, then run the generated `bin/run-<name>-vm` script. The host user needs
read and write access to `/dev/kvm`.

Set `NIX_DISK_IMAGE` to the guest's persistent disk path. The runner creates an
ext4 disk and boots the configured kernel directly, so the cloud template's
Btrfs layout and bootloader are not exercised. Snapshot the complete stopped
guest disk for reset, retaining the corresponding runner and Nix closure.

The read-only Nix store image is built once per configuration and reused on
restart. The guest has its own persistent writable store and no shared host directories.
Accounts and SSH keys come from the organization, never from this template.
Networking uses QEMU user networking; explicitly forward chosen ports to
loopback with `QEMU_NET_OPTS` or configure `virtualisation.forwardPorts`.
