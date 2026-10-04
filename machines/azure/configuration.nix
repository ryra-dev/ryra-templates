# This machine's choices. Shared defaults come from the pinned ryra-template input.
{ ryraModules, ... }:
{
  imports = [ ryraModules.azure ];
  nixpkgs.hostPlatform = "x86_64-linux";
  ryra.desktop.enable = true;
  # ryra.tailscale.enable = true; # After configuring the enrollment secret.
}
