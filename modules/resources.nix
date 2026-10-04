# Keep recovery access responsive without imposing workload CPU or memory caps.
{ lib, pkgs, ... }:
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

  # Only template-named, read-only snapshots are eligible. Keep 30 days and
  # always retain the newest three of each kind for recovery.
  systemd.services.ryra-snapshot-prune = {
    description = "Prune expired Ryra deployment snapshots";
    path = [ pkgs.btrfs-progs ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 ${./maintenance/prune-snapshots.py}";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };
  systemd.timers.ryra-snapshot-prune = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "15m";
    };
  };
}
