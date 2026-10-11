{
  description = "Ryra machine configuration";
  inputs.nixpkgs.follows = "ryra-template/nixpkgs";
  inputs.ryra-template.url = "github:ryra-dev/ryra-templates";
  outputs = { self, ryra-template, ... }@inputs:
    ryra-template.lib.mkMachine { inherit self inputs; };
}
