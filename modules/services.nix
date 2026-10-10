{ config, lib, machineDir, serviceRegistries, serviceModule, ... }:
let
  enabled = builtins.fromJSON (builtins.readFile (machineDir + "/modules/ryra/services.json"));
  settings = import (machineDir + "/modules/ryra/settings.nix");
  webPath = machineDir + "/modules/ryra/web.json";
  web = if builtins.pathExists webPath then builtins.fromJSON (builtins.readFile webPath) else {};
  websites = lib.attrValues (config.ryra.services.web or {});
in {
  imports = lib.optional (enabled != [])
    (serviceModule {
      registries = serviceRegistries;
      services = builtins.listToAttrs (map (name: {
        inherit name;
        value = (settings.${name} or {}) // { web = web.${name} or {}; };
      }) enabled);
    });

  ryra.deployment.requiredUnits = lib.optional (websites != []) "nginx.service";
  ryra.deployment.healthChecks = map (site: ''
    curl --fail --silent --show-error --max-time 10 \
      ${lib.optionalString (site.access == "public") "--resolve ${lib.escapeShellArg "${site.hostName}:443:127.0.0.1"}"} \
      ${lib.escapeShellArg (site.url + site.healthPath)} >/dev/null
  '') websites;
}
