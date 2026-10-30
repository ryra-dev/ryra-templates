{
  description = "Ryra machines, services and organization configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
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
      directories = path:
        let entries = if builtins.pathExists path then builtins.readDir path else {};
        in builtins.filter (name: entries.${name} == "directory") (builtins.attrNames entries);
      serviceIndex = services: builtins.mapAttrs (name: svc: svc.meta
        // { deployable = svc ? module; }
        // (if svc ? package then { package = name; } else {})) services;
      mkMachine = { self, inputs ? {}, machineDir ? self, hostName ? "machine", modules ? [], specialArgs ? {} }:
        let
          sources = sharedInputs // { ryra-template = sharedInputs.self; } // inputs;
          registries = import (machineDir + "/registries.nix") sources;
          # What the machine is, as Ryra measured it: its architecture, and the platform it runs on
          # when that needs its own module. A machine without the file states both itself.
          hardwareFile = machineDir + "/modules/ryra/hardware.json";
          hardware = if builtins.pathExists hardwareFile then builtins.fromJSON (builtins.readFile hardwareFile) else {};
          platform = { nixpkgs.hostPlatform = nixpkgs.lib.mkIf (hardware ? system) hardware.system; }
            // nixpkgs.lib.optionalAttrs (hardware ? platform) { imports = [ sharedInputs.self.nixosModules.${hardware.platform} ]; };
          bootstrapPorts = machineDir + "/modules/ryra/https-bootstrap-ports.nix";
          make = phase: extraModules: nixpkgs.lib.nixosSystem {
            specialArgs = specialArgs // {
              inherit self hostName machineDir;
              ryraServicePhase = phase;
              ryraModules = sharedInputs.self.nixosModules;
              serviceRegistries = registries;
              serviceModule = sharedInputs.self.nixosModules.services;
            };
            modules = [
              sharedInputs.self.nixosModules.default
              platform
              (machineDir + "/configuration.nix")
              ({ config, ... }: {
                _module.args.herdrPkgs = sources.herdr-pkgs.legacyPackages.${config.nixpkgs.hostPlatform.system};
                _module.args.cuaDriver = sources.cua.packages.${config.nixpkgs.hostPlatform.system}.cua-driver;
                _module.args.cuaGnomeExtension = sources.cua + "/libs/cua-driver/wayland-helper/winrects@cua";
                # In the closure, so garbage collection keeps the locked revision and a rebuild
                # from /etc/nixos finds it in the store rather than on GitHub. nixpkgs keeps its
                # own source the same way, through the flake registry.
                system.extraDependencies = [ sharedInputs.self.outPath ];
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
      lib = {
        inherit mkMachine mkOrganization;
        mkAdapter = { pkgs, name, src }: import ./adapters/package.nix { inherit pkgs src; service = name; };
        checkAuth = import ./checks/auth.nix;
        authLiveTest = import ./checks/auth-live.nix;
        withServices = { pkgs, package, services ? self.ryraServices, index ? self.index // { services = serviceIndex services; } }:
          let adapters = map (svc: svc.package pkgs)
            (builtins.filter (svc: svc ? package) (builtins.attrValues services));
          in pkgs.symlinkJoin {
            name = "ryra-with-catalog";
            paths = [ package ] ++ adapters;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              wrapProgram "$out/bin/ryra" \
                --set RYRA_CATALOG_INDEX ${pkgs.writeText "catalog.json" (builtins.toJSON index)} \
                --prefix PATH : ${pkgs.lib.makeBinPath adapters}
            '';
          };
      };
      nixosModules = {
        services = import ./lib/services-module.nix;
        auth-authelia-lldap = import ./lib/auth-provider.nix;
        backup-restic = import ./lib/backup-providers/restic.nix;
        default = {
          imports = [ disko.nixosModules.disko sops-nix.nixosModules.sops ./modules/default.nix ];
        };
        azure = import ./modules/azure.nix;
        confidential = import ./modules/confidential.nix;
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
      ryraServices = builtins.listToAttrs (map (name: {
        inherit name; value = import (./services + "/${name}");
      }) (directories ./services));
      index = {
        services = serviceIndex self.ryraServices;
        machines = builtins.listToAttrs (map (name: {
          inherit name;
          value = (import (./machines + "/${name}/catalog.nix")) // { directory = "machines/${name}"; };
        }) (directories ./machines));
      };
      templates = builtins.mapAttrs (name: meta: {
        path = ./machines + "/${name}";
        description = meta.summary;
        welcomeText = meta.description;
      }) self.index.machines // nixpkgs.lib.optionalAttrs (self.index.machines ? base) { default = self.templates.base; };
      packages = nixpkgs.lib.genAttrs [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ] (system:
        builtins.mapAttrs (_: svc: svc.package nixpkgs.legacyPackages.${system})
          (nixpkgs.lib.filterAttrs (_: svc: svc ? package) self.ryraServices));
      validate = builtins.concatLists (builtins.attrValues (builtins.mapAttrs (name: svc:
        let missing = field: if (svc.meta or {}) ? ${field} then [] else [ "${name}: missing meta.${field}." ];
        in missing "summary" ++ (if svc ? module then missing "optionRoot" else [])
      ) self.ryraServices));
      checks.x86_64-linux.computer-control = import ./tests/computer-control.nix {
        desktop = (mkMachine { self = ./machines/base; }).nixosConfigurations.machine;
      };
      checks.x86_64-linux.deployment-health = import ./tests/deployment.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        machine = mkMachine { self = ./tests/guided-network/machine; };
      };
    };
}
