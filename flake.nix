{
  description = "ozozka's nix system config";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs =
    { self, ... }:
    let
      perSystem = self.lib.perSystem [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      lib = import ./lib.nix self;
      devShells = perSystem (self.lib.load ./devshells.nix);
      formatter = perSystem (self.lib.load ./formatter.nix);
      checks = perSystem (self.lib.load ./checks.nix);
      apps = perSystem (self.lib.load ./apps.nix);
      templates = self.lib.templates ./templates;
      packages = perSystem (self.lib.packages ./pkgs);
      nixosModules = self.lib.paths ./modules self.lib.module;
      nixosConfigurations = self.lib.paths ./hosts self.lib.load;
    };
}
