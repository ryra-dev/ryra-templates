{ ... }: {
  sops.secrets.grafana-fixture = {
    owner = "grafana";
    path = "/run/secrets/grafana-fixture";
  };
}
