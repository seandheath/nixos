{
  inputs = {
    devel.url = "github:seandheath/nixpkgs";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    sops-nix.url = "github:Mic92/sops-nix";
    microvm.url = "github:astro/microvm.nix";
  };
  outputs = { self, ... }@inputs:
  let
    build-host = name: value: inputs.nixpkgs.lib.nixosSystem {
      system = value.system;
      modules = [
        ({ pkgs, ... }: {
          nixpkgs.overlays = [
            (final: prev: {
              devel = import inputs.devel {
                system = final.system;
                config.allowUnfree = true;
              };
            })
          ];
        })
        ./hosts/${name}.nix
        ./modules/core.nix
        inputs.sops-nix.nixosModules.sops
        inputs.home-manager.nixosModules.home-manager {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.user = import ./home/workstation.nix;
        }
      ] ++ value.modules;
      specialArgs = {inherit inputs;};
    };

    hosts = {
      hydrogen = {
        system = "x86_64-linux";
        home-manager = "server";
        modules = [
          ./users/user.nix
          ./profiles/server.nix
          ./modules/nvidia.nix
          ./modules/nextcloud.nix
          ./modules/usenet.nix
        ];
      };

      oxygen = {
        system = "x86_64-linux";
        home-manager = "workstation";
        modules = [
          ./users/user.nix
          ./modules/nvidia.nix
          ./modules/gnome.nix
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

      router = {
        system = "x86_64-linux";
        home-manager = "server";
        modules = [
          ./users/user.nix
          ./modules/ddlient.nix
        ];
      };
    };
  in {
    nixosConfigurations = builtins.mapAttrs build-host hosts;
  };
}
