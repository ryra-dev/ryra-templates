# NixOS under Lima: the platform is independent of the services on the machine.
{ lib, modulesPath, ... }:
{
  disabledModules = [ ./hardware.nix ];
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ./lima-boot.nix ];

  services.lima.enable = true;
  services.qemuGuest.enable = false;
  # lima-init owns the host user's bootstrap account and SSH key, read from cidata.
  users.mutableUsers = true;
  security.sudo.wheelNeedsPassword = false;
  nix.settings.trusted-users = [ "@wheel" ];
  networking.useDHCP = lib.mkDefault true;
  boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_net" ];
  boot.kernelParams = [ "console=tty0" ];

  # Used only by an explicit fresh install. Ordinary deploys never run disko.
  # Labels also match nixos-lima v0.2.1, allowing an existing image to be adopted.
  disko.devices.disk.main = {
    device = lib.mkDefault "/dev/vda";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            extraArgs = [ "-n" "ESP" ];
            mountpoint = "/boot";
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            extraArgs = [ "-L" "nixos" ];
            mountpoint = "/";
            mountOptions = [ "noatime" "discard" ];
          };
        };
      };
    };
  };
  fileSystems."/" = {
    device = lib.mkForce "/dev/disk/by-label/nixos";
    autoResize = true;
  };
  fileSystems."/boot".device = lib.mkForce "/dev/disk/by-label/ESP";
  # This profile uses ext4, so it cannot provide the cloud profile's btrfs snapshots.
  systemd.services.ryra-snapshot-prune.enable = false;
  systemd.timers.ryra-snapshot-prune.enable = false;
}
