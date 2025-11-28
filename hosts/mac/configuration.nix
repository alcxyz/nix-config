# hosts/mac/configuration.nix
{ config, pkgs, lib, inputs, username, ... }:

let
  # Define common trackpad settings using actual plist key names
  customTrackpadSettings = {
    # --- General ---
    Clicking = true; # Tap to click
    TrackpadRightClick = true; # Secondary click (e.g., two-finger click)

    # --- Scroll & Zoom ---
    TrackpadMomentumScroll = true; # Smooth scrolling
    TrackpadPinch = true;          # Pinch to zoom
    TrackpadRotate = true;         # Rotate gesture

    # --- Page Navigation ---
    # Two-finger swipe left/right to navigate pages
    TrackpadScrollToNextOrPreviousPageGesture = true;

    # --- Multi-Finger Swipes ---
    # Three-finger horizontal swipe: Swipe between full-screen apps
    TrackpadThreeFingerHorizSwipeGesture = 2;
    # Three-finger vertical swipe: Mission Control (up) & App Exposé (down)
    TrackpadThreeFingerVertSwipeGesture = 2;

    # --- Three Finger Drag ---
    # Disable Three Finger Drag to allow three-finger swipes to work
    TrackpadThreeFingerDrag = false;
    # Enable standard click-and-drag (press, hold, move)
    TrackpadDragging = true;

    # --- Other Tap Gestures (Examples) ---
    # TrackpadThreeFingerTapGesture = 2; # Look up & data detectors
    # TrackpadFourFingerTapGesture = 0; # Off
  };
 
  pkgsets = import ../../modules/pkgsets.nix { inherit pkgs inputs; };
in
{
  # ============================================================================
  # Nix Configuration
  # ============================================================================
  # ... (rest of your Nix configuration remains the same) ...
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      keep-derivations = true;
      keep-outputs = true;
      trusted-users = [ "root" "@admin" ];

      substituters = [
        "https://cache.nixos.org/"
        "https://nix-community.cachix.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };

    gc = {
      automatic = true;
      interval = { Weekday = 0; Hour = 2; Minute = 0; };
      options = "--delete-older-than 30d";
    };

    optimise = {
      automatic = true;
      interval = { Weekday = 0; Hour = 3; Minute = 0; };
    };
  };

  nixpkgs.config.allowUnfree = true;

  # ============================================================================
  # System Information
  # ============================================================================
  networking = {
    hostName = "mac";
    computerName = "mac";
    localHostName = "mac";
  };

  time.timeZone = "Europe/Oslo";

  # ============================================================================
  # Primary User (Required for system defaults)
  # ============================================================================
  system.primaryUser = username;

  # ============================================================================
  # System Packages
  # ============================================================================
  environment = {
    systemPackages = pkgsets.system.mac;
    shells = with pkgs; [ bash zsh nushell ];
    variables = { EDITOR = "nvim"; };
  };

  # ============================================================================
  # Programs
  # ============================================================================
  programs = {
    zsh.enable = true;

    gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
    };
  };

  # ============================================================================
  # System Defaults
  # ============================================================================
  system.defaults = {
    NSGlobalDomain = {
      AppleInterfaceStyle = "Dark";
      AppleShowAllExtensions = true;
      AppleICUForce24HourTime = true;
      KeyRepeat = 2;
      InitialKeyRepeat = 15;
      PMPrintingExpandedStateForPrint = true;
      PMPrintingExpandedStateForPrint2 = true;
      "com.apple.swipescrolldirection" = true; # Natural scrolling
    };

    finder = {
      AppleShowAllExtensions = true;
      AppleShowAllFiles = true;
      CreateDesktop = false;
      ShowPathbar = true;
      ShowStatusBar = true;
      _FXShowPosixPathInTitle = true;
      _FXSortFoldersFirst = true;
      FXDefaultSearchScope = "SCcf";
      FXEnableExtensionChangeWarning = false;
      # Consider moving FXDesktop... settings from CustomUserPreferences here for consolidation
    };

    dock = {
      autohide = true;
      autohide-delay = 0.0;
      autohide-time-modifier = 0.2;
      expose-animation-duration = 0.1;
      launchanim = false;
      magnification = true;
      minimize-to-application = true;
      mineffect = "scale";
      orientation = "bottom";
      show-process-indicators = true;
      show-recents = false;
      static-only = true;
      tilesize = 44;
    };

    # We will NOT use the `system.defaults.trackpad` alias here to avoid key name mismatches.
    # Instead, we'll set all trackpad preferences via CustomUserPreferences below,
    # using the actual plist key names defined in `customTrackpadSettings`.
    # Your original minimal trackpad settings were:
    # trackpad = {
    #   Clicking = true;
    #   TrackpadThreeFingerDrag = true;
    # };
    # These keys ARE valid for the alias, but our `customTrackpadSettings` is more comprehensive
    # and includes keys not directly aliased or aliased with different names.

    screencapture = {
      disable-shadow = true;
      location = "/Users/${username}/Pictures/Screenshots";
      type = "png";
    };

    ActivityMonitor = {
      IconType = 2;
      SortColumn = "CPUUsage";
      SortDirection = 0;
    };

    menuExtraClock = {
      Show24Hour = true;
      ShowSeconds = true;
    };

    loginwindow = {
      GuestEnabled = false;
      SHOWFULLNAME = true;
      LoginwindowText = "Those who would give up essential Liberty, to purchase a little temporary Safety, deserve neither Liberty nor Safety.";
    };

    screensaver = {
      askForPasswordDelay = 10;
    };

    CustomUserPreferences = {
      # Your existing Safari preferences (if you uncomment them)
      /*
      "com.apple.Safari" = {
        AutoOpenSafeDownloads = false;
        IncludeDevelopMenu = true;
        ShowFullURLInSmartSearchField = true;
        WebKitDeveloperExtrasEnabledPreferenceKey = true;
      };
      */

      # Your existing Finder preferences (consider merging into the main `finder` block above)
      "com.apple.finder" = {
        FXDesktopExtFoldersOnDesktop = false;
        FXDesktopCdRemovableDisksOnDesktop = false;
        FXDesktopDevicesOnDesktop = false;
        FXDesktopServersOnDesktop = false;
      };

      # Configure built-in trackpad using actual plist keys
      "com.apple.AppleMultitouchTrackpad" = customTrackpadSettings;

      # Configure Bluetooth trackpads (e.g., Magic Trackpad) using actual plist keys
      "com.apple.driver.AppleBluetoothMultitouch.trackpad" = customTrackpadSettings;
    };
  };

  # ============================================================================
  # Security
  # ============================================================================
  security.pam.services.sudo_local.touchIdAuth = true;

  security.sudo.extraConfig = ''
    # Define the secure execution path for sudo
    # It's important to include the standard system paths
    # as well as the path for Nix-Darwin system applications.
    Defaults secure_path="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/run/current-system/sw/bin"
  '';

  sops = {
    defaultSopsFile = inputs.nix-secrets + "/secrets.yaml";
    # Note: nix-darwin uses `keyFile` (string) instead of `sshKeyPaths` (list)
    age.keyFile = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets = {
      # Define any secrets needed for your mac user here
      # For example:
      # home_manager_api_key = {};
    };
  };

  # ============================================================================
  # Fonts
  # ============================================================================
  fonts.packages = with pkgs; [
    nerd-fonts.fira-code
    nerd-fonts.droid-sans-mono
    nerd-fonts.hack
  ];

  # ============================================================================
  # System State Version
  # ============================================================================
  system.stateVersion = 4;
}
