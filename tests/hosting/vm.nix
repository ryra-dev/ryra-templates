{ serviceSource ? null, secretsDirectory, managedAuth ? false, cronOrdering ? false }:
let
  templates = builtins.getFlake ("path:" + toString ../..);
  services = if serviceSource == null then templates.inputs.ryra-services else builtins.getFlake serviceSource;
  nixpkgs = templates.inputs.nixpkgs;
  certs = import (nixpkgs + "/nixos/tests/common/acme/server/snakeoil-certs.nix");
  machine = templates.lib.mkMachine {
    self = if managedAuth then ./managed else ./machine;
    hostName = "ryra-hosting-check";
    inputs.ryra-services = services;
    modules = [
      ({ lib, ... }: {
        systemd.services = lib.genAttrs [ "grafana" "authelia-main" "linkding" "linkding-setup" "linkding-background-tasks" "nextcloud-oidc" "phpfpm-nextcloud" ] (_: lib.mkIf managedAuth {
          after = [ "pebble-trust.service" ];
          requires = [ "pebble-trust.service" ];
          environment = {
            SSL_CERT_FILE = "/var/lib/pebble-trust/bundle.pem";
            REQUESTS_CA_BUNDLE = "/var/lib/pebble-trust/bundle.pem";
          };
        });
      })
      (nixpkgs + "/nixos/modules/virtualisation/qemu-vm.nix")
      ({ config, lib, pkgs, ... }: {
        system.stateVersion = lib.mkForce "26.05";
        systemd.services.nextcloud-setup = lib.mkIf cronOrdering {
          wantedBy = lib.mkForce [];
          preStart = "${pkgs.coreutils}/bin/sleep 5";
        };
        sops.secrets.nextcloud-adminpass.restartUnits = lib.mkIf cronOrdering (lib.mkForce []);
        systemd.timers.nextcloud-cron.timerConfig.OnBootSec = lib.mkIf cronOrdering (lib.mkForce "0");
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
        services.restic.backups.nextcloud = {
          repository = lib.mkForce "/srv/backups/nextcloud";
          environmentFile = lib.mkForce null;
        };
        services.restic.backups.grafana.repository = lib.mkForce "/srv/backups/grafana";
        systemd.tmpfiles.rules = [ "d /srv/backups/nextcloud 0750 nextcloud root - -" ];
        ryra.services.backup.requests.linkding.beforeRestore = lib.mkAfter [ ''
          if [[ -p /run/ryra-backup-overlap/restore-ready ]]; then
            printf 'ready\n' > /run/ryra-backup-overlap/restore-ready
            IFS= read -r _ < /run/ryra-backup-overlap/restore-release
          fi
        '' ];
        systemd.services.restic-backups-linkding = {
          preStart = lib.mkBefore ''
            if [[ -p /run/ryra-backup-overlap/backup-ready ]]; then
              printf 'ready\n' > /run/ryra-backup-overlap/backup-ready
              IFS= read -r _ < /run/ryra-backup-overlap/backup-release
            fi
          '';
          postStop = lib.mkAfter ''
            if [[ -d /run/ryra-backup-overlap ]]; then
              printf '%s\n' "''${SERVICE_RESULT:-missing}" > /run/ryra-backup-overlap/service-result
            fi
          '';
        };
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
            ${lib.optionalString managedAuth ''
              # Pebble loses ACME account registrations when its process restarts.
              if [[ -d /var/lib/acme/.lego/accounts ]]; then
                ${pkgs.findutils}/bin/find /var/lib/acme/.lego/accounts -type f -delete
              fi
            ''}
            ${pkgs.curl}/bin/curl --fail --silent --show-error --retry 20 --retry-all-errors --retry-delay 1 \
              --cacert ${certs.ca.cert} https://acme.test:15000/roots/0 > /var/lib/pebble-trust/root.pem
            cat ${config.security.pki.caBundle} /var/lib/pebble-trust/root.pem > /var/lib/pebble-trust/bundle.pem
          '';
        };
        environment.etc."ssl/certs/ca-certificates.crt".source = lib.mkForce "/var/lib/pebble-trust/bundle.pem";
        services.nextcloud.phpOptions = lib.mkIf managedAuth {
          "openssl.cafile" = lib.mkForce "/var/lib/pebble-trust/bundle.pem";
          "curl.cainfo" = "/var/lib/pebble-trust/bundle.pem";
        };
        services.authelia.instances.main.settings.log.level = lib.mkIf managedAuth (lib.mkForce "info");
        systemd.services.nginx.after = [ "pebble-trust.service" ];
        environment.systemPackages = [ pkgs.curl pkgs.openssl pkgs.jq pkgs.socat pkgs.openldap pkgs.sqlite ];
        environment.etc."ryra/test/auth-smoke.sh".source = services + "/scripts/auth-smoke.sh";
        environment.etc."ryra/test/grafana-restore-smoke.sh".source = services + "/services/grafana/restore-smoke.sh";
        environment.etc."ryra/test/datasource-canary.sh".source = services + "/services/grafana/datasource-canary.sh";

        security.acme.certs = lib.mkIf managedAuth {
          "apps.example.test" = {
            validMinDays = 3650;
            extraLegoRenewFlags = [ "--ari-disable" ];
          };
        };
        systemd.services."acme-order-renew-apps.example.test" = lib.mkIf managedAuth {
          after = [ "pebble-trust.service" ];
          requires = [ "pebble-trust.service" ];
        };

        specialisation.ownAuth = lib.mkIf managedAuth { configuration = {
          ryra.services.auth.modes = {
            nextcloud = lib.mkForce "none";
            grafana = lib.mkForce "none";
          };
          ryra.services.auth.requests = lib.mkForce {
            inherit (config.ryra.services.auth.requests) linkding;
          };
        }; };

        specialisation.privateHttps = lib.mkIf (!managedAuth) { configuration = {
          ryra.services.web = {
            nextcloud = { privateHttps = true; externalUrl = "https://apps.example.test:8443"; };
            grafana = { privateHttps = true; externalUrl = "https://apps.example.test:8444"; };
          };
          security.acme.certs."apps.example.test" = {
            validMinDays = 3650;
            extraLegoRenewFlags = [ "--ari-disable" ];
          };
          systemd.services."acme-order-renew-apps.example.test" = {
            after = [ "pebble-trust.service" ];
            requires = [ "pebble-trust.service" ];
          };
        }; };

        specialisation.public = lib.mkIf (!managedAuth) { configuration = {
          ryra.services.web.linkding = { access = "public"; domain = "bookmarks.example.test"; };
          security.acme.certs."bookmarks.example.test" = {
            validMinDays = 3650;
            extraLegoRenewFlags = [ "--ari-disable" ];
          };
          systemd.services."acme-order-renew-bookmarks.example.test" = {
            after = [ "pebble-trust.service" ];
            requires = [ "pebble-trust.service" ];
          };
        }; };
      })
    ];
  };
in machine.nixosConfigurations.ryra-hosting-check.config.system.build.vm
