# Evaluate with: nix eval --impure --json --file tests/access.nix
let
  root = toString ../.;
  names = [ "base" "base-arm" "azure" ];
  machines = import ./machines.nix;
  results = builtins.listToAttrs (map (name:
    let
      flake = builtins.getFlake ("path:" + root);
      base = machines.${name};
      withKey = {
        ryra.tailscale.enable = true;
        sops.secrets.tailscale-auth.sopsFile = builtins.toFile "test-secrets.yaml" "{}";
      };
      configuration = modules: (base.extendModules { inherit modules; }).config;
      summarize = c: {
        failures = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
        publicPorts = c.networking.firewall.allowedTCPPorts;
        udpPorts = c.networking.firewall.allowedUDPPorts;
        trusted = c.networking.firewall.trustedInterfaces;
        sshOpenFirewall = c.services.openssh.openFirewall;
        tailscale = c.services.tailscale.enable;
        authKeyFile = c.services.tailscale.authKeyFile;
        upFlags = c.services.tailscale.extraUpFlags;
        setFlags = c.services.tailscale.extraSetFlags;
        sopsSystemd = c.sops.useSystemdActivation;
        secretsUnitExists = builtins.hasAttr "sops-install-secrets.service" c.systemd.units;
        mode = c.environment.etc."ryra/access-mode".text;
        privatePorts = c.networking.firewall.interfaces.tailscale0.allowedTCPPorts or [];
        units = if c.ryra.tailscale.enable && builtins.hasAttr "tailscale-auth" c.sops.secrets then {
          enrollment = c.systemd.units."tailscaled-autoconnect.service".text;
          daemon = c.systemd.units."tailscaled.service".text;
          slice = c.systemd.units."system.slice".text;
        } else {};
      };
    in {
      inherit name;
      value = builtins.mapAttrs (_: modules: summarize (configuration modules)) {
        public = [];
        private = [ withKey ];
        bootstrap = [ withKey { ryra.access.publicSSH = true; } ];
        activationSecrets = [ withKey { sops.useSystemdActivation = false; } ];
        systemdSecrets = [ withKey { sops.useSystemdActivation = true; } ];
        missingKey = [ { ryra.tailscale.enable = true; } ];
        noAccess = [ { ryra.access.publicSSH = false; } ];
        leakedPort = [ withKey { networking.firewall.allowedTCPPorts = [ 22 ]; } ];
        leakedRange = [ withKey { networking.firewall.allowedTCPPortRanges = [{ from = 20; to = 30; }]; } ];
        leakedInterface = [ withKey { networking.firewall.interfaces.eth0.allowedTCPPorts = [ 22 ]; } ];
        trustedInterface = [ withKey { networking.firewall.trustedInterfaces = [ "eth0" ]; } ];
      };
    }
  ) names);
in results
