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
    }) ] ++ lib.optional (custom == "extra_host") ({ ... }: {
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
assert !(builtins.tryEval (machine "custom_origin").nixosConfigurations.machine-https-bootstrap.config.assertions).success;
{
  passed = [ "two-stable-outputs" "management-preserved" "sops-owner-preserved" "managed-apps-omitted" "custom-settings-retained" "challenge-only-http" "actual-http-health" "strict-final-tls-health" "port80-only-bootstrap" "custom-nginx-refusal" "custom-route-refusal" "custom-origin-refusal" ];
}
