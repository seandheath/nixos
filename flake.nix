
{
  description = "A NixOS configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    impermanence.url = "github:nix-community/impermanence";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";
    nix-gaming = {
      url = "github:fufexan/nix-gaming";
      # Don't follow nixpkgs — nix-gaming pins its own nixpkgs
      # compatible with its Wine builds (supportFlags removal broke it)
    };
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=v0.7.0";
    cclaude = {
      url = "github:seandheath/cclaude";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Prebuilt nix-index database (nix-locate/command-not-found/comma).
    # DB is pinned to this input's rev and refreshes on deliberate input bumps
    # (`nu`), not the nightly autoUpgrade (which runs --no-write-lock-file).
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pi-flake = {
      url = "github:ChauDucToan/pi-flake";
      # Deliberately does NOT follow nixpkgs — pi-flake targets nixpkgs-unstable
      # and forcing our 25.11 pin risks build breakage (mirrors nix-gaming above).
    };
  };

  outputs = { self, nixpkgs, nixos-hardware, home-manager, sops-nix, impermanence, disko, chaotic, nix-gaming, nix-flatpak, cclaude, ... }@inputs:
    let
      commonModules = [
        home-manager.nixosModules.home-manager
        sops-nix.nixosModules.sops
        nix-flatpak.nixosModules.nix-flatpak
        ./modules/nix-settings.nix
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.sheath = import ./home/sheath.nix;
          home-manager.extraSpecialArgs = { inherit inputs; };
          # Rename pre-existing files aside instead of aborting activation. Without
          # this a single unmanaged file that HM wants to own fails the whole
          # home-manager-sheath.service, and with it the nixos-rebuild switch --
          # a stale ~/.cache/nix-index/files did exactly that on 2026-07-21.
          home-manager.backupFileExtension = "hm-bak";
          users.users.sheath = import ./users/sheath.nix;
          users.groups.sheath = {};
          nixpkgs.config.allowUnfree = true;
        }
      ];
    in {
    nixosConfigurations = {
      hydrogen = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; lib = nixpkgs.lib; };
        modules = [
          ./hosts/hydrogen.nix
        ] ++ commonModules;
      };
      osmium = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; lib = nixpkgs.lib; };
        modules = [
          ./hosts/osmium.nix
          chaotic.nixosModules.default
        ] ++ commonModules;
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
