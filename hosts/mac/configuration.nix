# hosts/mac/configuration.nix
{ config, pkgs, lib, ... }:

{
  # Import your Home Manager configuration from flake.nix
  # This line tells Nix-Darwin to include your user's Home Manager config.
  # The `home-manager.users.${username}` refers to the output from your flake.nix
  # (e.g., homeConfigurations.alc-mac in your case)
  home-manager.users.alc = { config, ... }: {
    imports = [
      # You can put basic user settings here, or just import your home-darwin.nix
      # If you uncomment this, make sure it corresponds to your desired user,
      # and that your flake.nix is setup to pass it correctly.
      # However, since you're setting up home-manager *separately* via mkHomeConfiguration,
      # you typically wouldn't put an `imports` here.
      # Instead, your `flake.nix`'s `darwin.lib.darwinSystem.modules` (for the mac host)
      # should include the `home-manager.darwinModules.home-manager` and then pass
      # the specific user config.

      # Let's check your current flake.nix's darwinSystem:
      # modules = [ hostAttrs.configuration ];
      # This means your hosts/mac/configuration.nix *is* the module being imported.
      # So, inside hosts/mac/configuration.nix, you'd enable home-manager and refer to your user config.

      # Simplified:
      # This enables the Home Manager module for Darwin, and it will look for users defined later.
      # home-manager.darwinModules.home-manager
    ];
  };

  # System-wide Nix settings
  nix = {
    package = pkgs.nix;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  # Set the hostname
  networking.hostName = "mac"; # Or "my-macbook-pro"

  # List packages installed system-wide for all users
  environment.systemPackages = with pkgs; [
    # General CLI tools available to everyone
    curl
    wget
    tmux
    git
    vim
    # Maybe some GUI apps if you want them globally available (less common for apps)
    # brave
  ];

  # macOS-specific system services (launchd)
  services.nginx.enable = lib.mkDefault false; # Example, if you ran nginx

  # macOS system defaults (defaults write commands)
  system.defaults = {
    # Finder settings
    NSGlobalDomain = {
      _HIHideMenuBar = true; # Hide the menubar (uncommon)
      AppleShowAllExtensions = true;
    };
    Finder = {
      ShowPathbar = true;
      ShowStatusBar = true;
      _FXShowPosixPathInTitle = true;
    };
    # Dock settings
    com.apple.dock = {
      autohide = true;
      # Other dock settings
    };
    # Keyboard settings
    "com.apple.keyboard.fnremap" = {
      # Custom function key remapping
    };
  };

  # Other important system settings
  programs.gnupg.agent = {
    enable = true;
    # ... other GPG agent settings, including for YubiKey
  };

  # Auto upgrade nix package and the daemon service.
  # This is crucial for managing your Nix setup itself.
  services.nix-daemon.enable = true;
  # nix.autoOptimiseStore = true; # Enables garbage collection optimization
  # nix.gc = {
  #   automatic = true;
  #   dates = "weekly";
  #   options = "--delete-older-than 7d";
  # };


  # Use your NIX_PATH
  nix.nixPath = [
    "nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos"
    "darwin-config=${config.darwin.system.build.darwinConfiguration}"
    "home-manager=${home-manager.url}" # This is needed if you refer to HM
  ];

  # Allow unfree packages, etc. (already handled in flake.nix, but good to be explicit)
  nixpkgs.config.allowUnfree = true;

  # Your system's timezone
  time.timeZone = "Europe/Oslo"; # Or your local timezone

  # Create /etc/bashrc (or similar)
  # environment.shells = with pkgs; [ bash zsh ];
  # users.users.alc.shell = pkgs.zsh;

  # Your Apple ID (needed for some services or purchases)
  # services.login-items.enable = true; # Example
  # programs.login-items.items = {
  #   "Bartender" = "/Applications/Bartender 4.app";
  # };

  # Required for some setups, often for Rosetta 2 on M1/M2 Macs
  # system.apply-darwin-paths = true;

  # Auto-build and apply configuration on channel update (similar to NixOS auto-switch)
  system.auto-upgrade.enable = true;
  system.auto-upgrade.dates = "daily";

  # Set the default shell for new users (if not explicitly set per user)
  # environment.defaultUserShell = pkgs.zsh; # Needs to be defined in environment.shells

  # Fonts
  # fonts.fontDir.enable = true;
  # fonts.fonts = with pkgs; [
  #   fira-code-nerd-font
  # ];

  # For virtualisation/containers like Docker Desktop (requires certain permissions/settings)
  # virtualisation.docker.enable = true;


  # Add support for on-disk Nix store (if you're using /nix instead of /Users/youruser/.nix-profile)
  # You already have this in your flake, but if you needed a separate nix path, this is where
  # you'd define it if it's system wide.
  # nix.buildMachines = []; # if you use remote builders

  # Add ability to use 'nix-channel --update' for non-flakes setups (less relevant with flakes)
  # nix.extraOptions = "build-users-group = nixbld"; # Example for multi-user
}
