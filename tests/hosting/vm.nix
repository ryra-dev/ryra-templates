{ serviceSource ? null, secretsDirectory }:
let
  templates = builtins.getFlake ("path:" + toString ../..);
  services = if serviceSource == null then templates.inputs.ryra-services else builtins.getFlake serviceSource;
  nixpkgs = templates.inputs.nixpkgs;
  certs = import (nixpkgs + "/nixos/tests/common/acme/server/snakeoil-certs.nix");
  machine = templates.lib.mkMachine {
    self = ./machine;
    hostName = "ryra-hosting-check";
    inputs.ryra-services = services;
    modules = [
      (nixpkgs + "/nixos/modules/virtualisation/qemu-vm.nix")
      ({ config, lib, pkgs, ... }: {
        virtualisation = {
          memorySize = 3072;
          cores = 2;
          graphics = false;
          diskSize = 16384;
          useNixStoreImage = true;
          writableStore = true;
          qemu.package = pkgs.qemu_kvm;
          forwardPorts = [ { from = "host"; host.address = "127.0.0.1"; host.port = 22259; guest.port = 22; } ];
          sharedDirectories.keys = { source = secretsDirectory; target = "/run/testkeys"; };
        };
        boot.loader.grub.enable = lib.mkForce false;
        services.btrfs.autoScrub.enable = lib.mkForce false;
        system.preSwitchChecks = lib.mkForce {};
        systemd.services.ryra-snapshot-prune.enable = lib.mkForce false;
        systemd.timers.ryra-snapshot-prune.enable = lib.mkForce false;
        users.users.root.openssh.authorizedKeys.keys = [ (builtins.readFile (secretsDirectory + "/ssh.pub")) ];
        sops = {
          defaultSopsFile = builtins.path { path = secretsDirectory + "/secrets.yaml"; name = "hosting-secrets.yaml"; };
          age.keyFile = "/run/testkeys/age-key.txt";
          age.sshKeyPaths = [];
        };
        networking.hosts."127.0.0.1" = [ "acme.test" "bookmarks.example.test" ];
        security.pki.certificateFiles = [ certs.ca.cert ];
        security.acme.defaults = {
          server = "https://acme.test:14000/dir";
          email = "test@example.test";
        };
        systemd.services.pebble = {
          wantedBy = [ "multi-user.target" ];
          environment = { PEBBLE_VA_NOSLEEP = "1"; PEBBLE_WFE_NONCEREJECT = "0"; };
          serviceConfig.ExecStart = "${pkgs.pebble}/bin/pebble -config ${pkgs.writeText "pebble.json" (builtins.toJSON {
            pebble = {
              listenAddress = "127.0.0.1:14000";
              managementListenAddress = "127.0.0.1:15000";
              certificate = certs."acme.test".cert;
              privateKey = certs."acme.test".key;
              httpPort = 80;
              tlsPort = 443;
              strict = true;
            };
          })}";
        };
        systemd.services.pebble-trust = {
          wantedBy = [ "multi-user.target" ];
          after = [ "pebble.service" ];
          requires = [ "pebble.service" ];
          serviceConfig = { Type = "oneshot"; RemainAfterExit = true; StateDirectory = "pebble-trust"; };
          script = ''
            ${pkgs.curl}/bin/curl --fail --silent --show-error --retry 20 --retry-all-errors --retry-delay 1 \
              --cacert ${certs.ca.cert} https://acme.test:15000/roots/0 > /var/lib/pebble-trust/root.pem
            cat ${config.security.pki.caBundle} /var/lib/pebble-trust/root.pem > /var/lib/pebble-trust/bundle.pem
          '';
        };
        environment.etc."ssl/certs/ca-certificates.crt".source = lib.mkForce "/var/lib/pebble-trust/bundle.pem";
        systemd.services.nginx.after = [ "pebble-trust.service" ];
        environment.systemPackages = [ pkgs.curl pkgs.openssl pkgs.jq ];

        specialisation.public.configuration = {
          ryra.services.web.linkding = { access = "public"; domain = "bookmarks.example.test"; };
          security.acme.certs."bookmarks.example.test" = {
            validMinDays = 3650;
            extraLegoRenewFlags = [ "--ari-disable" ];
          };
          systemd.services."acme-order-renew-bookmarks.example.test" = {
            after = [ "pebble-trust.service" ];
            requires = [ "pebble-trust.service" ];
          };
        };
      })
    ];
  };
in machine.nixosConfigurations.ryra-hosting-check.config.system.build.vm
