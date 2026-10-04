# One machine, starting from the shared base.
#
# `?dir=` rather than a copy or a submodule: nix reads a flake from a
# subdirectory natively, `flake.lock` pins which commit, and overriding it is a
# `follows` rather than a fork. The organization decides when it moves, in a
# commit, with a diff.
{
  inputs.base.url = "github:ryra-dev/ryra-templates?dir=machines/base";

  outputs =
    { base, ... }:
    {
      # Named `machine` because a template cannot know what the box will be
      # called. `ryra org machines install` uses this when the flake has no host
      # matching the machine's name.
      nixosConfigurations.machine = base.nixosConfigurations.machine.extendModules {
        modules = [ ../../aspects/base.nix ];
      };
    };
}
