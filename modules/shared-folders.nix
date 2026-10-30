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
  # A process keeps the groups it started with, and a lingering login, its herdr session and every
  # pane in it run for weeks, so a member is named in the ACL of the space and of everything in it
  # as well as grouped: joining never needs anybody's session restarted. Done when membership
  # changes rather than on every activation, from what was granted before, kept by uid so an
  # account deleted since can still be taken out. The walk is tmpfiles' A+, which does not follow
  # a link a member could swap in, rather than a recursive setfacl as root, which does.
  access = pkgs.writeShellScript "ryra-shared-folders-access" ''
    set -u
    PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.acl config.systemd.package ]}
    state=/var/lib/ryra-shared-folders/named
    mkdir -p "$state"
    rules=$(mktemp)
    trap 'rm -f "$rules"' EXIT
    current=""
    grant() {
      path=$1; shift
      file="$state/$(printf %s "$path" | tr / :)"
      current="$current $file"
      [ -d "$path" ] || return 0
      had=$(cat "$file" 2>/dev/null || true)
      want=""; spec=""
      for member in "$@"; do
        uid=$(id -u -- "$member" 2>/dev/null) || continue
        want="$want $uid"
        case " $had " in *" $uid "*) ;; *) spec="$spec,u:$member:rwX,d:u:$member:rwx" ;; esac
      done
      if [ -n "$spec" ]; then printf 'A+ %s - - - - %s\n' "$path" "''${spec#,}" >> "$rules"; fi
      for uid in $had; do
        case " $want " in *" $uid "*) ;; *) take "$path" "$uid" ;; esac
      done
      echo $want > "$file.next"
    }
    # Only the space itself: whoever cannot pass it reaches nothing inside it.
    take() {
      setfacl -x "u:$2" "$1" 2>/dev/null || true
      setfacl -d -x "u:$2" "$1" 2>/dev/null || true
    }
    ${lib.concatMapStrings (name: "grant ${lib.escapeShellArg (path name)} ${lib.escapeShellArgs folders.${name}.members}\n") names}
    for file in "$state"/*; do
      case "$file" in *.next) continue ;; esac
      [ -f "$file" ] || continue
      case " $current " in *" $file "*) continue ;; esac
      for uid in $(cat "$file"); do take "$(basename "$file" | tr : /)" "$uid"; done
      rm -f "$file"
    done
    systemd-tmpfiles --create "$rules" || exit 1
    for file in $current; do
      if [ -f "$file.next" ]; then mv "$file.next" "$file"; fi
    done
  '';
  # An account's shortcuts as "LABEL=PATH", the ones the activation script leaves alone.
  shortcuts = account: map (name: "${folders.${name}.label}=${path name}")
    (builtins.filter (name: builtins.elem account folders.${name}.members) names);
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

  config = lib.mkMerge [
  (lib.mkIf (folders != {}) {
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

    environment.systemPackages = [ pkgs.acl ];
    systemd.tmpfiles.rules = lib.optionals (underSrv != [ ]) [
      # Traversable, but listing other teams' space names is unnecessary.
      "d /srv/shared 0711 root root - -"
    ] ++ lib.concatMap (name: [
      "d ${quote (path name)} 2770 root ${group name} - -"
      # Added to rather than replaced, so the members the access service names stay named.
      "a+ ${quote (path name)} - - - - m::rwx,d:u::rwx,d:g::rwx,d:m::rwx,d:o::---"
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
  })
  {
    # Restarted when membership changes, since the script names it, and after tmpfiles has made
    # the spaces. It holds no socket, so a deploy does not count restarting it as an interruption.
    systemd.services.ryra-shared-folders = {
      description = "Name shared folder members in what is already there";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" "systemd-tmpfiles-resetup.service" ];
      unitConfig.RequiresMountsFor = mounts;
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = access; };
    };

    # Outside the condition above, so removing the last space still tidies up after it.
    system.activationScripts.ryraSharedFolders = lib.stringAfter [ "users" "groups" ] (''
      # With mutable users, NixOS keeps group members it did not declare as users, so an account
      # made by hand would stay in a space after being removed from it. These groups belong to
      # this module, so whoever is not listed is taken out. `gpasswd -d`, because `-M` refuses a
      # name with no account yet, and listing one before it is made is allowed.
    '' + lib.concatMapStrings (name: ''
      for member in $(getent group ${group name} | cut -d: -f4 | tr , ' '); do
        case " ${lib.concatStringsSep " " folders.${name}.members} " in
          *" $member "*) ;;
          *) gpasswd -d "$member" ${group name} ;;
        esac
      done
    '') names + ''
      # What a rename, move or removal leaves behind. A former location is removed only when it
      # is empty: one still holding files stays where it is, with its shortcuts.
      state=/var/lib/ryra-shared-folders/paths
      current=${lib.escapeShellArg (lib.concatStringsSep " " paths)}
      if [ -f "$state" ] || [ -n "$current" ]; then
        known="$current"
        former=""
        for old in $(cat "$state" 2>/dev/null); do
          case " $current " in *" $old "*) continue ;; esac
          known="$known $old"
          rmdir -- "$old" 2>/dev/null || true
          if [ -e "$old" ]; then former="$former $old"; fi
        done
        mkdir -p /var/lib/ryra-shared-folders
        printf '%s\n' $current $former > "$state"
        if [ -z "$current$former" ]; then rm -f "$state"; fi
        # A shortcut under an old label, to a space the account was taken out of, or to a former
        # location that is gone. Removed as the account itself, so a home it controls cannot turn
        # this into root deleting something else.
        tidy() {
          user=$1; dir=$2/Shared; shift 2
          { [ -d "$dir" ] && [ ! -L "$dir" ]; } || return 0
          for link in "$dir"/*; do
            [ -L "$link" ] || continue
            target=$(readlink -- "$link")
            case " $current " in
              *" $target "*)
                keep=no
                for wanted in "$@"; do
                  if [ "$wanted" = "''${link##*/}=$target" ]; then keep=yes; fi
                done ;;
              *)
                case " $known " in
                  *" $target "*) if [ -e "$target" ]; then keep=yes; else keep=no; fi ;;
                  *) keep=yes ;;
                esac ;;
            esac
            if [ "$keep" = no ]; then runuser -u "$user" -- rm -f -- "$link"; fi
          done
        }
    '' + lib.concatMapStrings (name: ''
        tidy ${lib.escapeShellArg name} ${lib.escapeShellArg (user name).home} ${lib.escapeShellArgs (shortcuts name)}
    '') (builtins.filter homed (builtins.attrNames config.users.users)) + ''
      fi
    '');
  }
  ];
}
