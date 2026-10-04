# The `ryra` command itself, on the machine.
#
# So that somebody who has ssh'd in to fix something can put the fix back where it belongs. The
# break-glass edit in `/etc/nixos` is a REPAIR and is replaced by the next push; without this
# there is no way to promote one from the box, and the only route to a permanent change is a
# laptop somebody may not have with them.
#
# It carries NO credential. The binary is inert until a person signs in as themselves, which is
# the same flow and the same scope a laptop uses. Putting the command here does not make this
# machine able to change the organization; it makes the person at it able to, which they already
# were from somewhere else.
#
# From the signed static Linux runtime. Ryra's proprietary source stays private;
# this executable needs no foreign dynamic linker on NixOS.
#
# PINNED, and it has to be bumped when ryra is released: a `fetchurl` needs a hash, so "latest"
# is not expressible here. The same shape as the herdr pin above it, and no longer the slack one:
# `updates.nix` runs this binary, so a version older than the subcommand it calls is a timer that
# fails every night. 0.1.6 was pinned here while `machines update` existed only on main, and the
# unit died with "unrecognized subcommand" at the first run.
#
# This assumes the pool keeps what it has published. If a version is ever removed from
# pkg.ryra.dev, every machine pinned to it stops building.
{ lib, pkgs, ... }:
let
  version = "0.1.39";

  # Published target triples. Keyed by system so one file serves both
  # templates rather than two copies drifting apart.
  published = {
    "x86_64-linux" = {
      arch = "x86_64-unknown-linux-musl";
      sha256 = "e1f7d31e9e8c8e104644ab093f98166d72d8e5c145130d7b7b576976cc4e4096";
    };
    "aarch64-linux" = {
      arch = "aarch64-unknown-linux-musl";
      sha256 = "9bdd7b6264ce206dad3713e49aad037037e717f22940d2b4daa0ebafd4390507";
    };
  };
  package = published.${pkgs.stdenv.hostPlatform.system};

  ryra = pkgs.stdenv.mkDerivation {
    pname = "ryra";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://pkg.ryra.dev/bin/ryra-${version}-${package.arch}.tar.gz";
      inherit (package) sha256;
    };

    # Static Linux runtimes shipped alongside the desktop release.
    sourceRoot = ".";
    installPhase = ''
      install -Dm755 ryra $out/bin/ryra
    '';

    # Shaped the way nixpkgs shapes a closed-source binary, because that is what this would be
    # submitted AS. Slack, zoom and 1password are all in nixpkgs on exactly these terms: a
    # published artefact, `binaryNativeCode`, and an unfree licence. Building from source is not
    # an option nixpkgs has here and repackaging is not a lesser path, it is the path.
    #
    # `sourceProvenance` is the part that is easy to leave out and is not optional: it is how
    # somebody auditing a closure learns that this came down as a binary rather than being
    # compiled, and 1227 packages in nixpkgs declare it.
    meta = {
      description = "Ryra: machines, secrets, deployments and agent workspaces";
      homepage = "https://ryra.dev";
      sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
      license = lib.licenses.unfree;
      platforms = builtins.attrNames published;
      mainProgram = "ryra";
    };
  };
in
{
  environment.systemPackages = [ ryra ];

  # For units that run it. `environment.systemPackages` puts a binary on a
  # person's PATH and NOT on a systemd unit's, so `updates.nix` asking for
  # `ryra` by name would have failed every night with "command not found".
  _module.args.ryraPackage = ryra;
}
