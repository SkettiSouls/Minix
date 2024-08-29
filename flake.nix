{
  description = "Minix: NixOS module for minecraft servers";

  inputs = {
    nixpkgs = {
      type = "github";
      owner = "NixOS";
      repo = "nixpkgs";
      ref = "nixos-unstable";
    };

    curseforge-server-downloader-src = {
      type = "github";
      owner = "Malpiszonekx4";
      repo = "curseforge-server-downloader";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    curseforge-server-downloader-src,
    ...
  }: let
    supportedSystems = [
      "x86_64-linux"
      "x86_64-darwin"
    ];

    perSystem = attrs:
      nixpkgs.lib.genAttrs supportedSystems (system:
        attrs (import nixpkgs {inherit system;}));
  in {
    nixosModules = {
      nix-mc = import ./modules;

      default = self.nixosModules.nix-mc;
    };

    packages = perSystem (pkgs: {
      curseforge-server-downloader =
        pkgs.callPackage
        ./pkgs/curseforge-server-downloader.nix {
          inherit curseforge-server-downloader-src;
        };
    });

    formatter = perSystem (pkgs: pkgs.alejandra);
  };
}
