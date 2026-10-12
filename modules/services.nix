{ config, lib, pkgs, machineDir, serviceRegistries, serviceModule, ryraServicePhase ? "final", ... }:
let
  enabled = builtins.fromJSON (builtins.readFile (machineDir + "/modules/ryra/services.json"));
  settings = import (machineDir + "/modules/ryra/settings.nix");
  provider = settings.auth.provider or null;
  webPath = machineDir + "/modules/ryra/web.json";
  web = if builtins.pathExists webPath then builtins.fromJSON (builtins.readFile webPath) else {};
  authPath = machineDir + "/modules/ryra/auth.json";
  auth = if builtins.pathExists authPath then builtins.fromJSON (builtins.readFile authPath) else {};
  backupPath = machineDir + "/modules/ryra/backup.json";
  backups = if builtins.pathExists backupPath then builtins.fromJSON (builtins.readFile backupPath) else {};
  websites = lib.attrValues (config.ryra.services.web or {});
  bootstrap = ryraServicePhase == "https_bootstrap";
  phaseSites = if bootstrap then map (name: web.${name} or {}) enabled else websites;
  hosts = builtins.sort builtins.lessThan (lib.unique (map (site:
    let url = site.externalUrl or null;
      origin = if url == null then null else builtins.match "https://([a-zA-Z0-9.-]+)(:[0-9]+)?" url;
    in if origin == null then throw "Review a concrete private HTTPS hostname before preparing challenge ingress."
      else builtins.head origin
  ) (builtins.filter (site: (site.privateHttps or false) && (site.access or "private") == "private") phaseSites)));
  webroot = "/var/lib/acme/acme-challenge";
  challengeNames = map (host: "ryra-https-bootstrap-${host}") hosts;
  issuer = config.services.ryraSshIssuer or {};
  issuerPresent = config.services.nginx.virtualHosts ? ryra-issuer;
  safeIssuer = let vhost = config.services.nginx.virtualHosts.ryra-issuer;
    in (issuer.enable or false) && issuer.listen == "127.0.0.1:8788"
      && vhost.serverName == null && vhost.serverAliases == [] && vhost.listenAddresses == []
      && vhost.onlySSL && !vhost.addSSL && !vhost.forceSSL && !vhost.rejectSSL
      && !vhost.enableACME && vhost.useACMEHost == null
      && !vhost.default && vhost.root == null && vhost.globalRedirect == null
      && vhost.basicAuth == {} && vhost.basicAuthFile == null
      && !vhost.quic && !vhost.http3_hq && !vhost.reuseport && vhost.sslTrustedCertificate == null
      && vhost.listen == map (addr: {
        inherit addr; port = 8789; ssl = true; proxyProtocol = false; extraParameters = [];
      }) [ "0.0.0.0" "[::]" ]
      && vhost.sslCertificate == "/run/credentials/nginx.service/ryra-issuer-cert"
      && vhost.sslCertificateKey == "/run/credentials/nginx.service/ryra-issuer-key"
      && config.systemd.services.nginx.serviceConfig.LoadCredential == [
        "ryra-issuer-cert:/var/lib/ryra-issuer-tls/server.pem"
        "ryra-issuer-key:/var/lib/ryra-issuer-tls/server.key"
      ]
      && vhost.extraConfig == "client_max_body_size 16k;"
      && builtins.attrNames vhost.locations == [ "/" "/certificate" ]
      && vhost.locations."/".return == "404" && vhost.locations."/".proxyPass == null
      && vhost.locations."/certificate".proxyPass == "http://127.0.0.1:8788"
      && vhost.locations."/certificate".return == null
      && builtins.all (location: location.extraConfig == "" && location.root == null
        && location.alias == null && location.uwsgiPass == null && location.tryFiles == null
        && location.index == null && location.fastcgiParams == {} && !location.proxyWebsockets
        && !location.useGrpcErrorPages && location.basicAuth == {} && location.basicAuthFile == null
      ) (lib.attrValues vhost.locations);
  challengeHosts = lib.listToAttrs (map (host: lib.nameValuePair "ryra-https-bootstrap-${host}" {
    serverName = host;
    listen = [ { addr = "0.0.0.0"; port = 80; } ];
    locations = {
      "/".return = "404";
      "^~ /.well-known/acme-challenge/".root = webroot;
    };
  }) hosts);
  safeHost = name: expectedName: paths:
    let vhost = config.services.nginx.virtualHosts.${name};
    in vhost.serverName == expectedName && vhost.serverAliases == [] && vhost.extraConfig == ""
      && builtins.attrNames vhost.locations == builtins.sort builtins.lessThan paths
      && builtins.all (listener: listener.addr == "0.0.0.0" && listener.port == 80 && !listener.ssl
        && !listener.proxyProtocol && listener.extraParameters == []) vhost.listen
      && builtins.length vhost.listen == 1
      && builtins.all (location: location.proxyPass == null && location.extraConfig == "") (lib.attrValues vhost.locations)
      && vhost.locations."/".return == "404";
