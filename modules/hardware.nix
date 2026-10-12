# The disk and the bootloader, for a Hetzner Cloud VM.
#
# # Both boot paths, because guessing wrong is invisible
#
# This machine may be BIOS or UEFI and nothing in the configuration can ask.
# Hetzner Cloud x86 instances have historically booted SeaBIOS; arm64 and newer
# types are UEFI. An earlier version of this file installed a UEFI-only GRUB,
# copied from `hetzner-nixos-uefi` whose name says what it assumed.
#
# The failure that produces is the worst available here: `nixos-anywhere`
# reports `### Done! ###`, the disk is written correctly, the provider says the
# server is running, and the machine never boots. There is nothing to see and no
# error anywhere. Two machines went that way before this comment existed.
#
# On x86 the disk carries a BIOS boot partition AND an ESP, and GRUB uses
# both. ARM uses UEFI only, with no BIOS partition or MBR installation. It costs 1 MB and a few seconds, and it removes a question that can only
# be answered by buying a machine and watching it not come back.
#
# # Root is btrfs, and the reasoning is worth keeping
#
# It was ext4, which was drift rather than a decision: this file was written from
# `hetzner-nixos-uefi`, which is root on ZFS, and the disk layout is the one part
# of a template that evaluating cannot check, so the simplification was never
# caught.
#
# The fix was nearly ZFS, to match that machine. What decided against it is the
# size of box this template actually lands on. ZFS caches in the ARC rather than
# in the page cache, and the ARC wants a real share of memory: capped hard it
# still costs a few hundred megabytes, and left alone it takes HALF of RAM. On a
# 4 GB machine running a browser and an agent session that is the wrong trade,
# and 4 GB machines are the common case here rather than the small one.
#
# btrfs caches in the ordinary page cache, so its memory cost is close to ext4's,
# and it still answers the question ext4 cannot:
#
# `docs/DESIGN-machines.md` calls the armed undo the most load-bearing mechanism
# in the design, and then says what limits it: a generation restores
# CONFIGURATION, not DATA. Roll back a bad deploy on ext4 and you get yesterday's
# configuration pointed at today's state. Somebody who rolls back and finds it did
# not help is worse off than somebody who never trusted it. The pre-switch
# snapshot below is the other half, and it needs a filesystem that can take one.
#
# What is given up against ZFS: a real read cache, multi-disk, send/receive
# parity, dedup. None of those matter on a single-disk cloud VM, and the last two
# were never wanted. What is given up against ext4: copy-on-write fragments, so
# anything doing small random writes wants `chattr +C` on its directory, and a
# full filesystem reports oddly because data and metadata are allocated
# separately. Both are real and both are the price of the paragraph above.
#
# `nix/host.nix` in the ryra repo stays on ZFS deliberately. That box is larger,
# it runs Postgres, and there the ARC earns the memory it takes.
{ config, lib, pkgs, ... }:
let bios = pkgs.stdenv.hostPlatform.isx86_64; in
{
  imports = [{ options.ryra.hardware.biosBoot = lib.mkOption {
    type = lib.types.bool;
    default = bios;
    description = "Include a BIOS boot partition alongside the EFI system partition.";
  }; }];
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    # The firmware does not persist a boot entry, so the loader goes where a
    # machine with no entry looks by default.
    efiInstallAsRemovable = true;
    # And the MBR, for the firmware that never looks at an ESP at all.
    devices = if bios then [ "/dev/sda" ] else [ "nodev" ];
  };

  # virtio, or the installed system cannot see its own disk or network.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_scsi"
    "virtio_net"
    "ahci"
    "sd_mod"
  ];
  services.qemuGuest.enable = true;

  # The network, which a hand-written hardware aspect has to say out loud.
  #
  # NixOS enables DHCP through the `hardware-configuration.nix` that
  # `nixos-generate-config` writes, and a machine installed from a template
  # never runs that. Left out, the install succeeds and the machine comes up
  # with no route to anything.
  networking.useDHCP = lib.mkDefault true;

  # ---------------------------------------------------------------- the disk

  disko.devices.disk.main = {
    device = lib.mkDefault "/dev/sda";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        # 1 MB, no filesystem, type ef02. GRUB puts its core image here when the
        # firmware is BIOS and the table is GPT: without it, a BIOS machine has
        # nowhere to boot from on a GPT disk and fails silently at install time.
        boot = lib.mkIf config.ryra.hardware.biosBoot {
          size = "1M";
          type = "EF02";
          priority = 1;
        };
        # Plain vfat, and it stays that way: GRUB loads the kernel and the initrd
        # from here, so it needs no btrfs support of its own.
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
          };
        };
        root = {
          size = "100%";
          content = {
            type = "btrfs";
            # The disk is fresh from an installer that has just partitioned it,
            # and mkfs refuses a device it thinks already holds a filesystem.
            extraArgs = [ "-f" ];

            # Subvolumes rather than one flat filesystem, and the split is the
            # `local` and `safe` one that `hetzner-nixos-uefi` uses for its ZFS
            # datasets: what is rebuildable, and what somebody would actually
            # miss. It is what makes "what would I lose" a question with an
            # answer rather than a guess, and it is what the snapshot below
            # takes.
            subvolumes = {
              "/@root" = {
                mountpoint = "/";
                mountOptions = [ "compress=zstd" "noatime" ];
              };
              # Rebuildable by definition, and the one place compression pays
              # most: the store is text and ELF.
              "/@nix" = {
                mountpoint = "/nix";
                mountOptions = [ "compress=zstd" "noatime" ];
              };
              # The accounts an organization declares live here, which on a
              # machine people work in means checkouts and whatever has not been
              # pushed yet.
              "/@home" = {
                mountpoint = "/home";
                mountOptions = [ "compress=zstd" "noatime" ];
              };
              # Service state. Its own subvolume so a deploy that breaks a
              # service can be rewound without rewinding the whole machine.
              #
              # Anything here doing small random writes, a database above all,
              # wants `chattr +C` on its own directory: copy-on-write and a
              # write-ahead log are a bad pairing and it fragments. That is the
              # standing cost of choosing btrfs and it belongs next to the
              # subvolume it applies to rather than in a document.
              "/@var-lib" = {
                mountpoint = "/var/lib";
                mountOptions = [ "compress=zstd" "noatime" ];
              };
              # Where the snapshots land. Its own subvolume so that a snapshot
              # of `/home` does not contain the snapshots of `/home`: a nested
              # subvolume appears as an empty directory in its parent's
              # snapshot, which is exactly what is wanted here.
              "/@snapshots" = {
                mountpoint = "/.snapshots";
                mountOptions = [ "compress=zstd" "noatime" ];
              };
            };
          };
        };
      };
    };
  };

  # ---------------------------------------------------------------- before a switch

  # A snapshot of the data, taken before the configuration changes.
  #
  # This is the half of the armed undo that generations cannot do. NixOS keeps
  # the previous generation and that restores CODE: roll back and the binaries
  # are yesterday's while the state is still today's.
  #
  # `preSwitchChecks` rather than an activation script, because a check that
  # FAILS stops the switch. A deploy that could not snapshot should not proceed:
  # the snapshot is the only reason the next ten minutes are recoverable.
  #
  # Absolute paths, and this is not tidiness. Pre-switch checks run under
  # `systemd-run` with a minimal PATH, so a bare `date` is not found, the
  # snapshot fails, and the whole deploy aborts with `date: command not found`.
  # It works during a fresh install only because that runs with a full PATH,
  # which is what makes it a trap: it passes the first time and fails on the
  # first real deploy. `hetzner-nixos-uefi` hit this on ZFS and wrote it down,
  # and nothing about it was specific to ZFS.
  #
  # Read-only snapshots, because these exist to be read back from and nothing
  # should be able to write into one by accident.
  #
  # Two things this is NOT. Not a backup: same filesystem, same disk, and losing
  # the disk loses every snapshot with it. And not free to roll back, because it
  # discards everything written since, including work somebody did in the
  # meantime. It is a decision, not an undo button.
  #
  # resources.nix expires snapshots after 30 days, retaining at least the
  # newest three of each kind. These snapshots still share the live data disk.
  system.preSwitchChecks.btrfsSnapshot = ''
    stamp=$(${pkgs.coreutils}/bin/date --utc '+%y%m%dT%H%M%S')
    ${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot -r /home "/.snapshots/home-$stamp"
    ${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot -r /var/lib "/.snapshots/var-lib-$stamp"
  '';

  # Checksums only tell you about a block somebody read. A scrub is what reads
  # all of them, so this is what turns "btrfs can detect corruption" into "this
  # machine would notice". One disk means it detects and cannot repair, which is
  # still the difference between restoring a backup and serving the wrong bytes
  # for a year.
  #
  # Monthly by default, and it is IO-heavy: drop this line if these machines turn
  # out to be busy at the wrong moment.
  services.btrfs.autoScrub.enable = true;
}
