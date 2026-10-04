{ config, lib, pkgs, cuaDriver, ... }:
let
  cfg = config.ryra.desktop.computerControl;
  driver = pkgs.writeShellApplication {
    name = "cua-driver";
    runtimeInputs = with pkgs; [ coreutils systemd xdpyinfo imagemagick ];
    text = ''
      export RYRA_CUA_DRIVER=${lib.getExe cfg.package}
      ${builtins.readFile ./desktop/computer-control.sh}
    '';
  };
in {
  options.ryra.desktop.computerControl = {
    enable = lib.mkEnableOption "local agent control of the Ryra virtual desktop";
    package = lib.mkOption {
      type = lib.types.package;
      default = cuaDriver;
      description = "Cua Driver package wrapped to use the current user's Ryra desktop.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = config.ryra.desktop.enable;
      message = "Computer control requires ryra.desktop.enable.";
    }];
    environment.systemPackages = [ driver ];
    services.gnome.at-spi2-core.enable = true;
    # A long-lived user manager may still carry the accessibility-disabled
    # environment from before this option was enabled.
    systemd.services."ryra-desktop@".environment = {
      NO_AT_BRIDGE = "0";
      GTK_A11Y = "atspi";
    };
    # No Cua daemon, listener, or automatic desktop startup. Ryra starts the
    # local stdio process only after the account opts in to computer control.
  };
}
