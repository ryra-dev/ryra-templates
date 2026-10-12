let
  templates = builtins.getFlake ("path:" + toString ../.);
  services = templates.inputs.ryra-services;
  lib = templates.inputs.nixpkgs.lib;
  machine = custom: templates.lib.mkMachine {
    self = ./guided-network/machine;
    inputs.ryra-services = services;
    modules = [ ({ lib, ... }: {
      sops.defaultSopsFile = builtins.toFile "guided-network-secrets.yaml" "{}";
      sops.validateSopsFiles = false;
    }) ] ++ lib.optional (lib.hasPrefix "issuer" custom) ./guided-network/issuer.nix
    ++ lib.optional (custom == "issuer_listener") ({ lib, ... }: {
      services.nginx.virtualHosts.ryra-issuer.listen = lib.mkForce [ { addr = "0.0.0.0"; port = 443; ssl = true; } ];
    }) ++ lib.optional (custom == "issuer_route") ({ ... }: {
      services.nginx.virtualHosts.ryra-issuer.locations."/app".proxyPass = "http://127.0.0.1:8083";
    }) ++ lib.optional (custom == "issuer_proxy") ({ lib, ... }: {
      services.nginx.virtualHosts.ryra-issuer.locations."/certificate".proxyPass = lib.mkForce "http://127.0.0.1:8083";
    }) ++ lib.optional (custom == "issuer_credentials") ({ lib, ... }: {
      systemd.services.nginx.serviceConfig.LoadCredential = lib.mkForce [ "ryra-issuer-cert:/tmp/custom.pem" ];
    }) ++ lib.optional (custom == "issuer_reload") ({ lib, ... }: {
      systemd.services.nginx.serviceConfig.RefreshOnReload = lib.mkForce "extensions";
    }) ++ lib.optional (custom == "issuer_disabled") ({ lib, ... }: {
      services.ryraSshIssuer.enable = lib.mkForce false;
    }) ++ lib.optional (custom == "issuer_bind") ({ lib, ... }: {
      services.ryraSshIssuer.listen = lib.mkForce "0.0.0.0:8788";
    }) ++ lib.optional (custom == "issuer_certificate") ({ lib, ... }: {
      services.nginx.virtualHosts.ryra-issuer.sslCertificate = lib.mkForce "/tmp/custom.pem";
    }) ++ lib.optional (custom == "issuer_body") ({ lib, ... }: {
      services.nginx.virtualHosts.ryra-issuer.extraConfig = lib.mkForce "client_max_body_size 1m;";
    }) ++ lib.optional (custom == "issuer_location") ({ ... }: {
      services.nginx.virtualHosts.ryra-issuer.locations."/certificate".extraConfig = "proxy_pass http://127.0.0.1:8083;";
    }) ++ lib.optional (custom == "extra_host") ({ ... }: {
      services.nginx.virtualHosts.custom.locations."/".return = "200";
    }) ++ lib.optional (custom == "extra_route") ({ ... }: {
      services.nginx.virtualHosts."ryra-https-bootstrap-machine.example.com".locations."/app".proxyPass = "http://127.0.0.1:8083";
    }) ++ lib.optional (custom == "custom_origin") ({ lib, ... }: {
      ryra.services.web.grafana.externalUrl = lib.mkForce "https://custom.example.com:8083";
    });
  };
  configurations = (machine "none").nixosConfigurations;
  final = configurations.machine.config;
  bootstrap = configurations.machine-https-bootstrap.config;
  issuerConfigurations = (machine "issuer").nixosConfigurations;
  issuerBootstrap = issuerConfigurations.machine-https-bootstrap.config;
  failures = config: map (assertion: assertion.message) (builtins.filter (assertion: !assertion.assertion) config.assertions);
