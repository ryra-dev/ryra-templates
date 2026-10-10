{ pkgs ? import (builtins.getFlake ("path:" + toString ../.)).inputs.nixpkgs { system = builtins.currentSystem; } }:
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
in pkgs.runCommand "ryra-deployment-health" {} ''
  ${health [ "healthy.service" ]}
  if ${health [ "healthy.service" "inactive.service" ]} > failure.log 2>&1; then
    echo "An active service hid an inactive required service" >&2
    exit 1
  fi
  grep -F 'Required service is not active: inactive.service' failure.log
  touch "$out"
''
