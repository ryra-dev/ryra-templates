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
    assert organization.ryraCatalog.${name}.ryra.flake == "path:${flake.outPath}";
    assert organization.ryraCatalog.${name}.ryra.index.services.nextcloud.deployable;
    assert organization.ryraCatalog.${name}.ryra.index.machines.base.directory == "machines/base";
    { host = c.networking.hostName; shared = c.environment.etc."shared-content".text; };
  # A flake of somebody's own: its hosts, one named like a declared machine, and its other outputs.
  own = hostName: flake.inputs.nixpkgs.lib.nixosSystem {
    modules = [ { nixpkgs.hostPlatform = "x86_64-linux"; networking.hostName = hostName; } ];
  };
  composed = flake.lib.mkOrganization {
    self = project;
    outputs = {
      nixosConfigurations = { lab = own "lab"; two = own "their-two"; };
      packages.x86_64-linux.tool = "kept";
    };
  };
in
assert builtins.attrNames organization.nixosConfigurations == [ "one" "two" ];
assert builtins.attrNames organization.checks.x86_64-linux == [ "one" "two" ];
assert organization.checks.x86_64-linux.one.drvPath
  == organization.nixosConfigurations.one.config.system.build.toplevel.drvPath;
assert builtins.attrNames composed.nixosConfigurations == [ "lab" "one" "two" ];
assert composed.nixosConfigurations.lab.config.networking.hostName == "lab";
assert composed.nixosConfigurations.two.config.networking.hostName == "their-two";
assert composed.nixosConfigurations.one.config.networking.hostName == "one";
assert builtins.attrNames composed.ryraCatalog == [ "one" "two" ];
assert composed.packages.x86_64-linux.tool == "kept";
builtins.mapAttrs (name: _: inspect name) organization.nixosConfigurations
