{
  "ryra/authelia".settings.initialAccountFile = "/run/initial-auth-account";
  "ryra/grafana".settings = {
    adminPasswordFile = "/run/grafana-admin";
    secretKeyFile = "/run/grafana-key";
    extraSettings.panels.disable_sanitize_html = true;
  };
}
