{
  description = "Ryra organization flakes and machine modules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ryra-services.url = "github:ryra-dev/ryra-services";
    herdr-pkgs.url = "github:NixOS/nixpkgs/ca1659429c950a11a565b5764e37a1b704e17ec8";
    cua = {
      url = "github:trycua/cua/e88e9d899ac5effaeae38619527ebaa46b26ce72";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lima = {
      url = "github:nixos-lima/nixos-lima/24916c8e8719298499593e94a63f26eba839711b";
      flake = false;
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, sops-nix, ... }@sharedInputs:
    let
      names = [ "base" "base-arm" "azure" "desktop" "lima" "lima-intel" "qemu" ];
      mkMachine = { self, inputs ? {}, machineDir ? self, hostName ? "machine", modules ? [], specialArgs ? {} }:
        let
          sources = sharedInputs // inputs;
          registries = import (machineDir + "/registries.nix") sources;
          bootstrapPorts = machineDir + "/modules/ryra/https-bootstrap-ports.nix";
          make = phase: extraModules: nixpkgs.lib.nixosSystem {
            specialArgs = specialArgs // {
              inherit self hostName machineDir;
              ryraServicePhase = phase;
              ryraModules = sharedInputs.self.nixosModules;
              serviceRegistries = registries;
              serviceModule = sources.ryra-services.nixosModules.services;
            };
            modules = [
              sharedInputs.self.nixosModules.default
              (machineDir + "/configuration.nix")
              ({ config, ... }: {
                _module.args.herdrPkgs = sources.herdr-pkgs.legacyPackages.${config.nixpkgs.hostPlatform.system};
                _module.args.cuaDriver = sources.cua.packages.${config.nixpkgs.hostPlatform.system}.cua-driver;
                _module.args.cuaGnomeExtension = sources.cua + "/libs/cua-driver/wayland-helper/winrects@cua";
              })
            ] ++ modules ++ extraModules ++ builtins.filter
              (path: path != machineDir + "/modules/ryra/settings.nix"
                && path != bootstrapPorts
                && (phase != "https_bootstrap" || path != machineDir + "/modules/ryra-ports.nix")
                && nixpkgs.lib.hasSuffix ".nix" (toString path))
              (nixpkgs.lib.filesystem.listFilesRecursive (machineDir + "/modules"));
          };
          machine = make "final" [];
          bootstrap = make "https_bootstrap" [ bootstrapPorts ({ config, lib, ... }: {
            environment.etc."ryra/deploy/preflight".source = lib.mkForce machine.config.environment.etc."ryra/deploy/preflight".source;
            assertions = [ {
              assertion = (builtins.fromJSON config.environment.etc."ryra/service-network.json".text).challenge_hosts
                == (builtins.fromJSON machine.config.environment.etc."ryra/service-network.json".text).challenge_hosts;
              message = "Custom service settings changed the private HTTPS challenge hosts. Review explicit origins before preparing ingress.";
            } ];
            # Native account defaults win for users already declared by the base.
            users.users = nixpkgs.lib.mapAttrs (_: user: lib.mapAttrs (_: lib.mkOverride 1400) {
              inherit (user) isSystemUser uid group extraGroups home createHome homeMode shell;
            }) (nixpkgs.lib.filterAttrs (_: user: !user.isNormalUser) machine.config.users.users);
            users.groups = nixpkgs.lib.mapAttrs (_: group: lib.mapAttrs (_: lib.mkOverride 1400) {
              inherit (group) gid members;
            }) machine.config.users.groups;
          }) ];
        in {
          nixosConfigurations = { ${hostName} = machine; }
            // nixpkgs.lib.optionalAttrs (builtins.pathExists bootstrapPorts) {
              "${hostName}-https-bootstrap" = bootstrap;
            };
          ryraCatalog = builtins.mapAttrs (_: source: {
            flake = "path:${source.outPath}";
            index = source.index;
          }) registries;
        };
      mkOrganization = { self, inputs ? {} }:
        let
          declaration = builtins.fromTOML (builtins.readFile (self + "/organization.toml"));
          machines = builtins.listToAttrs (map (machine: {
            name = machine.name;
            value = mkMachine {
              inherit self inputs;
              hostName = machine.name;
              specialArgs = { inherit machine declaration; };
              machineDir = self + "/${machine.config or "machines/${machine.name}"}";
              modules = nixpkgs.lib.concatMap (stack:
                builtins.filter (path: nixpkgs.lib.hasSuffix ".nix" (toString path))
                  (nixpkgs.lib.filesystem.listFilesRecursive (self + "/stacks/${stack}"))
              ) (nixpkgs.lib.unique ((machine.stacks or []) ++ nixpkgs.lib.concatMap
                (group: group.stacks or [])
                (builtins.filter (group: builtins.elem group.name
                  ((machine.access or []) ++ (machine.admin or []))) (declaration.groups or []))));
            };
          }) (builtins.filter (machine: machine ? template || builtins.pathExists
            (self + "/${machine.config or "machines/${machine.name}"}/configuration.nix"))
            (declaration.machines or [])));
        in {
          nixosConfigurations = nixpkgs.lib.foldl' (outputs: machine:
            if builtins.any (name: outputs ? ${name}) (builtins.attrNames machine.nixosConfigurations)
            then throw "Ryra machine names collide with a generated HTTPS bootstrap output. Rename the conflicting machine."
            else outputs // machine.nixosConfigurations
          ) {} (builtins.attrValues machines);
          ryraCatalog = builtins.mapAttrs (_: machine: machine.ryraCatalog) machines;
        };
    in {
      lib = { inherit mkMachine mkOrganization; };
      nixosModules = {
        default = {
          imports = [ disko.nixosModules.disko sops-nix.nixosModules.sops ./modules/default.nix ];
        };
        azure = import ./modules/azure.nix;
        azure-image = import ./modules/azure-image;
        cloud-init = import ./modules/cloud-init.nix;
        qemu = import ./modules/qemu.nix;
        lima-boot = import ./modules/lima-boot.nix;
        lima = {
          imports = [
            (sharedInputs.lima + "/lima-init.nix")
            ./modules/lima.nix
          ];
        };
      };
      index = builtins.listToAttrs (map (name: {
        inherit name;
        value = (import ./machines/${name}/catalog.nix) // { directory = "machines/${name}"; };
      }) names);
      templates = (builtins.mapAttrs (name: meta: {
        path = ./machines/${name};
        description = meta.summary;
        welcomeText = meta.description;
      }) self.index) // {
        default = self.templates.base;
        azure-image = {
          path = ./machines/azure-image;
          description = "Clean Azure Gen 2 NixOS image for pre-provisioned computers";
          welcomeText = builtins.readFile ./machines/azure-image/README.md;
        };
      };
      checks.x86_64-linux.computer-control = import ./tests/computer-control.nix {
        desktop = (mkMachine { self = ./machines/desktop; }).nixosConfigurations.machine;
      };
      checks.x86_64-linux.deployment-health = import ./tests/deployment.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        machine = mkMachine { self = ./tests/guided-network/machine; };
      };
    };
}
