{ serviceSource ? null, httpCheck ? false, certificateCheck ? false }:
let
  templates = builtins.getFlake ("path:" + toString ../.);
  services = if serviceSource == null then templates.inputs.ryra-services
    else builtins.getFlake serviceSource;
  lib = templates.inputs.nixpkgs.lib;
  makeSystem = selectedServices: templates.inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      templates.inputs.sops-nix.nixosModules.default
      (services.nixosModules.services {
        registries = {
          ryra = services;
          fixture.ryraServices.gateway = {
            meta = { optionRoot = [ "ryra" "fixtureGateway" ]; provides = [ "web-gateway" ]; };
            module = _: { options.ryra.fixtureGateway = lib.mkOption {
              type = lib.types.attrs;
              default = {};
            }; };
          };
        };
        services = {
          "fixture/gateway" = {};
        } // selectedServices;
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
  system = makeSystem {
    "ryra/nextcloud".web = { access = "tailnet"; domain = "apps.example.ts.net"; };
    "ryra/grafana".web = { access = "tailnet"; domain = "apps.example.ts.net"; };
  };
  c = system.config;
  failures = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  refused = module: builtins.any (a: !a.assertion) (system.extendModules { modules = [ module ]; }).config.assertions;
  namedSystem = system.extendModules { modules = [ {
    ryra.services.web = {
      nextcloud = {
        access = lib.mkOverride 60 "tailnet_service";
        domain = lib.mkOverride 60 "files.example.ts.net";
        hostTags = [ "tag:ryra" ];
      };
      grafana = {
        access = lib.mkOverride 60 "tailnet_service";
        domain = lib.mkOverride 60 "metrics.example.ts.net";
        hostTags = [ "tag:ryra" "tag:monitoring" ];
        audience = "tailnet_members";
      };
    };
  } ]; };
  n = namedSystem.config;
  namedFailures = map (a: a.message) (builtins.filter (a: !a.assertion) n.assertions);
  refusedNamed = module: builtins.any (a: !a.assertion) (namedSystem.extendModules { modules = [ module ]; }).config.assertions;
  removed = (namedSystem.extendModules { modules = [ {
    ryra.services.web.grafana.access = lib.mkForce "private";
  } ]; }).config;
  mixed = (namedSystem.extendModules { modules = [ {
    ryra.services.web.grafana = {
      access = lib.mkForce "tailnet";
      domain = lib.mkForce "apps.example.ts.net";
    };
  } ]; }).config;
  gatewaySystem = system.extendModules { modules = [ {
    ryra.services.web = lib.genAttrs [ "nextcloud" "grafana" ] (name: {
      access = lib.mkOverride 60 "gateway";
      provider = "fixture/gateway";
      domain = lib.mkOverride 60 "${name}.example.com";
    });
  } ]; };
  g = gatewaySystem.config;
  proxyApps = (makeSystem (lib.listToAttrs (map (name: lib.nameValuePair "ryra/${name}" {
    web = { access = "gateway"; provider = "fixture/gateway"; domain = "${name}.example.com"; };
  }) [ "authelia" "linkding" ]))).config;
  gatewayFailures = map (a: a.message) (builtins.filter (a: !a.assertion) g.assertions);
  refusedGateway = module: builtins.any (a: !a.assertion) (gatewaySystem.extendModules { modules = [ module ]; }).config.assertions;
  directSystem = access: certificate: system.extendModules { modules = [ {
    ryra.services.web = lib.genAttrs [ "nextcloud" "grafana" ] (name: {
      access = lib.mkOverride 60 access;
      domain = lib.mkOverride 60 "${name}.example.com";
      privateHttps = access == "private";
      externalUrl = if access == "private" then
        "https://apps.example.com:${toString c.ryra.services.web.${name}.port}" else null;
      inherit certificate;
    });
  } ]; };
  p = (directSystem "public" {}).config;
  h = (directSystem "private" {}).config;
  dns = { mode = "dns"; dnsProvider = "rfc2136"; credentialsFile = "/run/secrets/acme-dns"; };
  dnsSystem = directSystem "public" dns;
  d = dnsSystem.config;
  privateDns = (directSystem "private" dns).config;
  refusedDns = certificate: builtins.any (a: !a.assertion) (dnsSystem.extendModules {
    modules = [ { ryra.services.web.grafana.certificate = certificate; } ];
  }).config.assertions;
  supplied = { mode = "supplied"; certificateFile = "/run/certs/fullchain.pem"; keyFile = "/run/certs/key.pem"; };
  suppliedSystem = directSystem "public" supplied;
  s = suppliedSystem.config;
  privateSupplied = (directSystem "private" supplied).config;
  defaultSupplied = (directSystem "public" { mode = "supplied"; }).config;
  privateDefaultSupplied = (directSystem "private" { mode = "supplied"; }).config;
  refusedSupplied = certificate: builtins.any (a: !a.assertion) (suppliedSystem.extendModules {
    modules = [ { ryra.services.web.grafana.certificate = certificate; } ];
  }).config.assertions;
  switched = (gatewaySystem.extendModules { modules = [ {
    ryra.services.web = lib.genAttrs [ "nextcloud" "grafana" ] (_: {
      access = lib.mkForce "private";
      provider = lib.mkForce null;
      domain = lib.mkForce null;
    });
  } ]; }).config;
  pkgs = templates.inputs.nixpkgs.legacyPackages.x86_64-linux;
  proxyHosts = {
    grafana = g.services.nginx.virtualHosts."grafana.example.com";
    authelia = proxyApps.services.nginx.virtualHosts."authelia.example.com";
    linkding = proxyApps.services.nginx.virtualHosts."linkding.example.com";
    private = c.services.nginx.virtualHosts."grafana.localhost";
  };
  httpFixture = (lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ {
      system.stateVersion = "26.05";
      services.nginx = {
        enable = true;
        validateConfigFile = false;
        recommendedProxySettings = true;
        commonHttpConfig = ''
          access_log off;
          client_body_temp_path @work@/client_body;
          proxy_temp_path @work@/proxy;
          fastcgi_temp_path @work@/fastcgi;
          uwsgi_temp_path @work@/uwsgi;
          scgi_temp_path @work@/scgi;
        '';
        virtualHosts = lib.mapAttrs' (name: host: lib.nameValuePair "${name}.example.com" {
          listen = [ { addr = "unix:@work@/${name}.sock"; port = null; } ];
          inherit (host) extraConfig;
          locations."/" = {
            inherit (host.locations."/") recommendedProxySettings proxyWebsockets extraConfig;
            proxyPass = "http://unix:@work@/upstream.sock";
          };
        }) proxyHosts // {
          "nextcloud.example.com" = {
            listen = [ { addr = "unix:@work@/nextcloud.sock"; port = null; } ];
            inherit (g.services.nginx.virtualHosts."nextcloud.example.com") extraConfig;
            locations."/remote" = g.services.nginx.virtualHosts."nextcloud.example.com".locations."/remote";
          };
          upstream = {
            listen = [ { addr = "unix:@work@/upstream.sock"; port = null; } ];
            locations."/".return = ''200 "$http_host|$http_x_forwarded_proto|$http_x_forwarded_host|$http_upgrade"'';
          };
        };
      };
    } ];
  }).config;
