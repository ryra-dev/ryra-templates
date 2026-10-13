{ ryraModules, lib, ... }:
{
  imports = [ ryraModules.qemu ];
  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";
  ryra.desktop.enable = lib.mkDefault false;
}