in {
  imports = lib.optional (!bootstrap && (enabled != [] || provider != null))
    (serviceModule {
      registries = serviceRegistries;
      backupRepositoryFor = name:
        if backups ? ${name} then (if backups.${name} == null then null else {
          path = backups.${name}.repository;
          inherit (backups.${name}) environmentFile;
        }) else settings.backup.repositories.${name} or { path = "/srv/backups/${name}"; };
      services = builtins.listToAttrs (map (name: {
        inherit name;
        value = (settings.${name} or {}) // { web = web.${name} or {}; }
          // lib.optionalAttrs (auth ? ${name}) {
            auth = (settings.${name}.auth or {}) // auth.${name};
          };
      }) enabled);
    });

  config = if bootstrap then {
    assertions = [
      { assertion = hosts != [];
        message = "HTTPS bootstrap requires reviewed private HTTPS origins."; }
      { assertion = builtins.attrNames config.services.nginx.virtualHosts == builtins.sort builtins.lessThan ([ "ryra-https-bootstrap-default" ] ++ challengeNames ++ lib.optional issuerPresent "ryra-issuer")
          && (!issuerPresent || safeIssuer)
          && config.services.nginx.httpConfig == "" && config.services.nginx.appendHttpConfig == ""
          && config.services.nginx.streamConfig == "" && config.services.nginx.appendConfig == ""
          && config.services.nginx.config == "" && config.services.nginx.commonHttpConfig == "";
        message = "Custom nginx configuration cannot be projected safely into challenge-only setup. Review a separate preparation configuration."; }
      { assertion = config.security.acme.certs == {};
        message = "HTTPS bootstrap cannot start certificate orders before challenge ingress is committed."; }
      { assertion = safeHost "ryra-https-bootstrap-default" "_" [ "/" ]
          && builtins.all (host: safeHost "ryra-https-bootstrap-${host}" host [ "/" "^~ /.well-known/acme-challenge/" ]
            && config.services.nginx.virtualHosts."ryra-https-bootstrap-${host}".locations."^~ /.well-known/acme-challenge/".root == webroot
            && config.services.nginx.virtualHosts."ryra-https-bootstrap-${host}".locations."^~ /.well-known/acme-challenge/".return == null) hosts;
        message = "HTTPS bootstrap permits only its exact-host static challenge routes. Custom listeners, aliases and locations need a separate reviewed configuration."; }
    ];
    environment.etc."ryra/service-network.json".text = builtins.toJSON {
      phase = "https_bootstrap"; challenge_hosts = hosts; managed_apps = [];
    };
    services.nginx = {
      enable = true;
      serverNamesHashBucketSize = lib.mkDefault 128;
      virtualHosts = challengeHosts // {
        ryra-https-bootstrap-default = {
          serverName = "_";
          default = true;
          listen = [ { addr = "0.0.0.0"; port = 80; } ];
          locations."/".return = "404";
        };
      };
    };
    systemd.tmpfiles.rules = [ "d ${webroot}/.well-known/acme-challenge 0755 root root -" ]
      ++ map (host: "L+ ${webroot}/.well-known/acme-challenge/ryra-bootstrap-${host} - - - - ${pkgs.writeText "ryra-https-bootstrap-health" host}") hosts;
    networking.firewall.allowedTCPPorts = [ 80 ];
    ryra.deployment.requiredUnits = [ "nginx.service" ];
    ryra.deployment.healthChecks = map (host: ''
      test "$(curl --fail --silent --show-error --max-time 10 \
        --header ${lib.escapeShellArg "Host: ${host}"} \
        ${lib.escapeShellArg "http://127.0.0.1/.well-known/acme-challenge/ryra-bootstrap-${host}"})" = ${lib.escapeShellArg host}
    '') hosts;
  } else {
    environment.etc."ryra/service-network.json".text = builtins.toJSON {
      phase = "final"; challenge_hosts = hosts; managed_apps = enabled;
    };
    ryra.deployment.requiredUnits = lib.optional (websites != []) "nginx.service";
    ryra.deployment.healthChecks = map (site: ''
      curl --fail --silent --show-error --max-time 10 \
        ${lib.optionalString (site.access == "public") "--resolve ${lib.escapeShellArg "${site.hostName}:443:127.0.0.1"}"} \
        ${lib.escapeShellArg (site.url + site.healthPath)} >/dev/null
    '') websites;
  } // lib.optionalAttrs (provider != null && !bootstrap) { ryra.services.auth.provider = provider; };
}
