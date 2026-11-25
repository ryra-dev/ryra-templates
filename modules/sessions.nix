# A Ryra client starts an account's terminals with `hc connect` over ssh, and `hc` runs the core
# that holds them as a unit of that account's systemd user manager. logind stops that manager,
# and every terminal and agent with it, ten seconds after the account's last login ends unless
# the account lingers. `hc` turns lingering on for itself where polkit allows it, and this
# template runs no polkit, so it is declared here.
{ lib, ... }:
{
  options.users.users = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({ config, ... }: {
      config.linger = lib.mkIf config.isNormalUser (lib.mkDefault true);
    }));
  };
}
