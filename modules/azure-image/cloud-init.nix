# Import alongside the matching Ryra hardware template when building a clean cloud image.
# Hardware, disk layout and workspace packages remain owned by that template.
# This module contains no customer identity and does not create or snapshot a server.
{ lib, pkgs, ... }:
{
  services.cloud-init = {
    enable = true;
    settings = {
      datasource_list = lib.mkDefault [ "Azure" "Hetzner" ];
      preserve_hostname = true;
      ssh_deletekeys = true;
      ssh_pwauth = false;
      disable_root = false;
      # Ryra supplies all access through user_data. Hetzner's vendor password
      # configuration uses deprecated fields and is unnecessary for key-only SSH.
      vendor_data.enabled = false;
      vendor_data2.enabled = false;
      # The Nix package lacks the optional console fingerprint helper.
      ssh.emit_keys_to_console = false;
    };
  };
  environment.systemPackages = [ pkgs.cloud-init (pkgs.writeShellApplication {
    name = "ryra-cloud-ready";
    runtimeInputs = [ pkgs.coreutils pkgs.cloud-init pkgs.chromium ];
    text = ''
      test -f /etc/NIXOS || { echo "This image is not NixOS" >&2; exit 1; }
      test -f /var/lib/cloud/instance/boot-finished || { echo "Initial computer setup is still running" >&2; exit 1; }
      cloud-init status --format json >/dev/null
      herdr --version >/dev/null
      probe_dir=$(mktemp -d)
      trap 'rm -rf "$probe_dir"' EXIT
      printf 'workspace probe\n' > "$probe_dir/document.txt"
      timeout 60 chromium --headless --no-sandbox --disable-gpu --no-first-run \
        --disable-background-networking --disable-component-update --disable-sync \
        --user-data-dir="$probe_dir/browser" --dump-dom about:blank >/dev/null
    '';
  }) ];
  # Initial purchaser accounts arrive through provider user_data. Later organization
  # deployments declare those same accounts through the ordinary Ryra login module.
  users.mutableUsers = true;
  services.openssh = {
    enable = true;
    settings = {
      Include = "/etc/ssh/sshd_config.d/*.conf";
      AuthorizedPrincipalsFile = null;
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  # cloud-config creates host keys too. Finish it before NixOS checks/generates
  # keys, or both generators race on the first boot of a clean snapshot.
  systemd.services.sshd-keygen.after = [ "cloud-config.service" ];
  systemd.services.sshd.aliases = [ "ssh.service" ];
  systemd.tmpfiles.rules = [
    "d /etc/ssh/sshd_config.d 0755 root root -"
    "d /etc/sudoers.d 0750 root root -"
    "L+ /bin/bash - - - - ${pkgs.bashInteractive}/bin/bash"
  ];
  security.sudo.enable = true;
  security.sudo.extraConfig = "@includedir /etc/sudoers.d";
  systemd.services.cloud-final.path = [ pkgs.shadow pkgs.coreutils pkgs.systemd ];
  networking.useDHCP = lib.mkDefault true;
}
