{
  description = "Ryra machine modules and compatibility templates";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ryra-services.url = "github:ryra-dev/ryra-services";
    herdr-pkgs.url = "github:NixOS/nixpkgs/c043004d1c6985732bcc1cbc5a9c9aecbbb4e0f0";
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
      names = [ "base" "base-arm" "azure" "desktop" "lima" "lima-intel" ];
      mkMachine = { self, inputs ? {} }:
        let
          sources = sharedInputs // inputs;
          hostName = nixpkgs.lib.fileContents (self + "/hostname");
          registries = import (self + "/registries.nix") sources;
          machine = nixpkgs.lib.nixosSystem {
            specialArgs = {
              inherit self hostName;
              machineDir = self;
              ryraModules = sharedInputs.self.nixosModules;
              serviceRegistries = registries;
              serviceModule = sources.ryra-services.nixosModules.services;
            };
            modules = [
              sharedInputs.self.nixosModules.default
              (self + "/configuration.nix")
              ({ config, ... }: {
                _module.args.herdrPkgs = sources.herdr-pkgs.legacyPackages.${config.nixpkgs.hostPlatform.system};
                _module.args.cuaDriver = sources.cua.packages.${config.nixpkgs.hostPlatform.system}.cua-driver;
                _module.args.cuaGnomeExtension = sources.cua + "/libs/cua-driver/wayland-helper/winrects@cua";
              })
            ] ++ builtins.filter
              (path: path != self + "/modules/ryra/settings.nix" && nixpkgs.lib.hasSuffix ".nix" (toString path))
              (nixpkgs.lib.filesystem.listFilesRecursive (self + "/modules"));
          };
        in {
          nixosConfigurations.${hostName} = machine;
          ryraCatalog = builtins.mapAttrs (_: source: {
            flake = "path:${source.outPath}";
            index = source.index;
          }) registries;
        };
    in {
      lib = { inherit mkMachine; };
      nixosModules = {
        default = {
          imports = [ disko.nixosModules.disko sops-nix.nixosModules.sops ./modules/default.nix ];
        };
        azure = import ./modules/azure.nix;
        azure-image = import ./modules/azure-image;
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
    };
}
