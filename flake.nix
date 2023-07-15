{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    sops-nix.url = "github:mic92/sops-nix";
  };
  outputs = { self, ...}@inputs:
  let
  build-host = name: value: inputs.nixpkgs.lib.nixosSystem {
      system = value.system;
      modules = [
        ({ pkgs, ... }: {
          nixpkgs.overlays = [
            (final: prev: {
              unstable = import inputs.unstable { system = final.system; };
            })
            (final: prev: {
              devel = import inputs.devel {
                system = final.system;
                config.allowUnfree = true;
              };
            })
          ];
        })
        { config.system.stateVersion = value.stateVersion; }
        ./hosts/${name}.nix
        inputs.sops-nix.nixosModules.sops
        inputs.home-manager.nixosModules.home-manager {
          home-manager.useGlobalPkgs = true;
          home-manager.users.sheath = {
	    home.stateVersion = value.stateVersion;
	    imports = [
	      ./home/core.nix
	    ];
	  };
        }
      ]
      ++ value.modules;
      specialArgs = {inherit inputs;};
    };

    hosts = {
      hydrogen = {
        system = "x86_64-linux";
	stateVersion = "23.05";
        home-manager = "server";
        modules = [
          ./users/sheath.nix
	  ./modules/core.nix
	  ./modules/gnome.nix
	  ./modules/syncthing.nix
        ];
      };
      oxygen = {
        system = "x86_64-linux";
	stateVersion = "23.05";
        modules = [
          ./users/sheath.nix
	  ./modules/core.nix
	  ./modules/gnome.nix
	  ./modules/syncthing.nix
	  ./modules/nvidia.nix
        ];
      };
      osmium = {
        system = "x86_64-linux";
	stateVersion = "23.05";
        modules = [
          ./users/sheath.nix
	  ./modules/core.nix
	  ./modules/gnome.nix
	  ./modules/syncthing.nix
        ];
      };
      router = {
        system = "x86_64-linux";
        home-manager = "server";
        modules = [
          ./users/sheath.nix
          ./modules/ddlient.nix
        ];
      };
    };
  in {
    nixosConfigurations = builtins.mapAttrs build-host hosts;
  };
}

