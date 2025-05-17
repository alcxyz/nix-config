{ config, pkgs, inputs, username, hostName, configDir, ... }:

{
  # ==================== Imports ====================
  imports = [
    # Import base NixOS configuration modules here
    # For example, a minimal setup might need networking, users, etc.
    # <nixpkgs/nixos/modules/services/networking/networkmanager.nix>
    # <nixpkgs/nixos/modules/system/boot/loader/systemd-boot/systemd-boot.nix>
    # <nixpkgs/nixos/modules/system/etc/passwd.nix>
    ./modules/system/suites/common/default.nix
    ./modules/system/suites/lab/default.nix
    ./modules/system/suites/desktop/default.nix
    ./modules/system/hardware/nvidia.nix

    # Import system service modules
    ./modules/system/services/ssh/default.nix
    ./modules/system/services/zfs/default.nix # Import the new ZFS service module

    # Import additional system programs and services
    ./modules/system/programs/gnupg/default.nix
    ./modules/system/services/calibre-web/default.nix
    ./modules/system/services/deluge/default.nix
    ./modules/system/services/kanata/default.nix
    ./modules/system/services/nfs/default.nix
    ./modules/system/services/samba/default.nix

    # Import the new system suite for Hyprland packages
    ./modules/system/suites/hyprland/default.nix

    # Import the Nix configuration module
    ./modules/system/nix/default.nix
  ];

  # ==================== System Configuration ====================

  # Define the hostname using the specialArgs passed from the flake
  networking.hostName = hostName;

  # Set your system state version. This determines the compatibility of your system configuration.
  # It's recommended to set this to the NixOS version you initially install.
  system.stateVersion = "24.11"; # Replace with your desired version (e.g., "24.05")

  # Enable the Nix daemon (usually enabled by default, but good to be explicit)
  nix.daemon.enable = true;


  # === Basic System Setup ===

  # Configure bootloader (example: systemd-boot)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # === Users and Shells ===

  # Configure users (example: using the username from specialArgs)
  users.users.${username} = {
    isNormalUser = true;
    extraGroups = [ "networkmanager" "wheel" ]; # Add your user to necessary groups
    packages = with pkgs; [
      # Add any packages you want available to this user system-wide
    ];
  };

  # Configure root user's shell
  users.users.root.shell = pkgs.bashInteractive;

  # Set the system-wide default shell for new users
  users.defaultUserShell = pkgs.nushell;

  # === Environment and Base Packages ===

  # System-wide environment packages (integrated from system shell module)
  environment.systemPackages = with pkgs; [
    bat # Generally useful system-wide
    nitch # Generally useful system-wide
    glow # Generally useful system-wide
  ];

  # System-wide shell aliases (integrated from system shell module)
  environment.shellAliases = {
    nixyz = "nixos-rebuild switch --flake .#xyz";
    # Retained the sudo alias which was present in the original file
    sudo = "doas";
  };

  # Locale configuration (integrated from system locale module)
  i18n.defaultLocale = "en_US.UTF-8";

  # Time configuration (integrated from system time module)
  time.timeZone = "Europe/Oslo";

  # XKB configuration (integrated from system xkb module)
  console.useXkbConfig = true;
  services.xserver.xkb = {
    layout = "no";
    #xkbOptions = "caps:escape";
  };

  # === Security ===

  # Doas configuration (integrated from system security doas module)
  security.sudo.enable = false;
  security.doas = {
    enable = true;
    extraRules = [
      {
        users = [config.user.name];
        noPass = true;
        keepEnv = true;
      }
    ];
  };

  # === Services and Features (Enabled via Imports) ===
  # Services and features are typically enabled within the modules they are defined in,
  # or enabled here if they are standard NixOS options not part of a custom module.
  # The suites below enable groups of modules.

  # === Suites ===

  # Enable suites
  suites.common.enable = true;
  suites.lab.enable = false;
  suites.desktop.enable = false;
  suites.hyprland.enable = true; # Enable the new Hyprland system suite


  # ==================== Hardware Specific ====================

  # Enable Nvidia hardware configuration
  hardware.nvidia.enable = true;


  # ==================== Networking Specific ====================

  # Host-specific networking configuration
  networking = {
    networkmanager.enable = true;
    hostId = "4e7ded69";
    bridges.br0.interfaces = [ "enp7s0" ];
    interfaces = {
      enp6s0 = {
        useDHCP = true;
      };
      enp7s0 = {
        useDHCP = false;
      };
      br0 = {
        useDHCP = false;
      };
    };
  };

  # ==================== Other Programs/Services ====================

  # Enable additional system services and programs (enabled individually)
  services.calibre-web.enable = true;
  services.deluge.enable = true;
  services.kanata.enable = true;
  services.nfs.enable = true;
  services.samba.enable = true;
  programs.gnupg.enable = true;


  # ==================== Home Manager Configuration ====================

  # Home Manager configuration for the user
  home-manager.users.${username} = {
    imports = [
      # Import your main home configuration
      ./users/${username}/home.nix

      # Import the user-specific shell configuration
      ./modules/home/shell
    ];

    # Other user-specific configurations...
  };
}
