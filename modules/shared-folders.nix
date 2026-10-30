# Shared documents belong to a space; homes and agent credentials remain personal.
{ config, lib, pkgs, ... }:
let
  folders = config.ryra.sharedFolders;
  names = builtins.attrNames folders;
  members = lib.unique (lib.concatMap (name: folders.${name}.members) names);
  group = name: "ryra-shared-${name}";
  path = name: folders.${name}.path;
  paths = map path names;
  user = name: config.users.users.${name};
  # tmpfiles has its own quoting and specifiers, independent of shell quoting.
  quote = value: "\"${lib.replaceStrings [ "%" ] [ "%%" ] (lib.strings.escapeC [ "\\" "\"" "\n" "\r" "\t" ] value)}\"";
  # Only accounts this configuration declares with a real home get a shortcut. Accounts made by
  # hand, or service accounts, get the group alone and reach the space by its path.
  homed = name:
    builtins.hasAttr name config.users.users
    && (user name).isNormalUser
    && (user name).createHome
    && (user name).home != "/var/empty";
  withHomes = builtins.filter homed members;
  homes = map (name: (user name).home) withHomes;
  underSrv = builtins.filter (lib.hasPrefix "/srv/shared/") paths;
  mounts = map quote (lib.optional (underSrv != [ ]) "/srv/shared" ++ paths ++ homes);
  system = [ "bin" "boot" "dev" "etc" "home" "lib" "lib64" "nix" "proc" "root" "run" "sbin" "sys" "tmp" "usr" "var" ];
  inside = outer: inner: outer == inner || lib.hasPrefix "${outer}/" inner;
in
{
  options.ryra.sharedFolders = lib.mkOption {
    default = {};
    description = ''
      Named shared spaces, under /srv/shared unless a space says where. Each
      space has a separate Unix group, and members with a declared home get a
      shortcut under ~/Shared. This does not create accounts or grant machine
      login, sudo, session or credential access.
    '';
    example = lib.literalExpression ''
      {
        company = { label = "Company"; members = [ "alice" "bob" ]; };
        research = { label = "Research"; members = [ "alice" ]; path = "/data/research"; };
      }
    '';
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = {
        label = lib.mkOption {
          type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9 _-]*";
          default = name;
          description = "Shortcut name inside each member's Shared directory.";
        };
        path = lib.mkOption {
          type = lib.types.strMatching "(/[A-Za-z0-9_][A-Za-z0-9._-]*){2,}";
          default = "/srv/shared/${name}";
          description = "Where the space is stored. Missing parent directories are created; the space itself becomes root-owned, setgid and accessible to its group.";
        };
        members = lib.mkOption {
          # No spaces or glob characters, so a name is safe in the activation script below.
          type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9_][A-Za-z0-9._-]{0,31}");
          default = [];
          description = "Linux accounts allowed to read and edit this space: personal logins, shared logins or accounts made by hand on the machine.";
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
        assertion = !(builtins.elem "root" members);
        message = "ryra.sharedFolders members cannot include root, which reaches every space already.";
      }
      {
        assertion = lib.all (p: !(builtins.elem (builtins.head (lib.splitString "/" (lib.removePrefix "/" p))) system)) paths;
        message = "ryra.sharedFolders paths cannot be inside the system's own directories or people's homes; use somewhere like /srv or a data volume.";
      }
      {
        assertion = lib.all (a: lib.all (b: a == b || !(inside (path a) (path b))) names) names;
        message = "ryra.sharedFolders paths must be distinct and not inside one another.";
      }
    ];

    users.groups = lib.genAttrs (map group names) (groupName: {
      members = folders.${lib.removePrefix "ryra-shared-" groupName}.members;
    });

    # With mutable users, NixOS keeps group members it did not declare as users, so an account
    # made by hand would stay in a space after being removed from it. These groups belong to this
    # module, so whoever is not listed is taken out. `gpasswd -d`, because `-M` refuses a name
    # with no account yet, and listing one before it is made is allowed.
    system.activationScripts.ryraSharedFolders = lib.stringAfter [ "users" "groups" ] (lib.concatMapStrings (name: ''
      for member in $(${pkgs.getent}/bin/getent group ${group name} | ${pkgs.coreutils}/bin/cut -d: -f4 | ${pkgs.coreutils}/bin/tr , ' '); do
        case " ${lib.concatStringsSep " " folders.${name}.members} " in
          *" $member "*) ;;
          *) ${pkgs.shadow}/bin/gpasswd -d "$member" ${group name} ;;
        esac
      done
    '') names);

    environment.systemPackages = [ pkgs.acl ];
    systemd.tmpfiles.rules = lib.optionals (underSrv != [ ]) [
      # Traversable, but listing other teams' space names is unnecessary.
      "d /srv/shared 0711 root root - -"
    ] ++ lib.concatMap (name: [
      "d ${quote (path name)} 2770 root ${group name} - -"
      # Own the root directory's ACL; do not recursively change existing files.
      "a ${quote (path name)} - - - - d:u::rwx,d:g::rwx,d:m::rwx,d:o::---"
    ]) names ++ map (name:
      "d ${quote "${(user name).home}/Shared"} 0700 ${quote name} ${quote (user name).group} - -"
    ) withHomes ++ lib.concatMap (name:
      map (member:
        # L, not L+: preserve an existing file, directory or different symlink.
        # The final argument is not a quoted field in tmpfiles syntax. The
        # path option admits no whitespace, escapes or specifiers.
        "L ${quote "${(user member).home}/Shared/${folders.${name}.label}"} - ${quote member} ${quote (user member).group} - ${path name}"
      ) (builtins.filter (member: builtins.elem member withHomes) (lib.unique folders.${name}.members))
    ) names;

    # Apply only after the actual storage and homes are mounted, on both boot
    # and nixos-rebuild switch. No new filesystem or disk layout is introduced.
    systemd.services.systemd-tmpfiles-setup.unitConfig.RequiresMountsFor = mounts;
    systemd.services.systemd-tmpfiles-resetup.unitConfig.RequiresMountsFor = mounts;
  };
}
