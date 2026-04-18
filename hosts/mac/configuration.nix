# hosts/mac/configuration.nix
{ config, pkgs, lib, inputs, configDir, username, ... }:

let
  pkgsets = import "${configDir}/modules/nixos/common/pkgsets.nix" {
    inherit pkgs inputs;
  };

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

  services.openssh.enable = true;

  # ============================================================================
  # Keyboard Remapping (kanata) — see ADR-0011
  # ============================================================================
  launchd.daemons.kanata-mac-builtin = {
    serviceConfig = {
      ProgramArguments = [
        "${pkgs.kanata}/bin/kanata"
        "--cfg"
        "${configDir}/users/${username}/configs/kanata/kanata-mac-builtin.kbd"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 10;
      StandardOutPath = "/var/log/kanata-mac-builtin.log";
      StandardErrorPath = "/var/log/kanata-mac-builtin.log";
    };
  };

  # ============================================================================
  # Window Management (yabai + skhd)
  # ============================================================================
  services.yabai = {
    enable = true;
    config = {
      layout = "bsp";
      window_placement = "second_child";

      top_padding    = 8;
      bottom_padding = 8;
      left_padding   = 8;
      right_padding  = 8;
      window_gap     = 8;

      mouse_follows_focus = "on";
      mouse_modifier      = "cmd";
      mouse_action1       = "move";
      mouse_action2       = "resize";
      mouse_drop_action   = "swap";

      auto_balance = "off";
      split_ratio  = 0.5;
    };
    extraConfig = ''
      # Float rules — apps that shouldn't tile
      yabai -m rule --add app="^System Settings$" manage=off
      yabai -m rule --add app="^Calculator$" manage=off
      yabai -m rule --add app="^Activity Monitor$" manage=off
      yabai -m rule --add app="^Raycast$" manage=off
      yabai -m rule --add app="^Finder$" title="(Copy|Bin|Trash|Connect)" manage=off
    '';
  };

  services.skhd = {
    enable = true;
    skhdConfig = ''
      # ═══════════════════════════════════════════════════════════
      # skhd bindings — matching Hyprland (SUPER = cmd)
      # ═══════════════════════════════════════════════════════════

      # ── Focus windows (SUPER + hjkl) ──
      cmd - h : yabai -m window --focus west
      cmd - j : yabai -m window --focus south
      cmd - k : yabai -m window --focus north
      cmd - l : yabai -m window --focus east

      # ── Swap windows (SUPER + SHIFT + hjkl) ──
      shift + cmd - h : yabai -m window --swap west
      shift + cmd - j : yabai -m window --swap south
      shift + cmd - k : yabai -m window --swap north
      shift + cmd - l : yabai -m window --swap east

      # ── Resize (SUPER + ALT + hjkl) ──
      cmd + alt - h : yabai -m window --resize left:-50:0
      cmd + alt - j : yabai -m window --resize bottom:0:50
      cmd + alt - k : yabai -m window --resize top:0:-50
      cmd + alt - l : yabai -m window --resize right:50:0

      # ── Window actions ──
      cmd - w : yabai -m window --close
      cmd - t : yabai -m window --toggle float --grid 4:4:1:1:2:2
      cmd - return : yabai -m window --toggle zoom-fullscreen

      # ── Focus space (SUPER + number) ──
      cmd - 1 : yabai -m space --focus 1
      cmd - 2 : yabai -m space --focus 2
      cmd - 3 : yabai -m space --focus 3
      cmd - 4 : yabai -m space --focus 4
      cmd - 5 : yabai -m space --focus 5
      cmd - 6 : yabai -m space --focus 6
      cmd - 7 : yabai -m space --focus 7
      cmd - 8 : yabai -m space --focus 8
      cmd - 9 : yabai -m space --focus 9

      # ── Move window to space (SUPER + CTRL + number) ──
      ctrl + cmd - 1 : yabai -m window --space 1; yabai -m space --focus 1
      ctrl + cmd - 2 : yabai -m window --space 2; yabai -m space --focus 2
      ctrl + cmd - 3 : yabai -m window --space 3; yabai -m space --focus 3
      ctrl + cmd - 4 : yabai -m window --space 4; yabai -m space --focus 4
      ctrl + cmd - 5 : yabai -m window --space 5; yabai -m space --focus 5
      ctrl + cmd - 6 : yabai -m window --space 6; yabai -m space --focus 6
      ctrl + cmd - 7 : yabai -m window --space 7; yabai -m space --focus 7
      ctrl + cmd - 8 : yabai -m window --space 8; yabai -m space --focus 8
      ctrl + cmd - 9 : yabai -m window --space 9; yabai -m space --focus 9

      # ── Previous space (SUPER + TAB) ──
      cmd - tab : yabai -m space --focus recent

      # ── Balance layout ──
      shift + cmd - 0 : yabai -m space --balance

      # ── Mouse: move/resize (SUPER + drag) ──
      # (handled by yabai config mouse_modifier = cmd)

      # ── Quake-style WezTerm toggle ──
      alt - space : ~/nix/nix-config/users/alc/configs/skhd/toggle-wezterm

      # ── Terminal (ALT + RETURN, like Hyprland) ──
      alt - return : open -a WezTerm
    '';
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
      # Disable Spotlight keyboard shortcut so Raycast can use Cmd+Space
      "com.apple.symbolichotkeys" = {
        AppleSymbolicHotKeys = {
          # 64 = Spotlight search, 65 = Finder search window
          "64" = { enabled = false; };
          "65" = { enabled = false; };
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
