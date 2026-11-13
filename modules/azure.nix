# Azure Gen 2 / x86-64 / SCSI OS disk, laid out by Ryra. The installer verifies these assumptions.
{ lib, ... }:
{
  imports = [ ./azure-guest.nix ];

  # Gen 2 boots via the removable EFI path. Never install an MBR on a guessed disk.
  boot.loader.grub.devices = lib.mkForce [ "nodev" ];
  ryra.hardware.biosBoot = false;
  disko.devices.disk.main.device = lib.mkForce "/dev/sda";
}
