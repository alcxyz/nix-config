# hosts/mac/configuration.nix
# This file configures the macOS system itself using Nix-Darwin.
# It does NOT directly manage Home Manager or user-specific dotfiles.
{ config, pkgs, lib, inputs, ... }: # Ensure 'inputs' is passed if you need to reference other flake inputs

{
  # 1. Core Nix-Darwin & Nix settings
  # Enable the Nix daemon (essential for Nix to work properly on macOS)
  services.nix-daemon.enable = true;

  # Enable automatic garbage collection and store optimization (recommended)
  nix.autoOptimiseStore = true;
  nix.gc = {
    automatic = true;
    dates = "weekly"; # Or "daily", "monthly" etc.
    options = "--delete-older-than 7d"; # Keep 7 days of generations
  };

  # Configure Nix experimental features (essential for flakes)
  nix.extraOptions = ''
    experimental-features = nix-command flakes
    keep-derivations = true # Good for debugging if something breaks
    keep-outputs = true     # Good for debugging
  '';

  # Set the NIX_PATH, though less critical with flakes, still good practice
  nix.nixPath = [
    "nixpkgs=${pkgs.path}" # Current nixpkgs being used
    "darwin-config=${config.darwin.system.build.darwinConfiguration}"
    # No need to reference home-manager here, as it's separate.
  ];

  # Allow unfree packages (already in your flake.nix, but harmless to repeat)
  nixpkgs.config.allowUnfree = true;

  # Auto upgrade Nix package and the daemon service (keeps Nix itself updated)
  system.auto-upgrade.enable = true;
  system.auto-upgrade.dates = "daily"; # Or "weekly"

  # 2. System Information
  # Set the hostname
  networking.hostName = "mac";

  # Set the system timezone
  time.timeZone = "Europe/Oslo";

  # 3. System-Wide Environment and Packages
  # List packages to be installed globally on the system (available to all users)
  # These are generally CLI tools or applications that don't have user-specific configs.
  environment.systemPackages = with pkgs; [
    # Common command-line tools
    git # Git will be system-wide here, but home-manager will manage your git config.
    wget
    curl
    htop
    neofetch
    tmux
    zsh # To make Zsh available as a system shell (often default on macOS anyway)
    vim
    direnv
    sshs
    glow
    # Any other system-wide tools
    # fzf # if you want it globally available
    # ripgrep
    # fd
  ];

  # Define system shells (optional, Zsh is often default on modern macOS)
  # environment.shells = with pkgs; [ bash zsh ];
  # environment.defaultUserShell = pkgs.zsh; # Sets default for *new* users.

  # 4. macOS System Defaults (using `system.defaults`)
  # These map to `defaults write` commands and apply system-wide.
  system.defaults = {
    # Global domain settings
    NSGlobalDomain = {
      # Show all filename extensions
      AppleShowAllExtensions = true;
      loginwindow.LoginwindowText = "Those who would give up essential Liberty, to purchase a little temporary Safety, deserve neither Liberty nor Safety.";
      # Disable the "Are you sure you want to open this application?" dialog
      # This can be risky if you download untrusted software!
      # com.apple.LaunchServices.LSQuarantine = false;
      # Set a faster keyboard repeat rate
      KeyRepeat = 2;       # default: 6 (2-30 range)
      InitialKeyRepeat = 15; # default: 60 (15-120 range)
    };

    # Finder settings
    Finder = {
      # Show hidden files (dotfiles) by default
      AppleShowAllFiles = true;
      # Show path bar in Finder windows
      ShowPathbar = true;
      # Show status bar in Finder windows
      ShowStatusBar = true;
      # Use POSIX path in Finder title bar (instead of macOS default)
      _FXShowPosixPathInTitle = true;
      # Keep folders on top when sorting by name in Finder
      _FXSortFoldersFirst = true;
    };

    # Dock settings
    "com.apple.dock" = {
      autohide = true; # Automatically hide and show the Dock
      #orientation = "left"; # Position the Dock on the left
      magnification = true; # Disable magnification
      tilesize = 36; # Set a smaller icon size
      # Enable "minimize windows into application icon"
      # This is usually managed by Home Manager `programs.dock.pinning` option if enabled
      # show-process-indicators = false; # Do not show indicator lights for open applications
    };

    # Screenshot settings
    "com.apple.screencapture" = {
      location = "${config.home.homeDirectory}/Pictures/Screenshots"; # Requires creating this dir
      type = "png"; # Or "jpg", "pdf", etc.
      # You might also want to set: `disable-shadow = true;`
    };

    # Disks: Do not show external drives, CDs, DVDs, iPods, and servers on the desktop
    "com.apple.finder.FXDesktopExtFoldersOnDesktop" = false;
    "com.apple.finder.FXDesktopCdRemovableDisksOnDesktop" = false;
    "com.apple.finder.FXDesktopDevicesOnDesktop" = false;
    "com.apple.finder.FXDesktopServersOnDesktop" = false;

    # Safari (example, if you use it and want system defaults)
    # com.apple.Safari = {
    #   "ShowFullURLInSmartSearchField" = true; # Show full URL
    #   "PreventSafariFromOpeningNewWindowsDueToJavaScriptAlerts" = true;
    # };

    # Others as needed
  };

  # 5. Services (Nix-Darwin specific system-level services)
  # Examples:
  # services.openssh.enable = true; # If you want system-wide SSH server
  # services.caffeinate.enable = true; # Prevent display sleep
  # services.skhd.enable = true; # If you prefer skhd as a system service rather than user
  # services.yabai.enable = true; # If you prefer yabai as a system service rather than user
  # You can keep `programs.gnupg.agent.enable = true;` here if you want the GPG agent
  # to be a system-wide service, rather than just user-level from Home Manager.
  # Otherwise, move it to common.nix.
  programs.gnupg.agent = {
    enable = true;
    pinentryFlavor = "mac"; # Use macOS native pinentry
    enableSSHSupport = true;
  };

  # 6. Security & Privacy (Advanced - use with caution)
  # E.g., firewall settings, or permissions.
    security.pam.enableSudoTouchIdAuth = true;
  # security.allowApplicationsFrom = "appStoreAndIdentifiedDevelopers"; # Default
  # security.auditd.enable = true;

  # 7. Font Management (system-wide font directories)
  # fonts.fontDir.enable = true;
  # fonts.fonts = with pkgs; [
  #   fira-code-nerd-font # Example, to install system-wide fonts
  #   font-symbols-only-nerd-font
  # ];

  # 8. User Management (if you define system users beyond the one Home Manager manages)
  # users.users.alc.shell = pkgs.zsh; # Set the default shell for the 'alc' user on the system
  # users.users.alc.home = "/Users/alc"; # Ensure correct home directory for user
  # users.users.alc.extraGroups = [ "wheel" "staff" ]; # Add user to groups
  # If you *already* have this user, you might not need to define it here explicitly,
  # or you'd only set specific attributes.

  # 9. Miscellaneous (Optional, depending on your needs)
  # virtualisation.docker.enable = true; # For Docker Desktop integration (requires system-level config)
  # boot.cleanBoot = true; # Tries to keep boot process clean, experimental
}
