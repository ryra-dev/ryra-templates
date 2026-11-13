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
    own = { system = "x86_64-linux"; platform = "own"; };
  };
  # A cloud's NixOS image as the machine's own hardware, which Ryra's layout once collided with.
  ownHardware = pkgs.writeText "hardware.nix" ''
    { modulesPath, ... }: { imports = [ "''${modulesPath}/virtualisation/amazon-image.nix" ]; }
  '';
  on = hardware: pkgs.runCommand "ryra-machine" {} (''
    cp -r ${../machines/base} $out && chmod -R u+w $out
    echo ${pkgs.lib.escapeShellArg (builtins.toJSON hardware)} > $out/modules/ryra/hardware.json
  '' + pkgs.lib.optionalString ((hardware.platform or null) == "own") ''
    cp ${ownHardware} $out/modules/hardware.nix
  '');
in
builtins.mapAttrs (_: hardware: (flake.lib.mkMachine { self = on hardware; }).nixosConfigurations.machine) facts
