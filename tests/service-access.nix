{ serviceSource ? null }:
let
  templates = builtins.getFlake ("path:" + toString ../.);
  services = if serviceSource == null then templates.inputs.ryra-services
    else builtins.getFlake serviceSource;
  lib = templates.inputs.nixpkgs.lib;
  system = templates.inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      templates.inputs.sops-nix.nixosModules.default
      (services.nixosModules.services {
        registries.ryra = services;
        services = {
          "ryra/nextcloud".web = { access = "tailnet"; domain = "apps.example.ts.net"; };
          "ryra/grafana".web = { access = "tailnet"; domain = "apps.example.ts.net"; };
        };
        backupRepositoryFor = _: null;
      })
      {
        services.tailscale.enable = true;
        system.stateVersion = "26.05";
        boot.loader.grub.enable = false;
        fileSystems."/" = { device = "/dev/test"; fsType = "ext4"; };
        sops.defaultSopsFile = builtins.toFile "service-access-secrets.yaml" "{}";
        sops.validateSopsFiles = false;
        sops.age.keyFile = "/var/lib/sops-nix/key.txt";
      }
    ];
  };
  c = system.config;
  failures = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  refused = module: builtins.any (a: !a.assertion) (system.extendModules { modules = [ module ]; }).config.assertions;
in
assert lib.assertMsg (failures == []) (lib.concatStringsSep "\n" failures);
assert c.ryra.services.web.nextcloud.url == "https://apps.example.ts.net:8082";
assert c.ryra.services.web.grafana.url == "https://apps.example.ts.net:8083";
assert builtins.all (name:
  builtins.all (listen: listen.addr == "127.0.0.1" && !listen.ssl)
    c.services.nginx.virtualHosts."${name}.localhost".listen &&
  lib.hasInfix "--bg=false" c.systemd.services."ryra-serve-${name}".script &&
  !(lib.hasInfix "funnel" c.systemd.services."ryra-serve-${name}".script) &&
  c.systemd.services."ryra-serve-${name}".serviceConfig.Restart == "always"
) [ "nextcloud" "grafana" ];
assert builtins.sort builtins.lessThan c.networking.firewall.interfaces.tailscale0.allowedTCPPorts == [ 8082 8083 ];
assert c.networking.firewall.allowedTCPPorts == [];
assert c.security.acme.certs == {};
assert builtins.elem "apps.example.ts.net:8082" c.services.nextcloud.settings.trusted_domains;
assert refused { services.tailscale.enable = lib.mkForce false; };
assert refused { ryra.services.web.grafana.domain = lib.mkForce "apps.example.com"; };
assert refused { ryra.services.web.grafana.privateHttps = true; };
assert c.services.restic.backups == {};
assert !(c.sops.secrets ? restic-nextcloud);
assert !(c.sops.secrets ? restic-grafana);
assert !(c.systemd.services ? restic-backups-nextcloud);
assert !(c.systemd.services ? restic-backups-grafana);
assert c.ryra.nextcloud.backup.result.backupService == null;
assert c.ryra.grafana.backup.result.restoreScript == null;
{ inherit failures; apps = builtins.fromJSON c.environment.etc."ryra/apps.json".text; }
