# nix eval --impure --json --file tests/shared-folders.nix
let
  flake = builtins.getFlake ("path:" + toString ../.);
  inherit (flake.inputs.nixpkgs) lib;
  machines = import ./machines.nix;
  presets = builtins.attrNames machines;
  machine = preset: machines.${preset};
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
  rules = c: builtins.filter (rule: lib.hasInfix "/srv/shared" rule || lib.hasInfix "/Shared" rule || lib.hasInfix "/data/" rule) c.systemd.tmpfiles.rules;
  summarize = c: {
    failures = failures c;
    rules = rules c;
    groups = lib.mapAttrs (_: g: g.members) (lib.filterAttrs (name: _: lib.hasPrefix "ryra-shared-" name) c.users.groups);
    homes = lib.genAttrs [ "alice" "bob" "carol" ] (name: c.users.users.${name}.home);
    mountPaths = c.systemd.services.systemd-tmpfiles-setup.unitConfig.RequiresMountsFor;
    activationMountPaths = c.systemd.services.systemd-tmpfiles-resetup.unitConfig.RequiresMountsFor;
    activationUnit = c.systemd.units."systemd-tmpfiles-resetup.service".text;
    packages = map (p: p.pname or p.name) c.environment.systemPackages;
    activation = c.system.activationScripts.ryraSharedFolders.text;
  };
  throws = extra: !(builtins.tryEval (builtins.deepSeq (rules (configured "base" [ extra ])) true)).success;
in
{
  presets = lib.genAttrs presets (preset: {
    enabled = summarize (configured preset []);
    disabled = rules (machine preset).config;
  });
  removedMember = summarize (configured "base" [ {
    ryra.sharedFolders.company.members = lib.mkForce [ "alice" ];
  } ]);
  located = summarize (configured "base" [ {
    ryra.sharedFolders.research.path = "/data/research";
    ryra.sharedFolders.company.members = lib.mkForce [ "alice" "bob" "deploy" ];
  } ]);
  elsewhere = rules (configured "base" [ {
    ryra.sharedFolders.company.path = "/data/company";
    ryra.sharedFolders.research.path = "/data/research";
  } ]);
  rejected = lib.mapAttrs (_: extra: failures (configured "base" [ extra ])) {
    rootMember.ryra.sharedFolders.company.members = [ "root" ];
    systemPath.ryra.sharedFolders.company.path = "/etc/company";
    homePath.ryra.sharedFolders.company.path = "/home/alice/company";
    samePath.ryra.sharedFolders.research.path = "/srv/shared/company";
    nestedPath.ryra.sharedFolders.research.path = "/srv/shared/company/research";
    duplicateLabel.ryra.sharedFolders.research.label = lib.mkForce "Company";
    longName.ryra.sharedFolders.abcdefghijklmnopqrstu.label = "Too long";
  };
  # A value its type refuses stops evaluation rather than failing an assertion.
  thrown = lib.mapAttrs (_: throws) {
    pathTraversal.ryra.sharedFolders."../outside".label = "Outside";
    label.ryra.sharedFolders.company.label = lib.mkForce "../outside";
    shallowPath.ryra.sharedFolders.company.path = "/data";
    dotPath.ryra.sharedFolders.company.path = "/srv/../etc/company";
    spacedPath.ryra.sharedFolders.company.path = "/data/my company";
    memberName.ryra.sharedFolders.company.members = [ "a;b" ];
  };
}
