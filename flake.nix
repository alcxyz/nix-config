# flake.nix
{
  description = "NixOS and Nix-Darwin configurations for multiple hosts with standalone Home Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    darwin = {
      url = "github:lnl7/nix-darwin";
      follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs = { self, nixpkgs, darwin, home-manager, ... }@inputs:
  let
    # Define the user for whom Home Manager is configured
    username = "alc";

    # Define the architectures we support
    supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

    # Helper to get the pkgs set for a specific architecture
    pkgsFor = arch: import nixpkgs {
      system = arch;
      config.allowUnfree = true; # Example: Allow unfree packages (adjust as needed)
    };

    # Define NixOS hosts and their configurations
    nixosHosts = {
      xyz = {
        system = "x86_64-linux"; # Or "aarch64-linux" if on ARM server
        configuration = ./hosts/xyz/configuration.nix;
      };
      nuc = {
        system = "x86_64-linux"; # Or "aarch64-linux" if on ARM server
        configuration = ./hosts/nuc/configuration.nix;
      };
      # Add other NixOS hosts here
    };

    # Define Nix-Darwin hosts and their configurations
    darwinHosts = {
      mac = {
        system = "aarch64-darwin"; # For Apple Silicon. Use "x86_64-darwin" for Intel Macs.
        configuration = ./hosts/mac/configuration.nix;
      };
      # Add other Nix-Darwin hosts here
    };

    # Combine all hosts
    allHosts = nixosHosts // darwinHosts;

  in
  {
    # Define the NixOS configurations for each NixOS host.
    nixosConfigurations = builtins.mapAttrs
      (hostName: hostAttrs:
        nixpkgs.lib.nixosSystem {
          inherit (hostAttrs) system;

          specialArgs = {
            inherit inputs pkgsFor hostName username;
            configDir = self; # Pass the flake directory path
            pkgs = pkgsFor hostAttrs.system; # Pass pkgs for the host's system
          };

          modules = [
            # Import the host-specific system configuration
            hostAttrs.configuration

            # Import shared system modules
            # inputs.self.modules.system.my-service # Example shared module
          ];
        }
      )
      nixosHosts; # Map only over the nixosHosts

    # Define the Nix-Darwin configurations for each Darwin host.
    darwinConfigurations = builtins.mapAttrs
      (hostName: hostAttrs:
        darwin.lib.darwinSystem {
          inherit (hostAttrs) system;

          specialArgs = {
            inherit inputs pkgsFor hostName username;
            configDir = self; # Pass the flake directory path
            pkgs = pkgsFor hostAttrs.system; # Pass pkgs for the host's system
          };

          modules = [
            # Import the host-specific system configuration
            hostAttrs.configuration

            # Import shared system modules (ensure they handle Darwin or use lib.isDarwin)
            # inputs.self.modules.system.my-service # Example shared module (needs Darwin compatibility)

            # Optional: If you have Home Manager configs that *must* be applied via the
            # Darwin system build (less common for standalone HM but possible),
            # you could import home-manager.darwinModules.home-manager here.
            # We are NOT doing this for standalone HM as requested.
          ];
        }
      )
      darwinHosts; # Map only over the darwinHosts


    # Define standalone Home Manager configurations.
    # We have one configuration for user 'alc' intended for any supported system.
    # The `pkgs` passed here is mostly for the flake evaluation context.
    # When `home-manager switch` is run on a target machine, it will use that machine's pkgs.
    homeConfigurations.${username} = home-manager.lib.homeManagerConfiguration {
      # Pass the current system's pkgs for flake evaluation context.
      # The pkgs used for package installation on the target machine
      # are implicitly determined by Home Manager when `home-manager switch` is run.
      pkgs = nixpkgs.legacyPackages.${builtins.currentSystem};

      extraSpecialArgs = {
        inherit inputs username pkgsFor;
        # Pass pkgs for the *evaluation* system. Use pkgsFor in home.nix for target-specific pkgs.
        pkgs = pkgsFor.${builtins.currentSystem};
      };

      modules = [
        # Import your user-specific home configuration
        ./users/${username}/home.nix

        # Crucially, enable the home-manager program itself
        { programs.home-manager.enable = true; }

        # Optionally, include shared Home Manager modules
        # inputs.self.modules.home.my-editor
      ];
    };

    # Add development shells for all supported systems.
    devShells = builtins.listToAttrs (map (system: {
      name = system;
      value = pkgsFor system.mkShell {
        packages = with pkgsFor system; [
          nixpkgs-fmt # Format Nix code
          alejandra # Another Nix code formatter (often preferred)
          editorconfig-checker # Check .editorconfig files
          # Add other tools useful for managing your NixOS/Darwin config here
          # Example: if you need a specific package to build something on aarch64-darwin
          # only add it here if needed for developing the *flake*, not for the target system
        ];
        shellHook = ''
          echo "Entering flake development shell for ${system}."
          echo "Useful commands:"
          echo "  NixOS system rebuild (e.g., xyz): sudo nixos-rebuild switch --flake .#xyz"
          echo "  Darwin system rebuild (e.g., mac): darwin-rebuild switch --flake .#mac"
          echo "  User rebuild (any host):   home-manager switch --flake .#${username}"
        '';
      };
    }) supportedSystems);

    # Expose custom modules for easy importing (if you create any)
    modules = {
      # System modules (might need lib.isLinux/lib.isDarwin guards internally)
      system = import ./modules/system { inherit inputs pkgsFor; };
      # Home modules (should be portable or use guards)
      home = import ./modules/home { inherit inputs pkgsFor; };
    };

  };
}

