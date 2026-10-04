# Add this machine's local settings here. Ryra imports .nix files under modules/
# automatically, except modules/ryra/settings.nix (read by the service module).
# Leave generated logins.nix and secrets.nix to Ryra.
{ ... }:
{
  # time.timeZone = "Europe/Oslo";
  # i18n.defaultLocale = "nb_NO.UTF-8";
}
