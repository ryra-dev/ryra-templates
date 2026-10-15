# The one template, on each kind of hardware Ryra measures, as mkMachine sees it.
let
  flake = builtins.getFlake ("path:" + toString ../.);
  pkgs = flake.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
  facts = {
    base = { system = "x86_64-linux"; };
    base-arm = { system = "aarch64-linux"; };
    azure = { system = "x86_64-linux"; platform = "azure"; };
    lima = { system = "aarch64-linux"; platform = "lima"; };
    lima-intel = { system = "x86_64-linux"; platform = "lima"; };
  };
  on = hardware: pkgs.runCommand "ryra-machine" {} ''
    cp -r ${../machines/base} $out && chmod -R u+w $out
    echo ${pkgs.lib.escapeShellArg (builtins.toJSON hardware)} > $out/modules/ryra/hardware.json
  '';
in
builtins.mapAttrs (_: hardware: (flake.lib.mkMachine { self = on hardware; }).nixosConfigurations.machine) facts
