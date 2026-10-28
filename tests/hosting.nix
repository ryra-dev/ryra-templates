{ serviceSource ? null, machineDir ? ./hosting/machine }:
let
  templates = builtins.getFlake ("path:" + toString ../.);
  services = if serviceSource == null then templates
    else builtins.getFlake serviceSource;
  lib = templates.inputs.nixpkgs.lib;
  machine = web: templates.lib.mkMachine {
    self = machineDir;
    inputs.ryra-template = services;
    modules = [
      ({ ... }: {
        system.stateVersion = lib.mkForce "26.05";
        sops.defaultSopsFile = lib.mkForce (builtins.toFile "hosting-secrets.yaml" "{}");
        sops.validateSopsFiles = false;
        ryra.services.web = lib.mapAttrs (_: site: lib.mapAttrs (_: lib.mkForce) site) web;
      })
    ];
  };
  c = (machine {}).nixosConfigurations.machine.config;
  p = (machine { linkding = { access = "public"; domain = "bookmarks.example.com"; externalUrl = null; }; }).nixosConfigurations.machine.config;
  privateWeb = {
    nextcloud = { privateHttps = true; externalUrl = "https://apps.example.com:8443"; };
    grafana = { privateHttps = true; externalUrl = "https://apps.example.com:8444"; };
  };
  tls = (machine privateWeb).nixosConfigurations.machine.config;
  independent = (machine { nextcloud.externalUrl = "https://proxy.example.com"; }).nixosConfigurations.machine.config;
  refused = web: builtins.any (a: !a.assertion) (machine web).nixosConfigurations.machine.config.assertions;
  failures = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  managed = (templates.lib.mkMachine {
    self = ./hosting/managed;
    inputs.ryra-template = services;
    modules = [{
      system.stateVersion = lib.mkForce "26.05";
      sops.defaultSopsFile = lib.mkForce (builtins.toFile "hosting-managed-secrets.yaml" "{}");
      sops.validateSopsFiles = false;
    }];
  }).nixosConfigurations.machine.config;
in
assert failures == [];
assert builtins.all (a: a.assertion) managed.assertions;
assert managed.ryra.services.auth.provider.credentialService == "ryra-auth-credentials.service";
assert builtins.elem "ryra-auth-credentials.service" managed.systemd.services.grafana.requires;
assert builtins.elem "ryra-auth-credentials.service" managed.systemd.services.grafana.after;
assert builtins.elem "oidc-client:/var/lib/ryra-auth/clients/grafana/secret" managed.systemd.services.grafana.serviceConfig.LoadCredential;
assert managed.services.grafana.settings."auth.generic_oauth".role_attribute_path == "('Viewer')";
assert builtins.all (a: a.assertion) p.assertions;
assert c.services.nginx.enable && c.services.postgresql.enable;
assert c.services.nextcloud.database.createLocally;
assert builtins.elem "nextcloud-setup.service" c.systemd.services.nextcloud-cron.requires;
assert builtins.elem "nextcloud-setup.service" c.systemd.services.nextcloud-cron.after;
assert c.ryra.services.auth.modes.nextcloud == "none";
assert c.ryra.services.auth.modes.grafana == "none";
assert c.services.grafana.enable;
assert c.ryra.services.backup.requests.linkding.user == "root";
assert builtins.all (name:
  (services.ryraServices.${name}.meta.secrets."restic-${name}".owner or "root") == c.ryra.services.backup.requests.${name}.user
) [ "linkding" "nextcloud" "grafana" ];
assert c.ryra.services.backup.requests.linkding.beforeBackup != [] && c.ryra.services.backup.requests.linkding.afterRestore != [];
assert managed.ryra.services.backup.requests.linkding.beforeBackup == c.ryra.services.backup.requests.linkding.beforeBackup;
assert lib.hasInfix "/run/ryra-backup-locks/linkding.lock" c.systemd.services.restic-backups-linkding.serviceConfig.ExecCondition;
assert lib.hasInfix "SERVICE_RESULT" c.services.restic.backups.linkding.backupCleanupCommand;
assert lib.hasInfix "exec-condition" c.services.restic.backups.linkding.backupCleanupCommand;
assert c.systemd.services.grafana.serviceConfig.LoadCredential == [
  "admin:/run/secrets/grafana-adminpass" "key:/run/secrets/grafana-secret-key"
];
assert c.services.restic.backups.nextcloud.repository == "rest:https://api.example.test/v1/orgs/test/backups/machine-nextcloud/";
assert c.services.restic.backups.nextcloud.environmentFile == "/run/secrets/backup-nextcloud";
assert c.ryra.services.auth.provider.enable == builtins.hasAttr c.ryra.services.auth.provider.instance c.services.authelia.instances;
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
assert builtins.all (a: a.assertion) tls.assertions;
assert tls.services.nginx.virtualHosts."nextcloud.localhost".serverName == "apps.example.com";
assert tls.services.nginx.virtualHosts."grafana.localhost".serverName == "apps.example.com";
assert builtins.all (name: tls.services.nginx.virtualHosts.${name}.onlySSL &&
  tls.services.nginx.virtualHosts.${name}.useACMEHost == "apps.example.com") [ "nextcloud.localhost" "grafana.localhost" ];
