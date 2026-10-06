{ ryraModules, ... }:
{
  imports = [ ryraModules.azure-image ];
  nixpkgs.hostPlatform = "x86_64-linux";
  ryra.desktop.enable = true;
}
