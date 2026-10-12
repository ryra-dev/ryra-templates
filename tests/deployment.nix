{ pkgs ? import (builtins.getFlake ("path:" + toString ../.)).inputs.nixpkgs { system = builtins.currentSystem; }
, machine ? (builtins.getFlake ("path:" + toString ../.)).lib.mkMachine { self = ./guided-network/machine; }
}:
let
  systemd = pkgs.writeShellScriptBin "systemctl" ''
    test "$1" = is-active && test "$2" = --quiet || exit 2
    shift 2
    for unit in "$@"; do
      case "$unit" in multi-user.target|healthy.service) exit 0 ;; esac
    done
    exit 3
  '';
  health = requiredUnits: (import ../modules/deployment.nix {
    inherit (pkgs) lib;
    pkgs = pkgs // { inherit systemd; };
    config.ryra.deployment = {
      inherit requiredUnits;
      beforeSwitch = [];
      healthChecks = [];
    };
  }).config.environment.etc."ryra/deploy/health".source;
  hostname = "ryra-d174df45a9244cd5bb8c4c0a53cdf8a1.westeurope.cloudapp.azure.com";
  nginxConfig = phase: pkgs.writeText "ryra-${phase}-azure-hostname.conf" ''
    error_log stderr;
    pid nginx.pid;
    events {}
    http {
      access_log off;
      server_names_hash_bucket_size ${toString machine.nixosConfigurations.${phase}.config.services.nginx.serverNamesHashBucketSize};
      server { listen 127.0.0.1:18080; server_name _; return 404; }
      server { listen 127.0.0.1:18080; server_name ${hostname}; return 204; }
    }
  '';
in pkgs.runCommand "ryra-deployment-health" {} ''
  ${pkgs.nginx}/bin/nginx -t -e stderr -p "$TMPDIR/" -c ${nginxConfig "machine"}
  ${pkgs.nginx}/bin/nginx -t -e stderr -p "$TMPDIR/" -c ${nginxConfig "machine-https-bootstrap"}
  ${health [ "healthy.service" ]}
  if ${health [ "healthy.service" "inactive.service" ]} > failure.log 2>&1; then
    echo "An active service hid an inactive required service" >&2
    exit 1
  fi
  grep -F 'Required service is not active: inactive.service' failure.log
  touch "$out"
''
