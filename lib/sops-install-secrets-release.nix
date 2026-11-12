# The binaries a Ryra release publishes for modules/sops-install-secrets.nix to fetch: sops-nix's
# own build at the locked revision, without cgo, so they reference nothing in the store they land
# in. Users and groups are then read from /etc/passwd and /etc/group rather than through NSS,
# which on NixOS holds every declared account.
{ pkgs, sops-nix }:
(pkgs.callPackage sops-nix.outPath { }).sops-install-secrets.overrideAttrs (old: {
  pname = "sops-install-secrets-release";
  outputs = [ "out" ];
  env = (old.env or { }) // { CGO_ENABLED = "0"; };
  buildPhase = ''
    runHook preBuild
    for arch in amd64 arm64; do
      GOARCH=$arch go build -trimpath -ldflags="-s -w" -o "build/$arch/sops-install-secrets" ./pkgs/sops-install-secrets
    done
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 build/amd64/sops-install-secrets $out/x86_64-linux
    install -Dm755 build/arm64/sops-install-secrets $out/aarch64-linux
    runHook postInstall
  '';
  # nixpkgs patches Go to look up MIME types, services and time zones in these. Without them Go
  # reads the system's own files and its built-in tables, as it does on any other system.
  nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.removeReferencesTo ];
  postInstall = ''
    remove-references-to -t ${pkgs.mailcap} -t ${pkgs.iana-etc} -t ${pkgs.tzdata} $out/*
  '';
  allowedReferences = [ ];
})
