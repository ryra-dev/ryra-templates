{ config, lib, pkgs, utils, ... }:
let
  cfg = config.services.ryraSshIssuer;
  policy = pkgs.writeText "ryra-ssh-issuer-policy.json" (builtins.toJSON cfg.policy);
in {
  options.services.ryraSshIssuer = {
    enable = lib.mkEnableOption "Ryra's group-operated SSH certificate issuer";
    package = lib.mkOption {
      type = lib.types.package;
      description = "The Ryra CLI package from the organization's pinned Ryra input.";
    };
    listen = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:8789";
      description = "Listen address behind an HTTPS reverse proxy.";
    };
    policy = lib.mkOption {
      type = lib.types.attrs;
      description = "Reviewed issuer policy, as emitted by ryra org ca policy. Contains public membership IDs and login grants, never credentials.";
    };
  };
  config = lib.mkIf cfg.enable {
    users.groups.ryra-ssh-issuer = { };
    users.users.ryra-ssh-issuer = {
      isSystemUser = true;
      group = "ryra-ssh-issuer";
      home = "/var/lib/ryra-ssh-issuer";
      createHome = true;
    };
    systemd.services.ryra-ssh-issuer = {
      description = "Ryra SSH certificate issuer";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = {
        RYRA_HOME = "/var/lib/ryra-ssh-issuer";
        RYRA_KEYSTORE = "off";
        RYRA_PRESENCE = "off";
      };
      serviceConfig = {
        ExecStart = utils.escapeSystemdExecArgs [ (lib.getExe cfg.package) "org" "ca" "serve" "--policy" policy "--listen" cfg.listen ];
        User = "ryra-ssh-issuer";
        Group = "ryra-ssh-issuer";
        StateDirectory = "ryra-ssh-issuer";
        StateDirectoryMode = "0700";
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = 10;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      };
    };
  };
}
