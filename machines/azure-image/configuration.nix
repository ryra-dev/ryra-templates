{ ryraModules, ... }:
{
  imports = [ ryraModules.azure-image ];
  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";
  ryra.desktop.enable = true;
}
