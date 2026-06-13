{
  description = "NixOS & nix-darwin module to configure JuiceFS (mounts, S3 gateway, WebDAV)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      nixosModules.juicefs = import ./modules/juicefs.nix;
      nixosModules.default = self.nixosModules.juicefs;

      darwinModules.juicefs = import ./modules/darwin.nix;
      darwinModules.default = self.darwinModules.juicefs;

      packages = forAllSystems (pkgs: {
        juicefs = pkgs.juicefs;
        default = pkgs.juicefs;
      });
    };
}
