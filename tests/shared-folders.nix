# nix eval --impure --json --file tests/shared-folders.nix
let
  flake = builtins.getFlake ("path:" + toString ../.);
  inherit (flake.inputs.nixpkgs) lib;
  presets = [ "base" "base-arm" "azure" "desktop" "lima" "lima-intel" ];
  machine = preset: (flake.lib.mkMachine { self = ../machines + "/${preset}"; }).nixosConfigurations.machine;
  people = {
    users.users = {
      alice = { isNormalUser = true; group = "alice"; };
      bob = { isNormalUser = true; group = "bob"; home = "/home/bob work"; };
      carol = { isNormalUser = true; group = "carol"; };
    };
    users.groups = { alice = {}; bob = {}; carol = {}; };
  };
  spaces = {
    ryra.sharedFolders = {
      company = { label = "Company"; members = [ "alice" "bob" ]; };
      research = { label = "Research notes"; members = [ "alice" ]; };
    };
  };
  configured = preset: extra: ((machine preset).extendModules {
    modules = [ people spaces ] ++ extra;
  }).config;
  failures = c: map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  rules = c: builtins.filter (rule: lib.hasInfix "/srv/shared" rule || lib.hasInfix "/Shared" rule) c.systemd.tmpfiles.rules;
  summarize = c: {
    failures = failures c;
    rules = rules c;
    groups = lib.mapAttrs (_: g: g.members) (lib.filterAttrs (name: _: lib.hasPrefix "ryra-shared-" name) c.users.groups);
    homes = lib.genAttrs [ "alice" "bob" "carol" ] (name: c.users.users.${name}.home);
    mountPaths = c.systemd.services.systemd-tmpfiles-setup.unitConfig.RequiresMountsFor;
    activationMountPaths = c.systemd.services.systemd-tmpfiles-resetup.unitConfig.RequiresMountsFor;
    activationUnit = c.systemd.units."systemd-tmpfiles-resetup.service".text;
    packages = map (p: p.pname or p.name) c.environment.systemPackages;
  };
in
{
  presets = lib.genAttrs presets (preset: {
    enabled = summarize (configured preset []);
    disabled = rules (machine preset).config;
  });
  removedMember = summarize (configured "base" [ {
    ryra.sharedFolders.company.members = lib.mkForce [ "alice" ];
  } ]);
  rejected = lib.mapAttrs (_: extra: failures (configured "base" [ extra ])) {
    unknownMember.ryra.sharedFolders.company.members = [ "unknown" ];
    rootMember.ryra.sharedFolders.company.members = [ "root" ];
    duplicateLabel.ryra.sharedFolders.research.label = lib.mkForce "Company";
    pathTraversal.ryra.sharedFolders."../outside".label = "Outside";
    longName.ryra.sharedFolders.abcdefghijklmnopqrstu.label = "Too long";
  };
  invalidLabelRejected = !(builtins.tryEval (builtins.deepSeq
    (rules (configured "base" [ { ryra.sharedFolders.company.label = lib.mkForce "../outside"; } ]))
    true
  )).success;
}
