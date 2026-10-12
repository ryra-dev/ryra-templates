{ ... }: {
  environment.etc."ryra/ports.json".text = builtins.toJSON {
    interface = "eth0";
    rules = [ { protocol = "tcp"; port = 80; sources = [ "0.0.0.0/0" ]; } ];
  };
  networking.nftables.enable = true;
  networking.nftables.tables.ryra-ports = {
    family = "inet";
    content = ''
      chain public_ingress {
        type filter hook prerouting priority -150; policy accept;
        iifname != "eth0" accept
        ct state established,related accept
        meta l4proto { icmp, ipv6-icmp } accept
        udp sport 67 udp dport 68 accept
        udp sport 547 udp dport 546 accept
        tcp dport { 22 8789 80 } accept
        drop
      }
    '';
  };
}
