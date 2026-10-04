let
  flake = builtins.getFlake ("path:" + toString ../.);
  names = [ "base" "base-arm" "azure" "desktop" ];
  inspect = name:
    let
      c = (flake.lib.mkMachine { self = ../machines + "/${name}"; }).nixosConfigurations.machine.config;
    in {
      failures = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
      system = c.nixpkgs.hostPlatform.system;
      grub = c.boot.loader.grub.devices;
      biosPartition = builtins.hasAttr "boot" c.disko.devices.disk.main.content.partitions;
      desktop = builtins.hasAttr "ryra-desktop@" c.systemd.services;
      azure = c.services.waagent.enable;
      earlyoom = c.services.earlyoom.enable;
      zram = c.zramSwap.enable;
      packages = map (p: p.pname or p.name) c.environment.systemPackages;
      revision = c.system.configurationRevision;
    };
in builtins.listToAttrs (map (name: { inherit name; value = inspect name; }) names)
