let
  flake = builtins.getFlake ("path:" + toString ../.);
  names = [ "base" "base-arm" "azure" "desktop" "lima" "lima-intel" ];
  withoutApps = (flake.lib.mkMachine {
    self = ../machines/base;
    modules = [{ disabledModules = [ (flake.outPath + "/modules/services.nix") ]; }];
  }).nixosConfigurations.machine.config;
  inspect = name:
    let
      c = (flake.lib.mkMachine { self = ../machines + "/${name}"; }).nixosConfigurations.machine.config;
    in
    assert builtins.all (agent: builtins.any (p: (p.pname or p.name) == agent) c.environment.systemPackages) [ "codex" "claude-code" ];
    assert !c.ryra.desktop.enable || (
      c.services.desktopManager.gnome.enable
      && !c.services.desktopManager.gnome.flashback.enableMetacity
      && c.systemd.services."ryra-desktop@".environment.XDG_SESSION_TYPE == "wayland"
      && !(c.systemd.user.services."org.gnome.Shell@".environment ? PATH)
      && builtins.all (app: flake.inputs.nixpkgs.lib.hasInfix app c.services.desktopManager.gnome.extraGSettingsOverrides)
        [ "firefox.desktop" "org.gnome.Console.desktop" "org.gnome.Nautilus.desktop" "org.gnome.Settings.desktop" ]
      && builtins.all (setting: flake.inputs.nixpkgs.lib.hasInfix (builtins.unsafeDiscardStringContext setting) c.services.desktopManager.gnome.extraGSettingsOverrides)
        (let wallpaper = builtins.head (builtins.filter (p: p.name == "ryra-wallpapers") c.environment.systemPackages);
         in [
           "picture-uri='file://${wallpaper}/share/backgrounds/ryra/horizon-light.svg'"
           "picture-uri-dark='file://${wallpaper}/share/backgrounds/ryra/horizon-light.svg'"
           "picture-options='zoom'"
         ])
    );
    {
      failures = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
      system = c.nixpkgs.hostPlatform.system;
      grub = c.boot.loader.grub.devices;
      bootPaths = map (b: { inherit (b) path efiSysMountPoint devices; }) c.boot.loader.grub.mirroredBoots;
      lima = c.services.lima.enable or false;
      rootFs = c.fileSystems."/".fsType;
      espSize = c.disko.devices.disk.main.content.partitions.ESP.size;
      disk = c.disko.devices.disk.main.device;
      snapshots = c.systemd.timers.ryra-snapshot-prune.enable;
      biosPartition = builtins.hasAttr "boot" c.disko.devices.disk.main.content.partitions;
      desktop = builtins.hasAttr "ryra-desktop@" c.systemd.services;
      azure = c.services.waagent.enable;
      earlyoom = c.services.earlyoom.enable;
      zram = c.zramSwap.enable;
      buildJobs = c.nix.settings.max-jobs;
      buildCores = c.nix.settings.cores;
      packages = map (p: p.pname or p.name) c.environment.systemPackages;
      revision = c.system.configurationRevision;
      timeZone = c.time.timeZone;
      locale = c.i18n.defaultLocale;
    };
in
assert builtins.all (p: !builtins.elem (p.pname or p.name) [ "codex" "claude-code" ]) withoutApps.environment.systemPackages;
builtins.listToAttrs (map (name: { inherit name; value = inspect name; }) names)
