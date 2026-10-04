# Keep kernels in the ext4 root store, including on older Lima images with a 249 MiB ESP.
# GRUB forces kernel copies whenever its boot directory is on another filesystem;
# copyKernels=false alone does not fix a separately mounted /boot.
{ lib, ... }:
{
  boot.loader.grub = {
    enable = true;
    device = lib.mkForce "";
    devices = lib.mkForce [];
    efiSupport = true;
    efiInstallAsRemovable = true;
    copyKernels = false;
    configurationLimit = lib.mkDefault 10;
    mirroredBoots = [{
      path = "/boot-nixos";
      efiSysMountPoint = "/boot";
      devices = [ "nodev" ];
    }];
  };
  boot.loader.efi.canTouchEfiVariables = false;
}
