{ config, lib, pkgs, ... }:
let
  cfg = config.ryra.deployment;
  backups = lib.attrValues (lib.attrByPath [ "ryra" "services" "backup" "results" ] {} config);
  script = name: commands: pkgs.writeShellApplication {
    inherit name;
    runtimeInputs = [ pkgs.systemd pkgs.curl pkgs.coreutils ];
    text = lib.concatStringsSep "\n" ([ ":" ] ++ commands);
  };
  preflight = script "ryra-deploy-preflight" ([
    (lib.concatMapStringsSep "\n" (backup: ''
      if [[ "$(systemctl show ${lib.escapeShellArg backup.backupService} -p LoadState --value)" == loaded ]]; then
        systemctl start ${lib.escapeShellArg backup.backupService}
        test "$(systemctl show ${lib.escapeShellArg backup.backupService} -p Result --value)" = success
      fi
    '') backups)
  ] ++ cfg.beforeSwitch);
  health = script "ryra-deploy-health" ([
    "systemctl is-active --quiet multi-user.target"
    (lib.concatMapStringsSep "\n" (unit: ''
      if ! systemctl is-active --quiet ${lib.escapeShellArg unit}; then
        printf '%s\n' ${lib.escapeShellArg "Required service is not active: ${unit}"} >&2
        exit 1
      fi
    '') cfg.requiredUnits)
  ] ++ cfg.healthChecks);
in {
  options.ryra.deployment = {
    beforeSwitch = lib.mkOption {
      type = lib.types.listOf lib.types.lines;
      default = [];
      description = "Checks that must pass before activation, after existing service backups complete.";
    };
    requiredUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Systemd units that must be healthy before deployment is confirmed.";
    };
    healthChecks = lib.mkOption {
      type = lib.types.listOf lib.types.lines;
      default = [];
      description = "Application health checks; failure prevents deployment confirmation.";
    };
  };
  config.environment.etc = {
    "ryra/deploy/preflight".source = "${preflight}/bin/ryra-deploy-preflight";
    "ryra/deploy/health".source = "${health}/bin/ryra-deploy-health";
  };
}
