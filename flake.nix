
{
  description = "A NixOS configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
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
  };

  outputs = { self, nixpkgs, home-manager, sops-nix, agenix, ... }@inputs:
    let
      commonModules = [
        home-manager.nixosModules.home-manager
        sops-nix.nixosModules.sops
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
                      home-manager.users.sheath = import ./home/sheath.nix;
                      home-manager.extraSpecialArgs = { inherit inputs; };
                      users.users.sheath = (import ./users/sheath.nix) // {
                        hashedPasswordFile = config.sops.secrets.sheath_password_hash.path;
                      };
                      sops.secrets.sheath_password_hash = {};
                      users.groups.sheath = {};          nix.settings.download-buffer-size = 1073741824;
          nix.settings.experimental-features = [ "nix-command" "flakes" ];
        }
      ];
    in {
    nixosConfigurations = {
      osmium = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; lib = nixpkgs.lib; };
        modules = [ ./hosts/osmium.nix ] ++ commonModules;
      };
      pentest-vm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; lib = nixpkgs.lib; };
        modules = [ ./hosts/pentest-vm.nix ] ++ commonModules;
      };
    };
  };
}
