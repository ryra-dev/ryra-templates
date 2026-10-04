# NixOS guest under Lima on Apple Silicon macOS.
{ ryraModules, lib, ... }:
{
  imports = [ ryraModules.lima ];
  nixpkgs.hostPlatform = "aarch64-linux";
  ryra.desktop.enable = false;
  # Preserve the state version of the supported nixos-lima bootstrap image.
  system.stateVersion = lib.mkForce "25.11";
}
