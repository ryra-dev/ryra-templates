# The configuration this machine was built from, at the place NixOS looks for it.
#
# For the moment ryra is not there. The control plane is down, or the laptop that holds the tree
# is in a bag somewhere, and a box needs changing now. Without this the machine carries no answer
# to "what am I": `/etc/nixos` is empty, the flake is in the store under a hashed name nobody can
# guess, and the only copy anybody can read is somewhere else entirely.
#
# So the machine keeps its own source, WRITABLE and at `/etc/nixos`, which means every ordinary
# NixOS command works here with no ryra-shaped knowledge at all:
#
#   $EDITOR /etc/nixos/machines/$(hostname)/modules/machine.nix
#   nixos-rebuild switch
#
# That is the whole reason it is a copy rather than the `environment.etc` symlink into the store
# this replaced. A store path is read-only, so an editor refuses it and the recipe grew a `cp`
# and a `chmod` that a person had to know; and `nixos-rebuild` with no arguments failed with
# `file 'nixos-config' was not found in the Nix search path`, which is the most standard command
# on the system failing in a way that names nothing you did. Whoever is fixing a box at two in
# the morning, person or agent, reaches for exactly that command.
#
# `flake.lock` comes with it, which is what makes a rebuild here reproducible and possible with
# no network: every input is already in this machine's store, because that is what built the
# system running now.
#
# WHAT HAPPENS ON THE NEXT `ryra org machines apply`: the machine is built from the TREE, this
# runs again, and whatever was done here is replaced. That is not a flaw to design around, it is
# what declarative means. A change worth keeping goes into the tree, into git, and gets reviewed
# like any other. A change made here is a repair, and repairs are supposed to be temporary.
#
# It follows that an edit made here and not yet built is lost by any activation, a reboot
# included. The alternative was leaving `/etc/nixos` read-only so nothing could ever be lost from
# it, which spends the whole point above to protect work that belongs in the tree anyway.
#
# Why not put the authoritative flake here instead: because then a fleet has one config per
# machine and one in the tree, and the two drift. That is the failure ryra names in Terraform,
# and every tool that manages more than one NixOS box, colmena and deploy-rs and morph among
# them, pushes from one repository for the same reason.
{ self, pkgs, ... }:
{
  # After `etc`, which owns the rest of `/etc` and would otherwise be writing underneath this.
  #
  # `--delete` because converging is the point: a module removed from the tree has to leave here
  # too, or the machine goes on carrying a file the declaration no longer mentions and the next
  # person to read `/etc/nixos` is reading a lie.
  #
  # `--chmod` because the source is a store path and arrives read-only, which is exactly what
  # stopped an editor before.
  #
  # `--checksum` because rsync's default is size plus mtime, and EVERY file in the store has the
  # same mtime: 1970. So a file that changed without changing length is not copied at all. That
  # is not a corner case, it is the ordinary shape of an edit here: bumping `ryra-cli.nix` from
  # 0.1.3 to 0.1.5 changed a version and two hex digests and left the byte count identical, so
  # the machine ran 0.1.5 while `/etc/nixos` went on saying 0.1.3. A repair promoted from that
  # copy would have reinstalled the version it was written to replace, which is the one failure
  # this whole file exists to prevent.
  system.activationScripts.etcNixos = {
    deps = [ "etc" ];
    text = ''
      mkdir -p /etc/nixos
      ${pkgs.rsync}/bin/rsync -rlt --checksum --delete --chmod=Du=rwx,Fu=rw ${self}/ /etc/nixos/
    '';
  };
}
