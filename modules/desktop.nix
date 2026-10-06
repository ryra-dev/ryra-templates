{ config, lib, pkgs, ... }:
let
  common = builtins.readFile ./desktop/common.sh;
  helper = pkgs.writeShellApplication {
    name = "ryra-desktop";
    runtimeInputs = with pkgs; [ coreutils systemd curl jq tigervnc gawk ];
    text = ''
      ${common}
      ${builtins.readFile ./desktop/control.sh}
    '';
  };
  session = pkgs.writeShellApplication {
    name = "ryra-desktop-session";
    runtimeInputs = with pkgs; [ coreutils systemd gnome-session gnome-remote-desktop dbus openssl python3Packages.websockify ];
    text = ''
      ${common}
      export RYRA_NOVNC=${pkgs.novnc}/share/webapps/novnc
      export RYRA_GNOME_REMOTE_DESKTOP=${pkgs.gnome-remote-desktop}/libexec/gnome-remote-desktop-daemon
      ${builtins.readFile ./desktop/session.sh}
    '';
  };
in {
  options.ryra.desktop.enable = lib.mkEnableOption "the Ryra virtual desktop";
  config = lib.mkIf config.ryra.desktop.enable {
    environment.systemPackages = with pkgs; [
      helper firefox gnome-console gnome-control-center
    ];
    nixpkgs.overlays = [(final: prev: {
      gnome-remote-desktop = prev.gnome-remote-desktop.overrideAttrs (old: {
        buildInputs = old.buildInputs ++ [ final.libvncserver ];
        mesonFlags = old.mesonFlags ++ [ "-Dvnc=true" ];
        # GNOME's VNC listener is otherwise public TCP. The patch also fixes
        # cleanup of absent GPU resources closing descriptor 0 on headless hosts.
        patches = (old.patches or []) ++ [ ./desktop/gnome-remote-desktop.patch ];
      });
    })];
    services.desktopManager.gnome = {
      enable = true;
      extraGSettingsOverridePackages = [ pkgs.gnome-remote-desktop ];
      extraGSettingsOverrides = ''
        [org.gnome.shell]
        favorite-apps=['firefox.desktop', 'org.gnome.Console.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Settings.desktop']
        [org.gnome.desktop.remote-desktop.vnc.headless]
        enable=true
        [org.gnome.desktop.background]
        picture-uri='file://${pkgs.gnome-backgrounds}/share/backgrounds/gnome/adwaita-l.jxl'
        picture-uri-dark='file://${pkgs.gnome-backgrounds}/share/backgrounds/gnome/adwaita-d.jxl'
        [org.gnome.desktop.lockdown]
        disable-lock-screen=true
        [org.gnome.desktop.session]
        idle-delay=uint32 0
      '';
    };
    # Enabling a desktop must not change the server's network configuration.
    networking.networkmanager.enable = lib.mkOverride 900 false;
    services.avahi.enable = lib.mkOverride 900 false;
    services.gnome.gnome-user-share.enable = lib.mkOverride 900 false;
    services.gnome.rygel.enable = lib.mkOverride 900 false;
    services.gnome.gnome-initial-setup.enable = false;
    hardware.graphics.enable = true;
    fonts.enableDefaultPackages = true;
    systemd.user.services."org.gnome.Shell@" = {
      overrideStrategy = "asDropin";
      # Inherit the login PATH. NixOS's generated service PATH hides desktop apps.
      path = lib.mkForce [];
      serviceConfig.ExecStart = [ "" "${pkgs.gnome-shell}/bin/gnome-shell --headless --wayland-display=wayland-ryra --mode=%i" ];
    };
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
        XDG_SESSION_TYPE = "wayland";
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
