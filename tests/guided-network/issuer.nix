{ ryraPackage, ... }:
{
  imports = [ ./issuer-module.nix ];
  services.ryraSshIssuer = {
    enable = true;
    package = ryraPackage;
    listen = "127.0.0.1:8788";
    policy = { org = "fixture"; authority = "ssh-machine"; custodians = []; grants = []; };
  };
  systemd.tmpfiles.rules = [ "Z /var/lib/ryra-ssh-issuer 0700 ryra-ssh-issuer ryra-ssh-issuer -" ];
  services.nginx.enable = true;
  systemd.services.nginx.serviceConfig.LoadCredential = [
    "ryra-issuer-cert:/var/lib/ryra-issuer-tls/server.pem"
    "ryra-issuer-key:/var/lib/ryra-issuer-tls/server.key"
  ];
  services.nginx.virtualHosts."ryra-issuer" = {
    onlySSL = true;
    listen = [ { addr = "0.0.0.0"; port = 8789; ssl = true; } { addr = "[::]"; port = 8789; ssl = true; } ];
    sslCertificate = "/run/credentials/nginx.service/ryra-issuer-cert";
    sslCertificateKey = "/run/credentials/nginx.service/ryra-issuer-key";
    locations."/certificate".proxyPass = "http://127.0.0.1:8788";
    locations."/".return = "404";
    extraConfig = "client_max_body_size 16k;";
  };
  networking.firewall.allowedTCPPorts = [ 8789 ];
}
