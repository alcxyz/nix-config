# nix-config/modules/nixos/common/default.nix
{ config, pkgs, inputs, username, hostName, configDir, lib, ... }:

let
  pkgsets = import "${configDir}/modules/nixos/common/pkgsets.nix" {
    inherit pkgs inputs;
  };

  alc_xyz_key =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM9g7HJbiqvmCZRZF5z5g9J/VLI91p7RpXipA9eWHX2q alc@xyz";
  alc_mac_key =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAxWjN37TvOrWjv1FXde72TscMwP0TbHRhoe0kO8IIU0 alc@mac";
  alc_iphone_key =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEhgqS6A8n44Azg65g9u7a2mQ+RwqYo8dBW/4CHfua+0 terminus@iphone";
  alc_nux_key =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ0jGXFKy82JnUagVgPVbBuUBlYqfbFGwcLoOnaabG+S alc@nux";
  alc_rpi0_key =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO+l1wZzNjZ8vyopSUTGqziqif96bdfDoGJf0Iz82VHM alc@rpi0";
  root_nux_key =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmkdBBUyxWpdARfACmw6+P3yOfo0RKfK3JfRJMX+NYW root@nux";
  root_rpi0_key =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEzVGF4OpgIzykRlY6jK4Qw9VIauCBd3aECraqvBntv9 root@rpi0";
  docker_app_key =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKkMvn8LGAG3tBwNmABBXifXKVTs54TzE1cpX4TcadT docker@iphone";
in

{
  # ==================== Imports ====================
  imports = [
  ];

  # ==================== Nix Configuration ====================
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      accept-flake-config = true;
      warn-dirty = false;
      sandbox = true;
      auto-optimise-store = true;
      trusted-users = [ "root" username ];
      allowed-users = [ "root" username ];
      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
        "https://cuda-maintainers.cachix.org"
      ];
      trusted-substituters = lib.optionals (hostName != "xyz") [ "ssh://alc@xyz" ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
        "xyz:qRbAg2a0Z9A7lm2G+lfdBvXXIJ/NuBtw07vhsJoxV4s="
      ];
    };
    package = pkgs.nixVersions.latest;
  };

  # ==================== System Configuration ====================
  networking.hostName = hostName;
  system.stateVersion = "24.11";

  i18n.defaultLocale = "en_US.UTF-8";
  time.timeZone = "Europe/Oslo";
  console.useXkbConfig = true;
  services.xserver.xkb = { layout = "us"; };

  # ==================== Boot Configuration ====================
  boot.loader = if pkgs.stdenv.isAarch64 then {
    systemd-boot.enable = false;
    generic-extlinux-compatible.enable = true;
  } else {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  boot.initrd.systemd.enable = true;
  boot.blacklistedKernelModules = [ "algif_aed" ];

  # ==================== Users & Shells ========================
  users = {
    users = {
      ${username} = {
        isNormalUser = true;
        home = "/home/${username}";
        createHome = true;
        shell = pkgs.nushell;
        extraGroups = [
          "networkmanager"
          "wheel"
          "audio"
          "sound"
          "input"
          "tty"
          "rtkit"
          "pcscd"
          "docker"
        ];

        openssh.authorizedKeys.keys = [
          root_nux_key
          root_rpi0_key
          alc_xyz_key
          alc_nux_key
          alc_rpi0_key
          alc_mac_key
          alc_iphone_key
          docker_app_key
        ];
      };

      root = {
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys = [ 
          root_nux_key
          root_rpi0_key
          alc_xyz_key
          alc_nux_key
          alc_rpi0_key
          alc_mac_key
        ];
      };
    };
  };

  # ==================== Fonts ====================
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-color-emoji
    nerd-fonts.jetbrains-mono
  ];

  environment.variables = {
    LOG_ICONS = "true";
    XDG_CACHE_HOME = "$HOME/.cache";
    XDG_CONFIG_HOME = "$HOME/.config";
    XDG_DATA_HOME = "$HOME/.local/share";
    XDG_BIN_HOME = "$HOME/.local/bin";
    XDG_DESKTOP_DIR = "$HOME";
    LESSHISTFILE = "$XDG_CACHE_HOME/less.history";
    WGETRC = "$XDG_CONFIG_HOME/wgetrc";
    EDITOR = "nvim";
    VISUAL = "nvim";
  };

  # ==================== Nix-ld ====================
  # Provides the missing dynamic linker for pre-built binaries (Mason, npm, AppImages, etc.)
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    icu
  ];

  # ==================== Security ====================
  security.sudo.enable = true;
  services.pcscd.enable = true;
  
  # libfido2 ships udev rules that reference the traditional "plugdev" group.
  # We keep libfido2 for FIDO2/YubiKey support and create the group to avoid
  # udev warnings on NixOS.
  users.groups.plugdev = {};

  services.udev.packages = [ pkgs.libfido2 ];

  # ==================== Networking ====================
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

  # ==================== Virtualisation ====================
  virtualisation.containers.enable = true;
  virtualisation.docker.enable = true;

  # ==================== sops/secrets ====================
  sops = {
    defaultSopsFile = "${inputs.nix-secrets}/hosts/${hostName}/secrets.yaml";
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    #secrets = {
    #  from_shared= { sopsFile = "${inputs.nix-secrets.secrets.files.shared.${hostName}}"; };
    #  from_host = { sopsFile = "${inputs.nix-secrets.secrets.files.hosts.${hostName}}"; };
    #};
  };

  # ==================== SSH ====================
  services.openssh = {
    enable = true;
    ports = [ 22 ];
    openFirewall = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      PubkeyAuthentication = true;
    };
  };

  # ==================== Audio ====================
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    wireplumber.enable = true;
    pulse.enable = true;
  };
  services.pulseaudio.enable = false;

  # ==================== Bluetooth ====================
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        FastConnectable = true;
        JustWorksRepairing = "always";
        Privacy = "device";
      };
      Policy.AutoEnable = true;
    };
  };

}