in
assert lib.assertMsg (failures final == []) (lib.concatStringsSep "\n" (failures final));
assert lib.assertMsg (failures bootstrap == []) (lib.concatStringsSep "\n" (failures bootstrap));
assert builtins.attrNames configurations == [ "machine" "machine-https-bootstrap" ];
assert final.networking.hostName == bootstrap.networking.hostName;
assert final.users.users.operator.openssh == bootstrap.users.users.operator.openssh;
assert final.services.openssh.settings == bootstrap.services.openssh.settings;
assert final.environment.etc."ryra/deploy/preflight".source == bootstrap.environment.etc."ryra/deploy/preflight".source;
assert bootstrap.users.users.grafana.uid == final.users.users.grafana.uid;
assert bootstrap.sops.secrets.grafana-fixture.owner == "grafana";
assert final.sops.secrets.grafana-fixture.path == bootstrap.sops.secrets.grafana-fixture.path;
assert final.services.grafana.enable && final.services.lldap.enable;
assert !bootstrap.services.grafana.enable && !bootstrap.services.lldap.enable;
assert bootstrap.services.authelia.instances == {};
assert bootstrap.services.restic.backups == {};
assert final.services.grafana.settings.panels.disable_sanitize_html;
assert bootstrap.security.acme.certs == {};
assert builtins.attrNames bootstrap.services.nginx.virtualHosts == [ "ryra-https-bootstrap-default" "ryra-https-bootstrap-machine.example.com" ];
assert bootstrap.services.nginx.virtualHosts.ryra-https-bootstrap-default.locations."/".return == "404";
assert bootstrap.services.nginx.virtualHosts."ryra-https-bootstrap-machine.example.com".locations."/".return == "404";
assert bootstrap.services.nginx.virtualHosts."ryra-https-bootstrap-machine.example.com".locations."^~ /.well-known/acme-challenge/".root == "/var/lib/acme/acme-challenge";
assert builtins.all (check: lib.hasInfix "curl --fail" check && lib.hasInfix "ryra-bootstrap-machine.example.com" check) bootstrap.ryra.deployment.healthChecks;
assert builtins.all (check: !(lib.hasInfix "--insecure" check)) final.ryra.deployment.healthChecks;
assert (builtins.fromJSON bootstrap.environment.etc."ryra/service-network.json".text).phase == "https_bootstrap";
assert (builtins.fromJSON final.environment.etc."ryra/service-network.json".text).phase == "final";
assert (builtins.fromJSON bootstrap.environment.etc."ryra/service-network.json".text).managed_apps == [];
assert (builtins.fromJSON final.environment.etc."ryra/service-network.json".text).managed_apps == [ "ryra/grafana" "ryra/authelia" ];
assert (builtins.fromJSON bootstrap.environment.etc."ryra/ports.json".text).rules == [ { protocol = "tcp"; port = 80; sources = [ "0.0.0.0/0" ]; } ];
assert failures (machine "extra_host").nixosConfigurations.machine-https-bootstrap.config != [];
assert failures (machine "extra_route").nixosConfigurations.machine-https-bootstrap.config != [];
assert lib.assertMsg (failures issuerBootstrap == []) (lib.concatStringsSep "\n" (failures issuerBootstrap));
assert issuerBootstrap.services.ryraSshIssuer.enable;
assert let endpoint = config: with config.services.nginx.virtualHosts.ryra-issuer; {
  inherit listen onlySSL sslCertificate sslCertificateKey extraConfig;
  certificateProxy = locations."/certificate".proxyPass;
  fallback = locations."/".return;
}; in endpoint issuerBootstrap == endpoint issuerConfigurations.machine.config;
assert issuerBootstrap.systemd.services.ryra-ssh-issuer.serviceConfig.ExecStart
  == issuerConfigurations.machine.config.systemd.services.ryra-ssh-issuer.serviceConfig.ExecStart;
assert builtins.all (custom: failures (machine custom).nixosConfigurations.machine-https-bootstrap.config != [])
  [ "issuer_listener" "issuer_route" "issuer_proxy" "issuer_credentials" "issuer_reload" "issuer_disabled"
    "issuer_bind" "issuer_certificate" "issuer_body" "issuer_location" ];
assert !(builtins.tryEval (machine "custom_origin").nixosConfigurations.machine-https-bootstrap.config.assertions).success;
{
  passed = [ "issuer-preserved" "mutated-issuer-refusal" "two-stable-outputs" "management-preserved" "sops-owner-preserved" "managed-apps-omitted" "custom-settings-retained" "challenge-only-http" "actual-http-health" "strict-final-tls-health" "port80-only-bootstrap" "custom-nginx-refusal" "custom-route-refusal" "custom-origin-refusal" ];
}
