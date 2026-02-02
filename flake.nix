{
  description =
    "Disko integration for nix-community/preservation with tmpfs root and optional clan";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    preservation.url = "github:nix-community/preservation";
  };

  outputs = { self, nixpkgs, preservation }: {
    nixosModules = {
      default = self.nixosModules.preservation-disko;
      preservation-disko = import ./module.nix { inherit preservation; };
    };
  };
}
