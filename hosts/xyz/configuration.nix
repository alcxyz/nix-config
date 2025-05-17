{ config, pkgs, inputs, username, hostName, configDir, ... }:

{
  # ==================== Imports ====================
  imports = [
    ./hardware-configuration.nix

    # Import the base system configuration module which collects other system modules
    ../../modules/system/default.nix

    # Import other system suites
    ../../modules/system/suites/lab/default.nix
    ../../modules/system/suites/desktop/default.nix

    # Import hardware-specific modules
    ../../modules/system/hardware/nvidia.nix

    # Import system service modules that are enabled directly in the host config
    ../../modules/system/services/zfs/default.nix

    # Import additional system programs and services that are enabled directly in the host config
    ../../modules/system/programs/gnupg/default.nix
    ../../modules/system/services/calibre-web/default.nix
    ../../modules/system/services/deluge/default.nix
    ../../modules/system/services/kanata/default.nix
    ../../modules/system/services/nfs/default.nix
    ../../modules/system/services/samba/default.nix

    # Import the new system suite for Hyprland packages
    ../../modules/system/suites/hyprland/default.nix

    # Import the KVM system module
    ../../modules/system/virtualisation/kvm
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
    extraGroups = [ "networkmanager" "wheel" "nixbld" "vfio" "audio" "sound" "video" "input" "tty" "docker" "podman" ];
    packages = with pkgs; [
      # Add any packages you want available to this user system-wide
    ];
  };

  # Configure root user's shell
  users.users.root.shell = pkgs.bashInteractive;

  # Set the system-wide default shell for new users
  users.defaultUserShell = pkgs.nushell;

  # === Environment and Base Packages ===

  # System-wide environment packages
  environment.systemPackages = with pkgs; [
    bat
    nitch
    glow
  ];

  # System-wide shell aliases
  environment.shellAliases = {
    nixyz = "nixos-rebuild switch --flake .#xyz";
    # Retained the sudo alias which was present in the original file
    sudo = "doas";
  };

  # Locale configuration
  i18n.defaultLocale = "en_US.UTF-8";

  # Time configuration
  time.timeZone = "Europe/Oslo";

  # XKB configuration
  console.useXkbConfig = true;
  services.xserver.xkb = {
    layout = "no";
  };

  # === Security ===

  # Doas configuration
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

  # Enable the consolidated system module which imports submodules
  system.enable = true;

  # Enable other suites
  suites.lab.enable = false;
  suites.desktop.enable = false;
  suites.hyprland.enable = true;

  # Enable the KVM system module
  virtualisation.kvm-system.enable = true;


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
  services.zfs.enable = true;
  services.nfs.enable = true;
  services.samba.enable = true;
  programs.gnupg.enable = true;
  programs.dconf.enable = true;


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
