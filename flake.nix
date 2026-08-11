
{
  description = "A NixOS configuration";

  # TWO CHANNELS, deliberately. hydrogen is the only stable host; the five laptops
  # track unstable. See mkHost below -- a host's channel is declared exactly once,
  # there, and modules/fleet-channel.nix carries it into the config so
  # modules/auto-update.nix can override the right input at 04:00.
  inputs = {
    # STABLE -- hydrogen only (immich, postgres 17, minecraft-server; runs 24/7).
    # nixos-25.11 went EOL: its branch stopped moving on 2026-06-30, which froze
    # signal-desktop at 8.9.1 -- past Signal's ~90-day hard expiry -- and stopped
    # security backports for everything else. 26.05 is the supported stable.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # UNSTABLE -- sulfur and the four kids' laptops.
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # home-manager master is what tracks nixpkgs-unstable; release-26.05 against an
    # unstable nixpkgs is the option-rename breakage of f11c4af waiting to happen.
    home-manager-unstable = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
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
    #
    # Follows the STABLE nixpkgs on every host, including the unstable ones. This is
    # a prebuilt database keyed to one nixpkgs rev, so a second copy for unstable
    # would double these lock nodes to fix nothing that matters: the consequence of
    # the skew is that `nix-locate` on a laptop describes 26.05's package set rather
    # than its own. Cosmetic, and accepted.
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pi-flake = {
      url = "github:ChauDucToan/pi-flake";
      # Deliberately does NOT follow nixpkgs — pi-flake targets nixpkgs-unstable
      # and forcing the stable pin risks build breakage (mirrors nix-gaming above).
      # Used on sulfur, which is now unstable itself, so this skew is gone.
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixos-hardware, home-manager, home-manager-unstable, sops-nix, impermanence, disko, chaotic, nix-gaming, nix-flatpak, cclaude, ... }@inputs:
    let
      # Parameterized by the channel's home-manager, because that is the one module
      # in here that genuinely differs between the two: HM's NixOS module has to
      # match the nixpkgs it will evaluate home/sheath.nix against.
      #
      # sops-nix, disko, cclaude and nix-index-database keep a single instance
      # following stable nixpkgs. They contribute NixOS modules that build against
      # the *host's* pkgs, so a per-channel copy of each would double those
      # flake.lock nodes and change nothing.
      commonModules = { hm }: [
        hm.nixosModules.home-manager
        sops-nix.nixosModules.sops
        nix-flatpak.nixosModules.nix-flatpak
        ./modules/nix-settings.nix
        # Declares fleet.channel, which mkHost sets below.
        ./modules/fleet-channel.nix
        # Every host, deliberately: NetworkManager will flush a WireGuard interface it
        # thinks it owns, and the hosts that most need protecting are the ones nobody
        # is watching. See the module header.
        ./modules/wg-unmanaged.nix
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

      # THE ONLY PLACE A HOST'S CHANNEL IS DECLARED. `channel` picks the nixpkgs, the
      # matching home-manager, and the lib that builds the system, and it is also
      # written into the config as fleet.channel so modules/auto-update.nix overrides
      # the correct input at 04:00. Those cannot drift apart, because they are one
      # argument.
      mkHost = { channel, hostName, extraModules ? [ ] }:
        let
          np = if channel == "unstable" then nixpkgs-unstable else nixpkgs;
          hm = if channel == "unstable" then home-manager-unstable else home-manager;
        in np.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; lib = np.lib; };
          modules = [
            ./hosts/${hostName}.nix
            { fleet.channel = channel; }
          ] ++ extraModules ++ commonModules { inherit hm; };
        };
    in {
    nixosConfigurations = {
      # The only stable host: postgres 17 and immich, up 24/7, and the one machine
      # where an unattended nightly rebuild against a moving branch is not worth it.
      hydrogen = mkHost { channel = "stable"; hostName = "hydrogen"; };

      sulfur = mkHost {
        channel = "unstable";
        hostName = "sulfur";
        extraModules = [
          nixos-hardware.nixosModules.asus-zephyrus-gu605my
          impermanence.nixosModules.impermanence
          chaotic.nixosModules.default
        ];
      };
    }
    # The kids' laptops. Identical apart from the hostname, which is the only thing
    # they declare: modules/family/profile.nix derives the username, WireGuard peer
    # address, sops key names and Minecraft handle from it via
    # modules/family/peers.nix.
    #
    # They still get commonModules, and therefore the sheath account and its home
    # config -- that is what makes them administrable. What they do NOT get is
    # modules/workstation.nix; see the header of modules/family/profile.nix.
    #
    # No nixos-hardware module yet: add the matching one here once the actual laptop
    # models are known. hardware/<name>.nix is a placeholder until install.sh
    # regenerates it on the real machine.
    #
    # These four MUST stay on the same channel as sulfur. Their VLAN resolves
    # cache.nixos.org to 0.0.0.0 (modules/family/profile.nix), so they substitute
    # nothing and get their closures pushed from sulfur's store with
    # `nixos-rebuild --target-host`. That only works while sulfur evaluates to the
    # same store paths they do -- i.e. same nixpkgs, same inputs.
    // nixpkgs.lib.genAttrs [
      "gentlemenpupil"
      "vizualwanderer"
      "phantomspecialst"
      "maddreamer"
    ] (host: mkHost { channel = "unstable"; hostName = host; });
  };
}
