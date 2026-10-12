let
  flake = builtins.getFlake ("path:" + toString ../.);
  image = (flake.lib.mkMachine { self = ../machines/azure-image; }).nixosConfigurations.machine;
  c = image.config;
  imageConfig = flake.inputs.disko.lib.testLib.prepareDiskoConfig c flake.inputs.disko.lib.testLib.devices;
  transformed = (image.extendModules { modules = [({ lib, ... }: {
    disko.devices = lib.mkForce imageConfig.disko.devices;
    boot.loader.grub.devices = lib.mkForce imageConfig.boot.loader.grub.devices;
  })]; }).config;
  custom = (image.extendModules { modules = [({ lib, ... }: {
    disko.devices.disk.main.content.partitions = {
      ESP.size = lib.mkForce "768M";
      customer = { size = "1G"; type = "8300"; };
    };
  })]; }).config;
  failures = config: map (a: a.message) (builtins.filter (a: !a.assertion) config.assertions);
  withCustomer = (image.extendModules { modules = [{ users.users.alice = { isNormalUser = true; }; }]; }).config;
  assigned = (flake.lib.mkMachine { self = ../machines/azure; }).nixosConfigurations.machine;
  updated = (assigned.extendModules { modules = [{ services.ryra-update = {
    enable = true;
    repository = "ssh://git@example.invalid/organization.git";
    gitKeyFile = "/run/secrets/update-git";
  }; }]; }).config;
in
assert failures c == [];
assert failures updated == [];
assert failures withCustomer != [];
assert c.services.cloud-init.enable && !assigned.config.services.cloud-init.enable;
assert c.systemd.services.cloud-config.enable && !assigned.config.systemd.services.cloud-config.enable;
assert !(builtins.any (p: (p.pname or "") == "ryra") c.environment.systemPackages);
assert c.services.cloud-init.settings.datasource_list == [ "Azure" ];
assert c.services.waagent.settings.Extensions.Enabled;
assert !c.services.ryra-update.enable && !c.system.autoUpgrade.enable;
assert updated.services.ryra-update.inputs == [ "nixpkgs" "ryra-template" ];
assert c.fileSystems."/".fsType == assigned.config.fileSystems."/".fsType;
assert c.environment.etc ? "ryra/deploy/health";
assert c.environment.etc ? "ryra/deploy/preflight";
assert c.ryra.desktop.enable && builtins.hasAttr "ryra-desktop@" c.systemd.services;
assert c.services.desktopManager.gnome.enable && !c.services.desktopManager.gnome.flashback.enableMetacity;
assert c.systemd.services."ryra-desktop@".environment.XDG_SESSION_TYPE == "wayland";
assert builtins.any (p: (p.pname or p.name) == "ryra-desktop") c.environment.systemPackages;
assert c.boot.loader.grub.devices == [ "nodev" ];
assert !(c.disko.devices.disk.main.content.partitions ? boot);
assert imageConfig.boot.loader.grub.devices == [ "nodev" ];
assert failures transformed == [];
assert flake.inputs.nixpkgs.lib.unique transformed.boot.loader.grub.devices == [ "nodev" ];
assert !(transformed.disko.devices.disk.main.content.partitions ? boot);
assert custom.disko.devices.disk.main.content.partitions.ESP.size == "768M";
assert custom.disko.devices.disk.main.content.partitions.customer.size == "1G";
assert !(custom.disko.devices.disk.main.content.partitions ? boot);
{
  image = c.system.build.azureImage.drvPath;
  inherit (c.disko.devices.disk.main) imageSize;
  runtime = image._module.args.ryraPackage.version;
  success = true;
}
