
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

  outputs = { self, nixpkgs, home-manager, sops-nix, agenix, ... }@inputs: {
    nixosConfigurations = {
      osmium = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; lib = nixpkgs.lib; };
        modules = [
          ./hosts/osmium.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "bak";
            home-manager.users.sheath = import ./users/sheath.nix;
            home-manager.extraSpecialArgs = { inherit inputs; };
            users.users.sheath = {
              isNormalUser = true;
              description = "sheath";
              extraGroups = [ "wheel" "networkmanager" "video" "libvirtd" "docker" ];
              openssh.authorizedKeys.keys = [
                "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGLhPOBx9dR2X3oYz5RS2eAGZA7YSeHPcnrQauHSmuk1"
              ];
              group = "sheath";
            };
            users.groups.sheath = {};
            nix.settings.download-buffer-size = 1073741824;
            nix.settings.experimental-features = [ "nix-command" "flakes" ];
          }
        ];
      };
    };
  };
}
