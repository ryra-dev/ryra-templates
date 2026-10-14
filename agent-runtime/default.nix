{ pkgs }:
pkgs.buildNpmPackage {
  pname = "ryra-agent-support";
  version = "1";
  src = ./.;
  npmDepsHash = "sha256-nFUCt5tr6V4zVnpGKz6M6ockIQFd9ULQ/D1vEFxF4Ik=";
  npmFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;
  nativeBuildInputs = [ pkgs.makeWrapper ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.autoPatchelfHook ];
  # ncurses provides libtinfo.so.6 for the zsh vendored inside @openai/codex-linux-x64.
  buildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.stdenv.cc.cc.lib pkgs.ncurses ];
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/ryra-agents $out/bin
    cp -r node_modules $out/lib/ryra-agents/
    for agent in claude-agent-acp codex-acp; do
      makeWrapper ${pkgs.nodejs_24}/bin/node $out/bin/$agent \
        --add-flags "$out/lib/ryra-agents/node_modules/@agentclientprotocol/$agent/dist/index.js"
    done
    runHook postInstall
  '';
}
