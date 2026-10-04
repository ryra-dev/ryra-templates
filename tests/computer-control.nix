{ desktop }:
let
  off = (desktop.extendModules {
    modules = [ { ryra.desktop.computerControl.enable = lib.mkForce false; } ];
  }).config;
  on = (desktop.extendModules {
    modules = [ { ryra.desktop.computerControl.enable = lib.mkForce true; } ];
  }).config;
  hasDriver = config: builtins.any (p: p.name == "cua-driver") config.environment.systemPackages;
  newServices = lib.filter (name: !(builtins.hasAttr name off.systemd.user.services))
    (builtins.attrNames on.systemd.user.services);
  inherit (desktop) pkgs;
  inherit (pkgs) lib;
in
assert desktop.options.ryra.desktop.computerControl.enable.default == false;
assert !hasDriver off;
assert hasDriver on;
assert on.services.gnome.at-spi2-core.enable;
assert on.systemd.services."ryra-desktop@".environment.NO_AT_BRIDGE == "0";
assert on.networking.firewall.allowedTCPPorts == off.networking.firewall.allowedTCPPorts;
assert lib.all (name: !(lib.hasInfix "cua" name)) newServices;
# Force both complete configurations, including the real upstream package, so
# disabled-only evaluation cannot hide an invalid opt-in configuration.
builtins.deepSeq [ off.system.build.toplevel.drvPath on.system.build.toplevel.drvPath ]
  (pkgs.runCommand "ryra-computer-control-options" { } ''
    touch "$out"
  '')
