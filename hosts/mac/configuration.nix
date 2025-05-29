# hosts/mac/configuration.nix
{ config, pkgs, lib, inputs, username, ... }:

{
  # ============================================================================
  # Nix Configuration
  # ============================================================================
  
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
    systemPackages = with pkgs; [
      git
      curl
      wget
      htop
      btop
      fd
      ripgrep
      fzf
      tmux
      zsh
      direnv
      vim
      glow
      sshs
      neofetch
    ];
    
    shells = with pkgs; [ bash zsh ];
    
    variables = {
      EDITOR = "vim";
    };
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
      KeyRepeat = 2;
      InitialKeyRepeat = 15;
      PMPrintingExpandedStateForPrint = true;
      PMPrintingExpandedStateForPrint2 = true;
      "com.apple.swipescrolldirection" = true;
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
    };

    dock = {
      autohide = true;
      autohide-delay = 0.0;
      autohide-time-modifier = 0.2;
      expose-animation-duration = 0.1;
      launchanim = false;
      magnification = false;
      minimize-to-application = true;
      mineffect = "scale";
      orientation = "bottom";
      show-process-indicators = true;
      show-recents = false;
      static-only = true;
      tilesize = 44;
    };

    trackpad = {
      Clicking = true;
      TrackpadThreeFingerDrag = true;
    };

    screencapture = {
      disable-shadow = true;
      location = "~/Pictures/Screenshots";
      type = "png";
    };

    ActivityMonitor = {
      IconType = 2;
      SortColumn = "CPUUsage";
      SortDirection = 0;
    };

    menuExtraClock = {
      Show24Hour = true;
      ShowSeconds = false;
    };

    loginwindow = {
      GuestEnabled = false;
      SHOWFULLNAME = false;
      LoginwindowText = "Those who would give up essential Liberty, to purchase a little temporary Safety, deserve neither Liberty nor Safety.";
    };

    screensaver = {
      askForPasswordDelay = 10;
    };

    CustomUserPreferences = {
      /*
      "com.apple.Safari" = {
        AutoOpenSafeDownloads = false;
        IncludeDevelopMenu = true;
        ShowFullURLInSmartSearchField = true;
        WebKitDeveloperExtrasEnabledPreferenceKey = true;
      };
      */
      
      "com.apple.finder" = {
        FXDesktopExtFoldersOnDesktop = false;
        FXDesktopCdRemovableDisksOnDesktop = false;
        FXDesktopDevicesOnDesktop = false;
        FXDesktopServersOnDesktop = false;
      };
    };
  };

  # ============================================================================
  # Security
  # ============================================================================
  
  security.pam.services.sudo_local.touchIdAuth = true;

  # ============================================================================
  # Fonts (Updated for new nerd-fonts structure)
  # ============================================================================
  
  fonts.packages = with pkgs; [
    # Individual nerd font packages (new syntax)
    nerd-fonts.fira-code
    nerd-fonts.droid-sans-mono
    nerd-fonts.hack
    
    # Or if you want all nerd fonts (uncomment the line below)
    # ] ++ builtins.filter lib.attrsets.isDerivation (builtins.attrValues pkgs.nerd-fonts);
  ];

  # ============================================================================
  # System State Version
  # ============================================================================
  
  system.stateVersion = 4;
}
