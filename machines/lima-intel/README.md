# Lima on Intel

A NixOS guest for local testing under Lima on macOS. Service modules stay in
`modules/` and can be reused on a cloud machine with its own platform profile.

The shared Lima module provides EFI boot on `/dev/vda`, DHCP, Lima's cidata
bootstrap and guest agent, and the host user's SSH access. Fresh installations
use a 1 GiB ESP and ext4 root. An ordinary deployment can also adopt the pinned
nixos-lima v0.2.1 image, using its existing `ESP` and `nixos` filesystem labels;
it does not resize or format that image. Never run the disk installer merely
to update an existing VM.

GRUB keeps its menu in `/boot-nixos` on the root disk and reads kernels from
the Nix store. Only EFI loader files need the ESP mounted at `/boot`, so kernel
updates do not fill the older image's 249 MiB partition. Ten configurations are
kept in the boot menu. Deployment rollback restores configuration, not ext4 data;
keep service backups separately. Legacy generations from before adoption retain
their old bootloader settings; test rollback between Lima-profile generations.

No host folders are shared by this template; configure Lima mounts explicitly.
The guest runs while its Mac is awake. Keep persistent VMs; uniquely name and
remove temporary acceptance-test VMs. Intel is evaluation-tested separately from
the Apple Silicon live boot/deploy/reboot/rollback check.
