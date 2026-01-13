
{
  description = "A NixOS configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    home-manager = {
      url = "github:nix-community/home-manager/master";  # master tracks unstable
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    impermanence.url = "github:nix-community/impermanence";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";
  };

  outputs = { self, nixpkgs, nixos-hardware, home-manager, sops-nix, agenix, impermanence, disko, chaotic, ... }@inputs:
    let
      commonModules = [
        home-manager.nixosModules.home-manager
        sops-nix.nixosModules.sops
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.sheath = import ./home/sheath.nix;
          home-manager.extraSpecialArgs = { inherit inputs; };
          users.users.sheath = import ./users/sheath.nix;
          users.groups.sheath = {};
          nix.settings.download-buffer-size = 1073741824;
          nix.settings.experimental-features = [ "nix-command" "flakes" ];
        }
      ];
    in {
    nixosConfigurations = {
      osmium = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; lib = nixpkgs.lib; };
        modules = [
          ./hosts/osmium.nix
          chaotic.nixosModules.default
        ] ++ commonModules;
      };
      pentest-vm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; lib = nixpkgs.lib; };
        modules = [ ./hosts/pentest-vm.nix ] ++ commonModules;
      };
      surface = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; lib = nixpkgs.lib; };
        modules = [
          ./hosts/surface.nix
          nixos-hardware.nixosModules.microsoft-surface-go
        ] ++ commonModules;
      };
      sulphur = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; lib = nixpkgs.lib; };
        modules = [
          ./hosts/sulphur.nix
          nixos-hardware.nixosModules.asus-zephyrus-gu605my
          impermanence.nixosModules.impermanence
          chaotic.nixosModules.default
        ] ++ commonModules;
      };
    };
  };
}
