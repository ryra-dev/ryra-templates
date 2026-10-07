let
  flake = builtins.getFlake ("path:" + toString ../.);
  project = ./organization;
  organization = flake.lib.mkOrganization { self = project; };
  inspect = name:
    let c = organization.nixosConfigurations.${name}.config;
    in
    assert c.networking.hostName == name;
    assert c.environment.etc."shared-content".text == "One shared source.\n";
    assert c.sops.secrets.token.sopsFile == project + "/hosts/common/secrets/vault.yaml";
    assert c.services.ryra-update.reviewedSource == project;
    assert organization.ryraCatalog.${name} ? ryra;
    { host = c.networking.hostName; shared = c.environment.etc."shared-content".text; };
in
assert builtins.attrNames organization.nixosConfigurations == [ "one" "two" ];
builtins.mapAttrs (name: _: inspect name) organization.nixosConfigurations