in
if certificateCheck then lib.findFirst
  (package: (package.name or "") == "ryra-check-certificates")
  (throw "Certificate validation command is missing") defaultSupplied.environment.systemPackages
else if httpCheck then pkgs.runCommand "ryra-gateway-http-check" {
  nativeBuildInputs = [ pkgs.nginx pkgs.curl ];
} ''
  set -euo pipefail
  substitute ${httpFixture.environment.etc."nginx/nginx.conf".source} nginx.conf \
    --replace-fail @work@ "$PWD" \
    --replace-fail /run/nginx/nginx.pid "$PWD/nginx.pid"
  nginx -t -e stderr -p "$PWD/" -c "$PWD/nginx.conf"
  nginx -e stderr -p "$PWD/" -c "$PWD/nginx.conf" >nginx.log 2>&1 &
  nginx_pid=$!
  trap 'status=$?; kill "$nginx_pid" 2>/dev/null || true; wait "$nginx_pid" || true; if [ "$status" -ne 0 ]; then cat nginx.log; fi; exit "$status"' EXIT
  for attempt in {1..100}; do
    if [ -S grafana.sock ]; then break; fi
    kill -0 "$nginx_pid"
    sleep 0.05
  done
  for name in grafana authelia linkding; do
    test "$(curl --fail --silent --show-error --max-time 5 --unix-socket "$name.sock" \
      -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-Host: wrong.example.com' \
      -H 'Connection: Upgrade' -H 'Upgrade: websocket' "http://$name.example.com/")" \
      = "$name.example.com|https|$name.example.com|websocket"
    test "$(curl --silent --show-error --max-time 5 --unix-socket "$name.sock" \
      -H 'X-Forwarded-Proto: http' --output /dev/null --write-out '%{http_code} %{redirect_url}' \
      "http://$name.example.com/path?x=1")" = "308 https://$name.example.com/path?x=1"
    test "$(curl --fail --silent --show-error --max-time 5 --unix-socket "$name.sock" \
      "http://$name.example.com/")" = "$name.example.com|https|$name.example.com|"
  done
  test "$(curl --fail --silent --show-error --max-time 5 --unix-socket private.sock \
    -H 'X-Forwarded-Proto: https' http://private.example.com/)" = 'private.example.com|http|private.example.com|'
  test "$(curl --silent --show-error --max-time 5 --unix-socket nextcloud.sock \
    -H 'X-Forwarded-Proto: https' --output /dev/null --write-out '%{http_code} %header{location}' \
    'http://nextcloud.example.com/remote/path?x=1')" = '301 /remote.php/remote/path?x=1'
  touch "$out"
