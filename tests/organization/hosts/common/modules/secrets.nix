{ ... }: {
  sops.validateSopsFiles = false;
  sops.secrets.token.sopsFile = ../secrets/vault.yaml;
}
