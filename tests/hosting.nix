{ serviceSource ? null }:
let
  templates = builtins.getFlake ("path:" + toString ../.);
  services = if serviceSource == null then templates.inputs.ryra-services
    else builtins.getFlake serviceSource;
  lib = templates.inputs.nixpkgs.lib;
  machine = web: templates.lib.mkMachine {
    self = ./hosting/machine;
    inputs.ryra-services = services;
    modules = [
      ({ ... }: {
        sops.defaultSopsFile = builtins.toFile "hosting-secrets.yaml" "{}";
        sops.validateSopsFiles = false;
        ryra.services.web.linkding = web;
      })
    ];
  };
  c = (machine {}).nixosConfigurations.machine.config;
  p = (machine { access = "public"; domain = "bookmarks.example.com"; }).nixosConfigurations.machine.config;
  failures = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
in
assert failures == [];
assert builtins.all (a: a.assertion) p.assertions;
assert c.services.nginx.enable && c.services.postgresql.enable;
assert c.services.nextcloud.database.createLocally;
assert !c.services.authelia.instances ? main;
assert c.services.nginx.virtualHosts."linkding.localhost".listen == [
  { addr = "127.0.0.1"; port = 8081; ssl = false; extraParameters = []; proxyProtocol = false; }
];
assert c.services.nginx.virtualHosts."nextcloud.localhost".listen == [
  { addr = "127.0.0.1"; port = 8082; ssl = false; extraParameters = []; proxyProtocol = false; }
];
assert !(builtins.elem 80 c.networking.firewall.allowedTCPPorts);
assert !(builtins.elem 443 c.networking.firewall.allowedTCPPorts);
assert p.services.nginx.virtualHosts."bookmarks.example.com".enableACME;
assert p.services.nginx.virtualHosts."bookmarks.example.com".forceSSL;
assert p.security.acme.acceptTerms;
assert p.security.acme.certs."bookmarks.example.com".reloadServices == [ "nginx.service" ];
assert builtins.elem 80 p.networking.firewall.allowedTCPPorts;
assert builtins.elem 443 p.networking.firewall.allowedTCPPorts;
assert p.ryra.services.web.nextcloud.access == "private";
{
  inherit failures;
  apps = builtins.fromJSON c.environment.etc."ryra/apps.json".text;
  nextcloudVersion = c.services.nextcloud.package.version;
  https = p.ryra.services.web.linkding.url;
  backup = c.services.restic.backups.nextcloud.paths;
}