'' else
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
assert lib.assertMsg (namedFailures == []) (lib.concatStringsSep "\n" namedFailures);
assert n.ryra.services.web.nextcloud.url == "https://files.example.ts.net";
assert n.ryra.services.web.grafana.url == "https://metrics.example.ts.net";
assert n.ryra.services.web.nextcloud.port == 8082;
assert n.ryra.services.web.grafana.port == 8083;
assert n.ryra.services.web.nextcloud.audience == "machine_users";
assert n.ryra.services.web.grafana.audience == "tailnet_members";
assert builtins.all (name:
  let unit = n.systemd.services."ryra-serve-${name}";
      site = n.ryra.services.web.${name};
      service = "svc:${builtins.head (lib.splitString "." site.domain)}";
  in builtins.all (listen: listen.addr == "127.0.0.1" && listen.port == site.port && !listen.ssl)
    n.services.nginx.virtualHosts."${name}.localhost".listen &&
  lib.hasInfix "--service=${lib.escapeShellArg service} --https=443 http://127.0.0.1:${toString site.port}" unit.script &&
  lib.hasInfix "tailscale serve advertise ${lib.escapeShellArg service}" unit.script &&
  lib.hasInfix ".BackendState == \"Running\"" unit.script &&
  lib.hasInfix ".CurrentTailnet.MagicDNSSuffix == $suffix" unit.script &&
  lib.hasInfix "--arg suffix ${lib.escapeShellArg "example.ts.net"}" unit.script &&
  lib.hasInfix "--argjson tags ${lib.escapeShellArg (builtins.toJSON site.hostTags)}" unit.script &&
  lib.hasInfix "($tags - $actual | length) == 0" unit.script &&
  lib.hasInfix ".CertDomains" unit.script &&
  lib.hasInfix ".Services[$service] == $expected" unit.script &&
  lib.hasInfix ".Services[$service] == $expected" unit.postStop &&
  lib.hasInfix "tailscale serve drain ${lib.escapeShellArg service}" unit.postStop &&
  lib.hasInfix "tailscale serve clear ${lib.escapeShellArg service}" unit.postStop &&
  lib.hasInfix "flock 9" unit.script && lib.hasInfix "flock 9" unit.postStop &&
  !(lib.hasInfix "--bg=false" unit.script) &&
  !(lib.hasInfix "--yes" unit.script) &&
  !(lib.hasInfix "funnel" (unit.script + unit.postStop)) &&
  !(lib.hasInfix "serve reset" (unit.script + unit.postStop)) &&
  unit.serviceConfig.Type == "oneshot" &&
  unit.serviceConfig.RemainAfterExit &&
  unit.serviceConfig.Restart == "on-failure" &&
  builtins.elem "multi-user.target" unit.wantedBy &&
  builtins.all (dependency: builtins.elem dependency unit.after && builtins.elem dependency unit.partOf &&
    builtins.elem dependency unit.wantedBy) [ "tailscaled.service" "nginx.service" ]
) [ "nextcloud" "grafana" ];
assert n.networking.firewall.interfaces.tailscale0.allowedTCPPorts == [];
assert n.networking.firewall.allowedTCPPorts == [];
assert n.security.acme.certs == {};
assert builtins.elem "files.example.ts.net" n.services.nextcloud.settings.trusted_domains;
assert n.services.grafana.settings.server.root_url == "https://metrics.example.ts.net/";
assert builtins.attrNames n.sops.secrets == builtins.attrNames c.sops.secrets;
assert mixed.networking.firewall.interfaces.tailscale0.allowedTCPPorts == [ 8083 ];
assert mixed.ryra.services.web.grafana.url == "https://apps.example.ts.net:8083";
assert mixed.ryra.services.web.nextcloud.url == "https://files.example.ts.net";
assert !(removed.systemd.services ? ryra-serve-grafana);
assert removed.systemd.services ? ryra-serve-nextcloud;
assert refusedNamed { services.tailscale.enable = lib.mkForce false; };
assert refusedNamed { ryra.services.web.grafana.domain = lib.mkForce "metrics.example.com"; };
assert refusedNamed { ryra.services.web.grafana.domain = lib.mkForce "files.example.ts.net"; };
assert refusedNamed { ryra.services.web.grafana.hostTags = lib.mkForce []; };
assert refusedNamed { ryra.services.web.grafana.hostTags = lib.mkForce [ "ryra" ]; };
assert refusedNamed { ryra.services.web.grafana.externalUrl = "https://metrics.example.ts.net:8083"; };
assert refusedNamed { ryra.services.web.grafana.privateHttps = true; };
assert refusedNamed { ryra.services.web.grafana.port = 8082; };
assert lib.assertMsg (gatewayFailures == []) (lib.concatStringsSep "\n" gatewayFailures);
assert builtins.all (name:
  g.ryra.services.web.${name}.url == "https://${name}.example.com" &&
  g.ryra.services.web.${name}.hostName == "${name}.example.com" &&
  builtins.all (listen: listen.addr == "127.0.0.1" && listen.port == g.ryra.services.web.${name}.port && !listen.ssl)
    g.services.nginx.virtualHosts."${name}.example.com".listen &&
  !(g.systemd.services ? "ryra-serve-${name}")
) [ "nextcloud" "grafana" ];
assert g.networking.firewall.allowedTCPPorts == [];
assert g.security.acme.certs == {};
assert builtins.elem "nextcloud.example.com" g.services.nextcloud.settings.trusted_domains;
assert g.services.grafana.settings.server.root_url == "https://grafana.example.com/";
assert !g.services.nginx.virtualHosts."grafana.example.com".locations."/".recommendedProxySettings;
assert c.services.nginx.virtualHosts."grafana.localhost".locations."/".recommendedProxySettings;
assert builtins.all (name:
  let location = proxyApps.services.nginx.virtualHosts."${name}.example.com".locations."/";
  in !location.recommendedProxySettings &&
    builtins.length (lib.splitString "proxy_set_header X-Forwarded-Proto https;" location.extraConfig) == 2 &&
    builtins.length (lib.splitString "proxy_set_header Host ${name}.example.com;" location.extraConfig) == 2
) [ "authelia" "linkding" ];
assert g.ryra.services.state == c.ryra.services.state;
assert g.services.nextcloud.home == c.services.nextcloud.home;
assert g.services.grafana.dataDir == c.services.grafana.dataDir;
assert refusedGateway { ryra.services.web.grafana.provider = lib.mkForce null; };
assert refusedGateway { ryra.services.web.grafana.provider = lib.mkForce "fixture/missing"; };
assert refusedGateway { ryra.services.web.grafana.provider = lib.mkForce "ryra/grafana"; };
assert refusedGateway { ryra.services.web.grafana.domain = lib.mkForce null; };
assert refusedGateway { ryra.services.web.grafana.domain = lib.mkForce "http://metrics.example.com"; };
assert refusedGateway { ryra.services.web.grafana.domain = lib.mkForce "nextcloud.example.com"; };
assert refusedGateway { ryra.services.web.grafana.port = 8082; };
assert refusedGateway { ryra.services.web.grafana.port = 443; };
assert refusedGateway { ryra.services.web.grafana.privateHttps = true; };
assert refusedGateway { ryra.services.web.grafana.externalUrl = "https://elsewhere.example.com"; };
assert refusedGateway { ryra.services.web.grafana.externalUrl = lib.mkForce null; };
assert refused { ryra.services.web.grafana.provider = "fixture/gateway"; };
assert builtins.all (config:
  let errors = map (a: a.message) (builtins.filter (a: !a.assertion) config.assertions);
  in lib.assertMsg (errors == []) (lib.concatStringsSep "\n" errors)
) [ p h d privateDns s privateSupplied defaultSupplied privateDefaultSupplied switched ];
assert p.networking.firewall.allowedTCPPorts == [ 80 443 ];
assert builtins.all (name:
  p.ryra.services.web.${name}.certificate.mode == "automatic" &&
  p.services.nginx.virtualHosts."${name}.example.com".enableACME &&
  p.services.nginx.virtualHosts."${name}.example.com".forceSSL &&
  p.security.acme.certs."${name}.example.com".webroot == "/var/lib/acme/acme-challenge" &&
  p.security.acme.certs."${name}.example.com".dnsProvider == null &&
  d.services.nginx.virtualHosts."${name}.example.com".onlySSL &&
  !d.services.nginx.virtualHosts."${name}.example.com".forceSSL &&
  !d.services.nginx.virtualHosts."${name}.example.com".enableACME &&
  d.services.nginx.virtualHosts."${name}.example.com".useACMEHost == "${name}.example.com" &&
  d.security.acme.certs."${name}.example.com".dnsProvider == "rfc2136" &&
  d.security.acme.certs."${name}.example.com".environmentFile == "/run/secrets/acme-dns" &&
  d.security.acme.certs."${name}.example.com".webroot == null &&
  d.security.acme.certs."${name}.example.com".group == d.services.nginx.group &&
  d.security.acme.certs."${name}.example.com".reloadServices == [ "nginx.service" ]
) [ "nextcloud" "grafana" ];
assert d.networking.firewall.allowedTCPPorts == [ 443 ];
assert h.networking.firewall.allowedTCPPorts == [ 80 ];
assert h.networking.hosts."127.0.0.1" == [ "apps.example.com" ];
assert builtins.attrNames h.security.acme.certs == [ "apps.example.com" ];
assert h.security.acme.certs."apps.example.com".webroot == "/var/lib/acme/acme-challenge";
assert h.services.nginx.virtualHosts."ryra-acme-apps.example.com".locations."/".return == "404";
assert privateDns.networking.firewall.allowedTCPPorts == [];
assert builtins.attrNames privateDns.services.nginx.virtualHosts == [ "grafana.localhost" "nextcloud.localhost" ];
assert builtins.attrNames privateDns.security.acme.certs == [ "apps.example.com" ];
assert privateDns.security.acme.certs."apps.example.com".dnsProvider == "rfc2136";
assert builtins.all (config:
  builtins.all (name: builtins.all (listen: listen.addr == "127.0.0.1" && listen.ssl)
    config.services.nginx.virtualHosts."${name}.localhost".listen) [ "nextcloud" "grafana" ] &&
  config.ryra.services.state == c.ryra.services.state
) [ h privateDns ];
assert refusedDns { credentialsFile = lib.mkForce null; };
assert refusedDns { dnsProvider = lib.mkForce null; };
assert refusedDns { dnsProvider = lib.mkForce ""; };
assert refusedDns { certificateFile = "/run/certs/app.pem"; };
assert refusedDns { credentialsFile = lib.mkForce "/nix/store/credential"; };
assert refusedDns { credentialsFile = lib.mkForce "/run/../nix/store/credential"; };
assert refusedDns { credentialsFile = lib.mkForce "relative-credential"; };
assert refused { ryra.services.web.grafana.certificate = dns; };
assert refusedNamed { ryra.services.web.grafana.certificate = dns; };
assert refusedGateway { ryra.services.web.grafana.certificate = dns; };
assert s.networking.firewall.allowedTCPPorts == [ 443 ];
assert privateSupplied.networking.firewall.allowedTCPPorts == [];
assert builtins.all (name:
  defaultSupplied.ryra.services.web.${name}.certificate.certificateFile == "/var/lib/ryra/certificates/${name}.example.com/fullchain.pem" &&
  defaultSupplied.ryra.services.web.${name}.certificate.keyFile == "/var/lib/ryra/certificates/${name}.example.com/key.pem" &&
  privateDefaultSupplied.ryra.services.web.${name}.certificate.certificateFile == "/var/lib/ryra/certificates/apps.example.com/fullchain.pem" &&
  privateDefaultSupplied.ryra.services.web.${name}.certificate.keyFile == "/var/lib/ryra/certificates/apps.example.com/key.pem" &&
  builtins.elem "d /var/lib/ryra/certificates/${name}.example.com 0750 root nginx -" defaultSupplied.systemd.tmpfiles.rules
) [ "nextcloud" "grafana" ];
assert builtins.all (config:
  lib.hasInfix "ryra-check-certificates" config.services.nginx.preStart &&
  lib.hasSuffix "/bin/ryra-check-certificates" (builtins.head config.systemd.services.nginx.serviceConfig.ExecReload) &&
  builtins.length config.systemd.services.nginx.serviceConfig.ExecReload == 3 &&
  config.systemd.services.nginx.serviceConfig.User == config.services.nginx.user &&
  builtins.any (package: (package.name or "") == "ryra-check-certificates") config.environment.systemPackages
) [ s privateSupplied defaultSupplied privateDefaultSupplied ];
assert !(lib.hasInfix "ryra-check-certificates" p.services.nginx.preStart);
assert builtins.length p.systemd.services.nginx.serviceConfig.ExecReload == 2;
assert builtins.all (config:
  config.security.acme.certs == {} && !config.security.acme.acceptTerms
) [ s privateSupplied ];
assert builtins.all (name:
  builtins.all (host: host.onlySSL && !host.enableACME && host.useACMEHost == null &&
    host.sslCertificate == supplied.certificateFile && host.sslCertificateKey == supplied.keyFile
  ) [ s.services.nginx.virtualHosts."${name}.example.com" privateSupplied.services.nginx.virtualHosts."${name}.localhost" ] &&
  builtins.all (listen: listen.addr == "127.0.0.1" && listen.ssl)
    privateSupplied.services.nginx.virtualHosts."${name}.localhost".listen &&
  switched.ryra.services.web.${name}.url == "http://127.0.0.1:${toString c.ryra.services.web.${name}.port}" &&
  switched.ryra.services.web.${name}.externalUrl == null
) [ "nextcloud" "grafana" ];
assert builtins.all (config:
  config.ryra.services.state == c.ryra.services.state &&
  config.services.nextcloud.home == c.services.nextcloud.home &&
  config.services.grafana.dataDir == c.services.grafana.dataDir &&
  builtins.attrNames config.sops.secrets == builtins.attrNames c.sops.secrets &&
  config.services.nextcloud.settings."overwrite.cli.url" == config.ryra.services.web.nextcloud.url &&
  config.services.grafana.settings.server.root_url == "${config.ryra.services.web.grafana.url}/"
) [ n g p h d privateDns s privateSupplied switched ];
assert refusedSupplied { keyFile = lib.mkForce null; };
assert refusedSupplied { certificateFile = lib.mkForce null; };
assert refusedSupplied { keyFile = lib.mkForce "/nix/store/private-key"; };
assert refusedSupplied { certificateFile = lib.mkForce "/nix/store/certificate"; };
assert refusedSupplied { keyFile = lib.mkForce "/run/../nix/store/private-key"; };
assert refusedSupplied { keyFile = lib.mkForce "/run/certs/private key"; };
assert refusedSupplied { keyFile = lib.mkForce "/run/certs/key;include"; };
assert refusedSupplied { dnsProvider = "rfc2136"; };
assert refusedSupplied { credentialsFile = "/run/secrets/acme-dns"; };
assert refusedSupplied { mode = lib.mkForce "automatic"; };
assert refused { ryra.services.web.grafana.certificate = supplied; };
assert refusedNamed { ryra.services.web.grafana.certificate = supplied; };
assert refusedGateway { ryra.services.web.grafana.certificate = supplied; };
assert builtins.any (a: !a.assertion) ((directSystem "private" dns).extendModules { modules = [ {
  ryra.services.web.grafana.certificate.credentialsFile = lib.mkForce "/run/secrets/other-dns";
} ]; }).config.assertions;
{
  inherit failures namedFailures gatewayFailures;
  apps = builtins.fromJSON c.environment.etc."ryra/apps.json".text;
  namedApps = builtins.fromJSON n.environment.etc."ryra/apps.json".text;
  gatewayApps = builtins.fromJSON g.environment.etc."ryra/apps.json".text;
}
