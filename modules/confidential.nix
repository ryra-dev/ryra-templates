{ config, lib, machineDir, ... }:
{
  disabledModules = [ ./hardware.nix ];
  ryra.desktop.enable = lib.mkDefault false;
  systemd.services.ryra-snapshot-prune.enable = false;
  systemd.timers.ryra-snapshot-prune.enable = false;

  assertions = [
    {
      assertion = builtins.pathExists (machineDir + "/modules/ryra/confidential-owner.nix")
        && config.boot.isContainer
        && builtins.length config.services.openssh.hostKeys == 1
        && builtins.all (key: key.type == "ed25519"
          && key.path == "/var/lib/ryra-confidential/ssh_host_ed25519_key")
          config.services.openssh.hostKeys;
      message = "A confidential workspace must retain the owner hardware module and pinned SSH host key written by Ryra.";
    }
    {
      assertion = !config.nix.distributedBuilds && config.nix.buildMachines == [];
      message = "Confidential workspace builds must remain inside the owner environment.";
    }
  ];
}
