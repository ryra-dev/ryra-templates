{ config, lib, pkgs, ... }:
let
  disk = config.disko.devices.disk.main;
  cleanUsers = lib.all (user:
    !user.isNormalUser
    && user.openssh.authorizedKeys.keys == []
    && user.openssh.authorizedKeys.keyFiles == []
  ) (lib.attrValues config.users.users);
in {
  imports = [ ../azure.nix ./cloud-init.nix ];

  services.cloud-init.enable = lib.mkOverride 40 true;
  services.cloud-init.settings.datasource_list = [ "Azure" ];
  services.waagent.settings = {
    Provisioning.Agent = lib.mkForce "cloud-init";
    Extensions.Enabled = lib.mkForce true;
  };
  boot.initrd.availableKernelModules = [ "nvme" "hv_storvsc" "hv_vmbus" "hv_netvsc" ];
  disko.devices.disk.main.imageSize = lib.mkDefault "32G";
  disko.imageBuilder.imageFormat = "raw";
  # Disko passes an aggregated module tree as vmTools.kernel. Current nixpkgs
  # needs the bootable kernel and module tree as separate arguments.
  disko.imageBuilder.pkgs = pkgs // {
    vmTools = pkgs.vmTools // {
      override = args: pkgs.vmTools.override (args // {
        kernel = config.disko.imageBuilder.kernelPackages.kernel;
        kernelModules = args.kernel;
      });
    };
  };

  environment.systemPackages = [ (pkgs.writeShellApplication {
    name = "ryra-pool-handoff";
    runtimeInputs = [ pkgs.python3 pkgs.shadow pkgs.openssh pkgs.systemd pkgs.coreutils ];
    text = ''exec python3 ${./pool-handoff.py} "$@"'';
  }) ];

  assertions = [
    { assertion = config.nixpkgs.hostPlatform.system == "x86_64-linux";
      message = "The Azure image template builds an x86-64 Gen 2 image."; }
    { assertion = cleanUsers && config.sops.secrets == {} && !config.ryra.tailscale.enable;
      message = "Build Azure images without customer accounts, SSH keys, SOPS secrets or Tailscale enrollment."; }
    { assertion = !config.services.ryra-update.enable && !config.system.autoUpgrade.enable;
      message = "Enable automatic updates in the assigned machine's declaration, not in the shared Azure image."; }
  ];

  system.build.azureImage = pkgs.runCommand "ryra-azure-image" {
    nativeBuildInputs = [ pkgs.qemu ];
  } ''
    mkdir -p "$out"
    qemu-img convert -f raw -O vpc -o subformat=fixed,force_size=on \
      ${config.system.build.diskoImages}/${lib.escapeShellArg disk.imageName}.raw "$out/ryra.vhd"
    qemu-img info --output=json "$out/ryra.vhd" > "$out/image.json"
  '';
}
