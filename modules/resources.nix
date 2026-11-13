# Keep recovery access responsive without imposing workload CPU or memory caps.
{ lib, ... }:
{
  systemd.services.sshd.serviceConfig = {
    CPUWeight = 1000;
    IOWeight = 1000;
    # Best-effort reclaim protection, not preallocated or unavailable RAM.
    MemoryLow = "64M";
  };
  systemd.slices.system.sliceConfig.MemoryLow = lib.mkDefault "64M";

  # Builds may use all idle capacity, but yield to other services under load.
  systemd.services.nix-daemon.serviceConfig = {
    CPUWeight = 25;
    IOWeight = 25;
  };

  # Collect unreferenced store paths during builds when space gets tight.
  nix.settings = {
    max-jobs = lib.mkDefault 1;
    cores = lib.mkDefault 2;
    min-free = lib.mkDefault (1024 * 1024 * 1024);
    max-free = lib.mkDefault (3 * 1024 * 1024 * 1024);
  };
  services.journald.settings.Journal = {
    SystemMaxUse = "512M";
    SystemKeepFree = "1G";
  };
}
