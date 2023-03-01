{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    impermanence.url = "github:nix-community/impermanence";
  };
  outputs = { self, home-manager, ... }@inputs:
    let
      build-host = name: value: inputs.nixpkgs.lib.nixosSystem {
        system = value.system;
        modules = [
          ./hosts/${name}.nix
          ./modules/core.nix
          "${inputs.impermanence}/nixos.nix"
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.lo = import ./home/workstation.nix;
          }
        ] ++ value.modules;
        specialArgs = { inherit inputs; };
      };

      hosts = {
        hydrogen = {
          system = "x86_64-linux";
          home-manager = "server";
          modules = [
            ./users/lo.nix
            ./modules/server.nix
            ./modules/nvidia.nix
            ./modules/usenet.nix
            ./modules/gnome.nix
          ];
        };

        oxygen = {
          system = "x86_64-linux";
          home-manager = "workstation";
          modules = [
            ./users/lo.nix
            ./modules/nvidia.nix
            ./modules/workstation.nix
            ./modules/dod_certs.nix
          ];
        };

        uranium = {
          system = "x86_64-linux";
          home-manager = "workstation";
          modules = [
            ./users/user.nix
            ./modules/gnome.nix
          ];
        };

        plutonium = {
          system = "x86_64-linux";
          home-manager = "workstation";
          modules = [
            ./users/user.nix
            ./modules/gnome.nix
            ./modules/nvidia.nix
          ];
        };

        osmium = {
          system = "x86_64-linux";
          modules = [
            ./users/lo.nix
            ./modules/workstation.nix
            ./modules/gnome.nix
          ];
        };

        router = {
          system = "x86_64-linux";
          home-manager = "server";
          modules = [
            ./users/user.nix
            ./modules/ddlient.nix
          ];
        };
      };
    in
    {
      nixosConfigurations = builtins.mapAttrs build-host hosts;
    };
}
