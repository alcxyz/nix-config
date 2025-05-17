# hosts/xyz/configuration.nix
{ config, pkgs, inputs, username, hostName, configDir, lib, ... }:

{
  # ==================== Imports ====================
  imports = [
    ./hardware-configuration.nix # Host-specific hardware

    # Import system suites using configDir for robust paths from flake root
    "${configDir}/modules/system/suites/lab/default.nix"
    "${configDir}/modules/system/suites/desktop/default.nix"
    "${configDir}/modules/system/suites/hyprland/default.nix"

    # Import hardware-specific modules
    "${configDir}/modules/system/hardware/nvidia.nix"

    # Import system service modules
    "${configDir}/modules/system/services/zfs/default.nix" # Make sure networking.hostId is NOT in here
    "${configDir}/modules/system/services/calibre-web/default.nix"
    "${configDir}/modules/system/services/deluge/default.nix"
    "${configDir}/modules/system/services/kanata/default.nix"
    "${configDir}/modules/system/services/nfs/default.nix"
    "${configDir}/modules/system/services/samba/default.nix"

    # Import additional system programs
    "${configDir}/modules/system/programs/gnupg/default.nix"

    # Import KVM system module
    "${configDir}/modules/system/virtualisation/kvm/default.nix" # Assuming default.nix is the entry
  ];

  # NOTE: The import of ../../modules/system/default.nix has been REMOVED
  # because self.modules.system (which is that file) is now included
  # in the modules list in your flake.nix for this host.

  # ==================== System Configuration ====================
  networking.hostName = hostName; # Set by specialArgs
  system.stateVersion = "24.11";
  nix.daemon.enable = true;

  # === Basic System Setup ===
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # === Users and Shells ===
  users.users.${username} = {
    isNormalUser = true;
    extraGroups = [ "networkmanager" "wheel" "nixbld" "vfio" "audio" "sound" "video" "input" "tty" "docker" "podman" ];
  };
  users.users.root.shell = pkgs.bashInteractive;
  users.defaultUserShell = pkgs.nushell;

  # === Environment and Base Packages ===
  environment.systemPackages = with pkgs; [ bat nitch glow ];
  environment.shellAliases = {
    nixyz = "nixos-rebuild switch --flake .#xyz";
    sudo = "doas";
  };

  i18n.defaultLocale = "en_US.UTF-8";
  time.timeZone = "Europe/Oslo";
  console.useXkbConfig = true;
  services.xserver.xkb = { layout = "no"; };

  # === Security ===
  security.sudo.enable = false;
  security.doas = {
    enable = true;
    extraRules = [{
      users = [ username ]; # Use the username variable
      noPass = true;
      keepEnv = true;
    }];
  };

  # === Services and Features (Enabled via Options from Modules) ===

  # Enable the base system configurations from self.modules.system
  system.enable = true; # This option is defined in modules/system/default.nix

  # Enable other suites (options defined in their respective suite modules)
  suites.lab.enable = false;
  suites.desktop.enable = false;
  suites.hyprland.enable = true;

  # Enable KVM (option defined in modules/system/virtualisation/kvm/default.nix)
  virtualisation.kvm-system.enable = true; # Ensure your KVM module defines this option path

  # ==================== Hardware Specific ====================
  hardware.nvidia.enable = true; # Option from modules/system/hardware/nvidia.nix

  # ==================== Networking Specific ====================
  networking.networkmanager.enable = true;
  networking.hostId = "4e7ded69"; # Crucial: Host-specific, keep it here.
  networking.bridges.br0.interfaces = [ "enp7s0" ];
  networking.interfaces = {
    enp6s0.useDHCP = true;
    enp7s0.useDHCP = false;
    br0.useDHCP = false;
  };

  # ==================== Other Programs/Services (Enabled via Options) ====================
  services.calibre-web.enable = true;
  services.deluge.enable = true;
  services.kanata.enable = true;
  services.zfs.enable = true;       # Option from modules/system/services/zfs/default.nix
  services.nfs.enable = true;
  services.samba.enable = true;
  programs.gnupg.enable = true;     # Option from modules/system/programs/gnupg/default.nix
  programs.dconf.enable = true;

  # ==================== Home Manager Configuration (NixOS Managed) ====================
  # This configures Home Manager for 'alc' when building this NixOS system.
  # It's separate from your standalone `homeConfigurations.alc` but can share the same `home.nix`.
  /* home-manager.users.${username} = {
    imports = [
      # Import the main home.nix for the user, using configDir for the path.
      "${configDir}/users/${username}/home.nix"
    ];
    # pkgs = pkgs; # This is implicitly passed by home-manager.nixosModule.
    # Home Manager will use the system's 'pkgs' and specialArgs from nixosSystem.
  }; */
}
