let
  flake = builtins.getFlake ("path:" + toString ../.);
  image = (flake.lib.mkMachine { self = ../machines/azure-image; }).nixosConfigurations.machine;
  c = image.config;
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
assert c.services.cloud-init.settings.datasource_list == [ "Azure" ];
assert c.services.waagent.settings.Extensions.Enabled;
assert !c.services.ryra-update.enable && !c.system.autoUpgrade.enable;
assert updated.services.ryra-update.inputs == [ "nixpkgs" "ryra-template" ];
assert c.fileSystems."/".fsType == assigned.config.fileSystems."/".fsType;
assert c.environment.etc ? "ryra/deploy/health";
assert c.environment.etc ? "ryra/deploy/preflight";
assert c.boot.loader.grub.devices == [ "nodev" ];
{
  image = c.system.build.azureImage.drvPath;
  inherit (c.disko.devices.disk.main) imageSize;
  runtime = (builtins.head (builtins.filter (p: (p.pname or "") == "ryra") c.environment.systemPackages)).version;
  success = true;
}
