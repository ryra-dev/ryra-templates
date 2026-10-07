{
  description = "Ryra organization configuration";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.ryra-template = {
    url = "github:ryra-dev/ryra-templates";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { self, ryra-template, ... }@inputs:
    ryra-template.lib.mkOrganization { inherit self inputs; };
}
