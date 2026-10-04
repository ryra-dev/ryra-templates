# Shared documents belong to a space; homes and agent credentials remain personal.
{ config, lib, pkgs, ... }:
let
  folders = config.ryra.sharedFolders;
  names = builtins.attrNames folders;
  members = lib.unique (lib.concatMap (name: folders.${name}.members) names);
  group = name: "ryra-shared-${name}";
  path = name: "/srv/shared/${name}";
  user = name: config.users.users.${name};
  # tmpfiles has its own quoting and specifiers, independent of shell quoting.
  quote = value: "\"${lib.replaceStrings [ "%" ] [ "%%" ] (lib.strings.escapeC [ "\\" "\"" "\n" "\r" "\t" ] value)}\"";
  validMembers = builtins.filter (name:
    builtins.hasAttr name config.users.users
    && (user name).isNormalUser
    && (user name).createHome
    && (user name).home != "/var/empty"
  ) members;
  homes = map (name: (user name).home) validMembers;
  mounts = map quote ([ "/srv/shared" ] ++ map path names ++ homes);
in
{
  options.ryra.sharedFolders = lib.mkOption {
    default = {};
    description = ''
      Named shared spaces under /srv/shared. Each space has a separate Unix
      group, and members get a shortcut under ~/Shared. Members must already
      have individual local accounts, for example through Ryra's login module.
      This does not grant machine login, sudo, session or credential access.
    '';
    example = lib.literalExpression ''
      {
        company = { label = "Company"; members = [ "alice" "bob" ]; };
        research = { label = "Research"; members = [ "alice" ]; };
      }
    '';
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = {
        label = lib.mkOption {
          type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9 _-]*";
          default = name;
          description = "Shortcut name inside each member's Shared directory. The attribute name determines the storage path.";
        };
        members = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Existing personal Linux accounts allowed to read and edit this space.";
        };
      };
    }));
  };

  config = lib.mkIf (folders != {}) {
    assertions = [
      {
        assertion = lib.all (name: builtins.match "[a-z][a-z0-9-]{0,19}" name != null) names;
        message = "ryra.sharedFolders names must start with a lowercase letter and contain at most 20 lowercase letters, digits or hyphens.";
      }
      {
        assertion = builtins.length (lib.unique (map (name: folders.${name}.label) names)) == builtins.length names;
        message = "ryra.sharedFolders labels must be unique so home shortcuts cannot collide.";
      }
      {
        assertion = builtins.length validMembers == builtins.length members;
        message = "ryra.sharedFolders members must be existing normal users with home directories; shared/system/root accounts are not created by this option.";
      }
    ];

    users.groups = lib.genAttrs (map group names) (groupName: {
      members = folders.${lib.removePrefix "ryra-shared-" groupName}.members;
    });

    environment.systemPackages = [ pkgs.acl ];
    systemd.tmpfiles.rules = [
      # Traversable, but listing other teams' space names is unnecessary.
      "d /srv/shared 0711 root root - -"
    ] ++ lib.concatMap (name: [
      "d ${quote (path name)} 2770 root ${group name} - -"
      # Own the root directory's ACL; do not recursively change existing files.
      "a ${quote (path name)} - - - - d:u::rwx,d:g::rwx,d:m::rwx,d:o::---"
    ]) names ++ map (name:
      "d ${quote "${(user name).home}/Shared"} 0700 ${quote name} ${quote (user name).group} - -"
    ) validMembers ++ lib.concatMap (name:
      map (member:
        # L, not L+: preserve an existing file, directory or different symlink.
        # The final argument is not a quoted field in tmpfiles syntax. The
        # storage identifier admits no whitespace, escapes or specifiers.
        "L ${quote "${(user member).home}/Shared/${folders.${name}.label}"} - ${quote member} ${quote (user member).group} - ${path name}"
      ) (builtins.filter (member: builtins.elem member validMembers) (lib.unique folders.${name}.members))
    ) names;

    # Apply only after the actual storage and homes are mounted, on both boot
    # and nixos-rebuild switch. No new filesystem or disk layout is introduced.
    systemd.services.systemd-tmpfiles-setup.unitConfig.RequiresMountsFor = mounts;
    systemd.services.systemd-tmpfiles-resetup.unitConfig.RequiresMountsFor = mounts;
  };
}
