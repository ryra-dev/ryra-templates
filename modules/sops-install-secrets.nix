# sops-nix compiles its activation helper from source against the machine's own nixpkgs, which no
# binary cache holds: minutes on two cores, the first time a machine has a secret and after every
# NixOS update. Each Ryra release publishes it built from the sops-nix revision this template
# locks (lib/sops-install-secrets-release.nix), and a machine on that revision fetches it by hash.
# Another revision may write a manifest that binary does not read, so it compiles as before.
{ revision }:
{ lib, pkgs, ... }:
let
  published = {
    revision = "13616fff713a9f94055c66f15687ebdc17a335df";
    x86_64-linux = "sha256-QYQPgk3A0rfa9MOMZ3ByUQkqllyzO6E8dxsxIoolAiM=";
    aarch64-linux = "sha256-nk/3/k2GZS1rYlSGxzFUePoo5kwZI2/xWhdKmbLy6k8=";
  };
  system = pkgs.stdenv.hostPlatform.system;
in
{
  config = lib.mkIf ((published.revision or null) == revision && published ? ${system}) {
    # Fetched straight into the package's own layout, so its store path is fixed by the hash
    # alone: a NixOS update rebuilds nothing, and nothing fetches it again once it is here.
    sops.package = pkgs.fetchurl {
      name = "sops-install-secrets";
      url = "https://pkg.ryra.dev/bin/sops-install-secrets-${revision}-${system}";
      hash = published.${system};
      downloadToTemp = true;
      recursiveHash = true;
      postFetch = "install -Dm555 $downloadedFile $out/bin/sops-install-secrets";
    };
  };
}
