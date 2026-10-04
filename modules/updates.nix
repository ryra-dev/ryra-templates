{ config, lib, pkgs, machineDir, ... }:
let
  cfg = config.services.ryra-update;
  validDirectory = cfg.directory == "." || builtins.match "[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*" cfg.directory != null;
  protected = lib.optionalAttrs config.services.postgresql.enable {
    postgresql = "services.postgresql.package";
  } // lib.optionalAttrs config.services.grafana.enable {
    grafana = "services.grafana.package";
  } // cfg.protectedPackages;
  settings = pkgs.writeText "ryra-update.json" (builtins.toJSON {
    inherit (cfg) repository branch directory configuration inputs authorName authorEmail;
    source = toString cfg.reviewedSource;
    versions = lib.mapAttrs (_: attr: (lib.getAttrFromPath (lib.splitString "." attr) config).version) protected;
    versionsExpression = "n: {" + lib.concatStringsSep " " (lib.mapAttrsToList
      (name: attr: "\"${name}\" = n.config.${attr}.version;") protected) + "}";
  });
  helper = pkgs.writeShellApplication {
    name = "ryra-system-update";
    runtimeInputs = [ pkgs.git pkgs.openssh config.nix.package pkgs.jq pkgs.coreutils pkgs.util-linux pkgs.diffutils ];
    text = builtins.readFile ./update.sh;
  };
  command = action: "${helper}/bin/ryra-system-update ${action} ${settings}";
  locked = action: ''
    exec 9>/run/lock/ryra-deploy.lock
    flock -n 9
    ${command action}
  '';
in {
  options.services.ryra-update = {
    enable = lib.mkEnableOption "independent, signed NixOS dependency updates";
    repository = lib.mkOption { type = lib.types.str; description = "Writable Git URL on any forge."; };
    branch = lib.mkOption { type = lib.types.str; default = "main"; };
    reviewedSource = lib.mkOption {
      type = lib.types.path;
      default = machineDir;
      description = "Deployed flake source. Automatic updates refuse changes outside its lockfile.";
    };
    directory = lib.mkOption { type = lib.types.str; default = "."; description = "Relative flake directory in the repository."; };
    configuration = lib.mkOption { type = lib.types.strMatching "[A-Za-z0-9_-]+"; default = config.networking.hostName; };
    inputs = lib.mkOption { type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9_-]+"); default = [ "nixpkgs" "ryra-template" ]; };
    gitKeyFile = lib.mkOption { type = lib.types.str; description = "Runtime SSH private key file for Git transport and commit signing, normally supplied by SOPS."; };
    authorName = lib.mkOption { type = lib.types.str; default = "Ryra maintenance"; };
    authorEmail = lib.mkOption { type = lib.types.str; default = "maintenance@localhost"; };
    dates = lib.mkOption { type = lib.types.str; default = "03:10"; };
    protectedPackages = lib.mkOption {
      type = lib.types.attrsOf (lib.types.strMatching "[A-Za-z0-9_.-]+");
      default = {};
      description = "Additional config package paths whose major version must not change automatically. PostgreSQL and Grafana are checked when enabled.";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = validDirectory && cfg.inputs != []; message = "services.ryra-update needs a relative flake directory and at least one input."; }
      { assertion = lib.hasPrefix "/" cfg.gitKeyFile && !(lib.hasPrefix "/nix/store/" cfg.gitKeyFile); message = "The update Git key must be a runtime secret outside the Nix store."; }
    ];
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    system.autoUpgrade = {
      enable = true;
      flake = "git+file:///var/lib/ryra-update/candidate?dir=${cfg.directory}#${cfg.configuration}";
      upgrade = false;
      dates = cfg.dates;
      randomizedDelaySec = "10m";
      persistent = false;
      flags = [ "--max-jobs" "1" "--cores" "2" "--no-write-lock-file" ];
      allowReboot = lib.mkDefault true;
      rebootWindow = lib.mkDefault { lower = "01:00"; upper = "06:00"; };
    };
    systemd.services.nixos-upgrade = {
      restartIfChanged = false;
      stopIfChanged = false;
      environment.GIT_SSH_COMMAND = "${pkgs.openssh}/bin/ssh -i /run/credentials/nixos-upgrade.service/git -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes";
      serviceConfig = {
        StateDirectory = "ryra-update";
        StateDirectoryMode = "0700";
        LoadCredential = [ "git:${cfg.gitKeyFile}" ];
        TimeoutStartSec = "4h";
        Nice = 15;
      };
      path = [ pkgs.util-linux ];
      script = lib.mkBefore (locked "prepare");
      postStart = locked "verify";
      unitConfig.OnFailure = [ "ryra-update-rollback.service" ];
    };
    systemd.services.ryra-update-rollback = {
      serviceConfig = { Type = "oneshot"; StateDirectory = "ryra-update"; StateDirectoryMode = "0700"; };
      path = [ pkgs.util-linux ];
      script = locked "rollback";
    };
    systemd.services.ryra-update-verify = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = { Type = "oneshot"; StateDirectory = "ryra-update"; StateDirectoryMode = "0700"; };
      path = [ pkgs.util-linux ];
      script = locked "verify";
    };
    systemd.timers.ryra-update-verify = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "5min"; OnUnitActiveSec = "5min"; };
    };
  };
}