assert tls.services.nginx.virtualHosts."nextcloud.localhost".listen == [
  { addr = "127.0.0.1"; port = 8443; ssl = true; extraParameters = []; proxyProtocol = false; }
];
assert tls.services.nginx.virtualHosts."grafana.localhost".listen == [
  { addr = "127.0.0.1"; port = 8444; ssl = true; extraParameters = []; proxyProtocol = false; }
];
assert builtins.attrNames tls.security.acme.certs == [ "apps.example.com" ];
assert tls.security.acme.certs."apps.example.com".extraDomainNames == [];
assert tls.security.acme.certs."apps.example.com".webroot == "/var/lib/acme/acme-challenge";
assert tls.security.acme.certs."apps.example.com".dnsProvider == null;
assert tls.security.acme.certs."apps.example.com".reloadServices == [ "nginx.service" ];
assert tls.systemd.timers."acme-renew-apps.example.com".timerConfig.OnCalendar == "daily";
assert tls.services.nginx.virtualHosts."ryra-acme-apps.example.com".locations."/".return == "404";
assert builtins.all (listen: listen.port == 80 && !listen.ssl)
  tls.services.nginx.virtualHosts."ryra-acme-apps.example.com".listen;
assert builtins.elem "apps.example.com" tls.networking.hosts."127.0.0.1";
assert builtins.elem 80 tls.networking.firewall.allowedTCPPorts;
assert !builtins.any (port: builtins.elem port tls.networking.firewall.allowedTCPPorts) [ 443 8443 8444 ];
assert independent.services.nginx.virtualHosts."nextcloud.localhost".useACMEHost == null;
assert !independent.services.nginx.virtualHosts."nextcloud.localhost".onlySSL;
assert independent.security.acme.certs == {};
assert refused { nextcloud.privateHttps = true; };
assert refused { nextcloud = { privateHttps = true; access = "public"; domain = "apps.example.com"; }; };
assert refused { nextcloud = { privateHttps = true; externalUrl = "https://apps.example.com:0"; }; };
assert refused { nextcloud = { privateHttps = true; externalUrl = "https://apps.example.com:65536"; }; };
assert refused { nextcloud = { privateHttps = true; externalUrl = "https://apps.example.com/path"; }; };
assert refused { nextcloud = { privateHttps = true; externalUrl = "https://app.test.ts.net:8443"; }; };
assert refused (privateWeb // { grafana = { privateHttps = true; externalUrl = "https://apps.example.com:8443"; }; });
{
  inherit failures;
  apps = builtins.fromJSON c.environment.etc."ryra/apps.json".text;
  nextcloudVersion = c.services.nextcloud.package.version;
  https = p.ryra.services.web.linkding.url;
  backup = c.services.restic.backups.nextcloud.paths;
  auth = if c.ryra.services.auth.provider.enable then services.lib.checkAuth { config = c; inherit lib; } else null;
  modes = c.ryra.services.auth.modes;
  managedAuth = services.lib.checkAuth { config = managed; inherit lib; };
  privateHttps = {
    apps = builtins.fromJSON tls.environment.etc."ryra/apps.json".text;
    certificate = builtins.attrNames tls.security.acme.certs;
    ports = tls.networking.firewall.allowedTCPPorts;
  };
  toplevel = c.system.build.toplevel.drvPath;
}
