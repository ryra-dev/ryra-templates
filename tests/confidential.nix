# Pass the image builder's actual hardware module as ownerModule.
{ ownerModule }:
let
  flake = builtins.getFlake ("path:" + toString ../.);
  pkgs = flake.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
  machine = pkgs.runCommand "confidential-owner-template-check" {} ''
    cp -r ${../machines/base} "$out"
    chmod -R u+w "$out"
    echo '{"platform":"confidential","system":"x86_64-linux"}' > "$out/modules/ryra/hardware.json"
    cp ${ownerModule} "$out/modules/ryra/confidential-owner.nix"
  '';
  base = (flake.lib.mkMachine { self = machine; }).nixosConfigurations.machine;
  failures = configuration: map (a: a.message)
    (builtins.filter (a: !a.assertion) configuration.assertions);
  config = base.config;
  substitutedKey = (base.extendModules { modules = [ ({ lib, ... }: {
    services.openssh.hostKeys = lib.mkForce [{ type = "ed25519"; path = "/etc/ssh/other-key"; }];
  }) ]; }).config;
in
assert config.boot.isContainer;
assert config.disko.devices.disk == {};
assert !config.boot.loader.grub.enable;
assert !config.systemd.timers.ryra-snapshot-prune.enable;
assert config.networking.firewall.enable;
assert builtins.elem 22 config.networking.firewall.allowedTCPPorts;
assert config.nix.buildMachines == [];
assert config.swapDevices == [];
assert failures config == [];
assert failures substitutedKey != [];
{
  container = config.boot.isContainer;
  hostKey = map (key: key.path) config.services.openssh.hostKeys;
  diskLayout = config.disko.devices.disk;
  firewall = config.networking.firewall.enable;
  failures = failures config;
}
