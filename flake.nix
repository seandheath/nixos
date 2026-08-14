{
  description = "A NixOS configuration";

  # ONE CHANNEL for the whole fleet: a second one costs another home-manager input, a
  # channel option, and a branch table in auto-update.nix, all to defend against an EOL
  # that nixos-unstable cannot have.
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    nixos-hardware = {
      url = "github:NixOS/nixos-hardware/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # master is the branch that tracks nixpkgs-unstable; a release-* home-manager against
    # unstable is an option-rename break waiting to happen.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative disk layout. One description of a disk drives both the partitioning and
    # the fileSystems config, so install.sh cannot format one shape and describe another.
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    cclaude = {
      url = "github:seandheath/cclaude";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Prebuilt nix-index database (nix-locate/comma). Refreshes on deliberate input bumps
    # (`nu`), not the nightly, which passes --no-write-lock-file.
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Does not follow nixpkgs: pi-flake pins its own.
    pi-flake.url = "github:ChauDucToan/pi-flake";
  };

  outputs = { self, nixpkgs, nixos-hardware, home-manager, sops-nix, impermanence, disko, ... }@inputs:
    let
      system = "x86_64-linux";

      commonModules = [
        home-manager.nixosModules.home-manager
        sops-nix.nixosModules.sops
        disko.nixosModules.disko
        # Inert until a host sets fleet.disk.enable, so the hosts still carried by a
        # hand-written hardware/<host>.nix are untouched by adding it here.
        ./modules/disk-layout.nix
        ./modules/nix-settings.nix
        ./modules/sops.nix
        ./modules/accounts.nix
        ./modules/boot-efi.nix
        ./modules/locale.nix
        ./modules/auto-update.nix
        # Every host: NetworkManager will flush a WireGuard interface it thinks it owns,
        # and the hosts that most need protecting are the ones nobody is watching.
        ./modules/wg-unmanaged.nix
        # Every host: hydrogen's br0 lost its slave during the 2026-08-13 nightly and
        # stayed unreachable for six hours. Defines nothing on a host with no bridges.
        ./modules/bridge-slave-restore.nix
        { nixpkgs.overlays = [ (import ./packages) ]; }
        # Every host: sulfur's Ghostty sets TERM=xterm-ghostty, which nixpkgs' ncurses does
        # not carry, and an SSH session inherits it.
        ({ pkgs, ... }: { environment.systemPackages = [ pkgs.ghostty.terminfo ]; })
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.sheath = import ./home/sheath.nix;
          home-manager.extraSpecialArgs = { inherit inputs; };
          # Rename pre-existing files aside rather than failing activation, which would
          # fail the whole nixos-rebuild switch with it.
          home-manager.backupFileExtension = "hm-bak";
          users.users.sheath = import ./users/sheath.nix;
          users.groups.sheath = {};
          nixpkgs.config.allowUnfree = true;
        }
      ];

      mkHost = { hostName, extraModules ? [ ] }: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [ ./hosts/${hostName}.nix ] ++ extraModules ++ commonModules;
      };

      # The kids' laptops. modules/family/profile.nix derives the username, WireGuard peer
      # address, sops key names and Minecraft handle from the hostname via
      # modules/family/peers.nix, so a host declares only its hostname and hardware.
      # Value is the host's hardware-model modules, the seam mkHost has as extraModules.
      familyHosts = {
        gentlemenpupil = [ ./modules/oryp10.nix ]; # System76 Oryx Pro 10, ex-osmium
        vizualwanderer = [ ];
        phantomspecialst = [ ];
        maddreamer = [ ];
      };

      hosts = {
        hydrogen = mkHost { hostName = "hydrogen"; };

        sulfur = mkHost {
          hostName = "sulfur";
          extraModules = [
            nixos-hardware.nixosModules.asus-zephyrus-gu605my
            impermanence.nixosModules.impermanence
          ];
        };
      } // nixpkgs.lib.mapAttrs (hostName: extraModules: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          ./modules/family/profile.nix
          ./hardware/${hostName}.nix
          { networking.hostName = hostName; }
        ] ++ extraModules ++ commonModules;
      }) familyHosts;
    in {
      nixosConfigurations = hosts;

      # `nix flake check` builds every host, so a change is verified against the five
      # machines you are not sitting at before it is committed.
      checks.${system} =
        nixpkgs.lib.mapAttrs (_: h: h.config.system.build.toplevel) hosts;

      packages.${system} =
        let pkgs = import nixpkgs { inherit system; config.allowUnfree = true; overlays = [ (import ./packages) ]; };
        in {
          inherit (pkgs) ghidra-reva imjtool jackify qwen-code re-container;
        };
    };
}
