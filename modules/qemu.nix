{ config, lib, modulesPath, ... }:
let
  hostPkgs = config.virtualisation.host.pkgs;
  registration = hostPkgs.closureInfo {
    rootPaths = config.virtualisation.additionalPaths;
  };
  closure = hostPkgs.closureInfo {
    rootPaths = [ config.system.build.toplevel registration ];
  };
  # qemu-vm's built-in store image is recreated at every start.
  storeImage = hostPkgs.runCommand "ryra-qemu-store.img" {
    preferLocalBuild = true;
  } (import (modulesPath + "/../lib/erofs-store-image.nix") {
    inherit hostPkgs;
    storePaths = "${closure}/store-paths";
    label = "nix-store";
    destination = ''"$out"'';
  });
in {
  disabledModules = [ ./hardware.nix ];
  imports = [ (modulesPath + "/virtualisation/qemu-vm.nix") ];

  virtualisation = {
    memorySize = lib.mkDefault 4096;
    cores = lib.mkDefault 2;
    diskSize = lib.mkDefault 32768;
    graphics = lib.mkDefault false;
    qemu.forceAccel = true;
    useNixStoreImage = false;
    mountHostNixStore = false;
    writableStore = true;
    writableStoreUseTmpfs = false;
    # qemu-vm otherwise exports host directories through SHARED_DIR and TMPDIR.
    sharedDirectories = lib.mkForce {};
    useHostCerts = false;
    qemu.drives = [{
      name = "nix-store";
      file = "${storeImage}";
      driveExtraOpts = { format = "raw"; readonly = "on"; };
      deviceExtraOpts.bootindex = "2";
    }];
    fileSystems = {
      "/nix/.ro-store" = {
        device = "/dev/disk/by-label/nix-store";
        fsType = "erofs";
        neededForBoot = true;
        options = [ "ro" ];
      };
      "/nix/store".overlay = {
        lowerdir = [ "/nix/.ro-store" ];
        upperdir = "/nix/.rw-store/upper";
        workdir = "/nix/.rw-store/work";
      };
    };
  };

  # qemu-vm directly boots the kernel and creates an ext4 writable disk.
  boot.loader.grub.enable = false;
  systemd.services.ryra-snapshot-prune.enable = false;
  systemd.timers.ryra-snapshot-prune.enable = false;
}
