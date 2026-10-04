{ config, lib, pkgs, ... }:
let
  common = builtins.readFile ./desktop/common.sh;
  panel = pkgs.gnome-panel-with-modules.override { panelModulePackages = [ pkgs.gnome-applets ]; };
  gnomeSession = pkgs.gnome-flashback.mkGnomeSession {
    wmName = "metacity";
    wmLabel = "Metacity";
  };
  helper = pkgs.writeShellApplication {
    name = "ryra-desktop";
    runtimeInputs = with pkgs; [ coreutils systemd curl jq tigervnc gawk xprop ];
    text = ''
      ${common}
      ${builtins.readFile ./desktop/control.sh}
    '';
  };
  session = pkgs.writeShellApplication {
    name = "ryra-desktop-session";
    runtimeInputs = with pkgs; [ coreutils systemd tigervnc gnome-session dbus xauth xdpyinfo xprop openssl python3Packages.websockify ];
    text = ''
      ${common}
      export RYRA_NOVNC=${pkgs.novnc}/share/webapps/novnc
      ${builtins.readFile ./desktop/session.sh}
    '';
  };
in {
  options.ryra.desktop.enable = lib.mkEnableOption "the Ryra virtual desktop";
  config = lib.mkIf config.ryra.desktop.enable {
    environment.systemPackages = with pkgs; [
      helper gnomeSession panel gnome-flashback metacity
      gnome-console nautilus gnome-text-editor firefox adwaita-icon-theme
    ];
    environment.pathsToLink = [ "/share" ];
    fonts.enableDefaultPackages = true;
    services.dbus.enable = true;
    programs.dconf.enable = true;
    security.polkit.enable = true;
    services.gvfs.enable = true;
    services.gnome.gnome-settings-daemon.enable = true;
    services.gnome.at-spi2-core.enable = true;
    systemd.packages = with pkgs; [ gnome-session gnome-flashback metacity panel ];
    security.pam.services.ryra-desktop.startSession = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id === "org.freedesktop.systemd1.manage-units"
            && action.lookup("unit") === "ryra-desktop@" + subject.user + ".service"
            && ["start", "stop", "restart", "reset-failed"].indexOf(action.lookup("verb")) !== -1) {
          return polkit.Result.YES;
        }
      });
    '';

    systemd.services."ryra-desktop@" = {
      description = "Ryra desktop session";
      after = [ "systemd-logind.service" ];
      requires = [ "systemd-logind.service" ];
      environment = {
        XDG_SESSION_TYPE = "x11";
        XDG_SESSION_CLASS = "user";
      };
      serviceConfig = {
        ExecStart = "${session}/bin/ryra-desktop-session";
        User = "%i";
        PAMName = "ryra-desktop";
        WorkingDirectory = "~";
        UMask = "0077";
        KillMode = "mixed";
        TimeoutStopSec = 10;
        NoNewPrivileges = true;
      };
    };
  };
}
