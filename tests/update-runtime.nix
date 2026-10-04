let
  flake = builtins.getFlake ("path:" + toString ../.);
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
in pkgs.runCommand "ryra-update-runtime" {
  nativeBuildInputs = [ pkgs.bash pkgs.git pkgs.openssh pkgs.jq pkgs.coreutils pkgs.diffutils ];
} ''
  export RYRA_UPDATE_TEST_TARGET="$out/fixture"
  mkdir -p "$RYRA_UPDATE_TEST_TARGET/etc/ryra/deploy" "$RYRA_UPDATE_TEST_TARGET/bin"
  for hook in health preflight; do
    printf '#!${pkgs.bash}/bin/bash\nexit "''${%s_STATUS:-0}"\n' "''${hook^^}" > "$RYRA_UPDATE_TEST_TARGET/etc/ryra/deploy/$hook"
    chmod +x "$RYRA_UPDATE_TEST_TARGET/etc/ryra/deploy/$hook"
  done
  printf '#!${pkgs.bash}/bin/bash\necho rollback >> "$TEST_EVENTS"\n' > "$RYRA_UPDATE_TEST_TARGET/bin/switch-to-configuration"
  chmod +x "$RYRA_UPDATE_TEST_TARGET/bin/switch-to-configuration"
  bash ${./update-runtime.sh} ${../modules/update.sh}
  touch "$out/passed"
''
