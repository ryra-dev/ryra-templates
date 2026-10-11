{
  description = "Ryra organization configuration";
  inputs.nixpkgs.follows = "ryra-template/nixpkgs";
  inputs.ryra-template.url = "github:ryra-dev/ryra-templates";
  outputs = { self, ryra-template, ... }@inputs:
    ryra-template.lib.mkOrganization { inherit self inputs; };
}
