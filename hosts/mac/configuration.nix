# hosts/mac/configuration.nix
{ config, pkgs, lib, inputs, configDir, username, hostInventory, ... }:

let
  pkgsets = import "${configDir}/modules/nixos/common/pkgsets.nix" {
    inherit pkgs inputs;
  };
  networkName = hostInventory.darwinNetworkName or "mac";

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
      # Only free space, never delete profile generations.
      # Profile generations are managed explicitly via: nix-env --delete-generations +5
      options = "--max-freed 10G";
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
    hostName = networkName;
    computerName = networkName;
    localHostName = networkName;
  };

  services.openssh.enable = true;

  # ============================================================================
  # Netbird — mesh VPN client
  # ============================================================================
  launchd.daemons.netbird = {
    serviceConfig = {
      ProgramArguments = [
        "${pkgs.netbird}/bin/netbird"
        "service"
        "run"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "/var/log/netbird.log";
      StandardErrorPath = "/var/log/netbird.log";
      EnvironmentVariables = {
        NB_CONFIG = "/var/lib/netbird/config.json";
        NB_LOG_FILE = "console";
      };
    };
  };

  # Keyboard remapping: Karabiner Elements (brew cask), config managed
  # declaratively via home-manager — see ADR-0011.

  time.timeZone = "Europe/Oslo";

  # ============================================================================
  # Primary User (Required for system defaults)
  # ============================================================================
  system.primaryUser = username;

  # ============================================================================
  # System Packages
  # ============================================================================
  environment = {
    systemPackages = pkgsets.system.mac ++ [ pkgs.netbird ];
    shells = with pkgs; [ bash zsh nushell ];
    variables = { EDITOR = "nvim"; };
  };

  # Homebrew is used for macOS tools that are not available in nixpkgs.
  homebrew = {
    enable = true;
    brews = [ ];
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

    spaces = {
      # Required by Paneru. In the underlying plist, false means macOS
      # "Displays have separate Spaces" is enabled. Requires logout/login.
      spans-displays = false;
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
      # Disable Spotlight keyboard shortcut so Raycast can use Cmd+Space
      "com.apple.symbolichotkeys" = {
        AppleSymbolicHotKeys = {
          # 64 = Spotlight search, 65 = Finder search window (Cmd+Option+Space)
          "64" = { enabled = false; };
          "65" = { enabled = false; };
        };
      };

      ".GlobalPreferences" = {
        NSUserKeyEquivalents = {
          "Hide Others" = "";
          "Minimize All" = "";
        };
      };

      "com.t3tools.t3code" = {
        NSUserKeyEquivalents = {
          "Hide Others" = "";
          "Hide T3 Code (Alpha)" = "";
          "Hide T3 Code" = "";
          "Minimize All" = "";
        };
      };

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
    # Default: common secrets for all hosts
    #defaultSopsFile = "${inputs.nix-secrets.secrets.files.shared}";

    # Add host‑specific secrets file
    #secretsFiles = [ "${inputs.nix-secrets.secrets.files.hosts.mac}" ];

    # On macOS, sops-nix expects a single key path
    #age.keyFile = "/etc/ssh/ssh_host_ed25519_key";

    # Define system secrets (example)
    secrets = {
      # sample placeholder
      # home_manager_api_key = {
      #   owner = "alc";
      # };
    };
  };

  # ============================================================================
  # Fonts
  # ============================================================================
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    nerd-fonts.fira-code
    nerd-fonts.droid-sans-mono
    nerd-fonts.hack
  ];

  # ============================================================================
  # Spotlight
  # ============================================================================
  # Disable Spotlight entirely — using Raycast as a replacement.
  system.activationScripts.postActivation.text = ''
    mdutil -a -i off 2>/dev/null || true
  '';

  # ============================================================================
  # System State Version
  # ============================================================================
  system.stateVersion = 4;
}
