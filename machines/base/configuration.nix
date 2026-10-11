# This machine's choices. Shared defaults come from the pinned ryra-template input.
{ ... }:
{
  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";
  ryra.desktop.enable = true;
  # ryra.tailscale.enable = true; # After configuring the enrollment secret.
}
