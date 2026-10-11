# Internal units use an immutable static runtime, independent of the client-prepared runtime.
# Published archives must remain available for machines pinned to them.
{ lib, pkgs, ... }:
let
  version = "0.1.61";

  # Published target triples. Keyed by system so one file serves both
  # templates rather than two copies drifting apart.
  published = {
    "x86_64-linux" = {
      arch = "x86_64-unknown-linux-musl";
      sha256 = "e852bd7dbd271d4514ed32238dd614ed8d94e0aac09e2940e3d3a60114ce81cb";
    };
    "aarch64-linux" = {
      arch = "aarch64-unknown-linux-musl";
      sha256 = "023aa94b961fdaf140b6fbb57b26c352cc4aed7a7370dfeb337421faefe034ec";
    };
  };
  package = published.${pkgs.stdenv.hostPlatform.system};

  ryra = pkgs.stdenv.mkDerivation {
    pname = "ryra";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://pkg.ryra.dev/bin/ryra-${version}-${package.arch}.tar.gz";
      inherit (package) sha256;
    };

    # Static Linux runtimes shipped alongside the desktop release.
    sourceRoot = ".";
    installPhase = ''
      install -Dm755 ryra $out/bin/ryra
    '';

    # Shaped the way nixpkgs shapes a closed-source binary, because that is what this would be
    # submitted AS. Slack, zoom and 1password are all in nixpkgs on exactly these terms: a
    # published artefact, `binaryNativeCode`, and an unfree licence. Building from source is not
    # an option nixpkgs has here and repackaging is not a lesser path, it is the path.
    #
    # `sourceProvenance` is the part that is easy to leave out and is not optional: it is how
    # somebody auditing a closure learns that this came down as a binary rather than being
    # compiled, and 1227 packages in nixpkgs declare it.
    meta = {
      description = "Ryra: machines, secrets, deployments and agent workspaces";
      homepage = "https://ryra.dev";
      sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
      license = lib.licenses.unfree;
      platforms = builtins.attrNames published;
      mainProgram = "ryra";
    };
  };
in
{
  _module.args.ryraPackage = ryra;
}
