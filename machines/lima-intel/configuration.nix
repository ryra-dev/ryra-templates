# NixOS guest under Lima on Intel macOS.
{ ryraModules, lib, ... }:
{
  imports = [ ryraModules.lima ];
  nixpkgs.hostPlatform = "x86_64-linux";
  ryra.desktop.enable = false;
  # Preserve the state version of the supported nixos-lima bootstrap image.
  system.stateVersion = lib.mkForce "25.11";
}
