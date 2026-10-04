let
  flake = builtins.getFlake ("path:" + toString ../.);
  base = (flake.lib.mkMachine { self = ../machines/base; }).nixosConfigurations.machine;
  c = (base.extendModules { modules = [{ services.ryra-update = {
    enable = true;
    repository = "ssh://git@example.invalid/organization.git";
    gitKeyFile = "/run/secrets/update-git";
  }; }]; }).config;
in
assert c.services.ryra-update.inputs == [ "nixpkgs" "ryra-template" ];
assert !c.systemd.timers.nixos-upgrade.timerConfig.Persistent;
{
  survivesActivation = !c.systemd.services.nixos-upgrade.restartIfChanged && !c.systemd.services.nixos-upgrade.stopIfChanged;
  persistent = c.systemd.timers.nixos-upgrade.timerConfig.Persistent;
  followsReleasedRuntime = c.services.ryra-update.inputs == [ "nixpkgs" "ryra-template" ];
  updatesSelectedPins = !c.system.autoUpgrade.upgrade;
  credentials = c.systemd.services.nixos-upgrade.serviceConfig.LoadCredential;
  unit = c.systemd.units."nixos-upgrade.service".text;
  verifier = c.systemd.units."ryra-update-verify.service".text;
  failures = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
}
