{ config, pkgs, inputs, username, hostName, configDir, lib, ... }:

let
  pkgsets = import ../pkgsets.nix { inherit pkgs inputs; };

  alc_xyz_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM9g7HJbiqvmCZRZF5z5g9J/VLI91p7RpXipA9eWHX2q alc@xyz";
  alc_mac_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAxWjN37TvOrWjv1FXde72TscMwP0TbHRhoe0kO8IIU0 alc@mac";
  alc_iphone_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEhgqS6A8n44Azg65g9u7a2mQ+RwqYo8dBW/4CHfua+0";
  alc_nux_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ0jGXFKy82JnUagVgPVbBuUBlYqfbFGwcLoOnaabG+S alc@nux";
  root_nux_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmkdBBUyxWpdARfACmw6+P3yOfo0RKfK3JfRJMX+NYW root@nux";
  docker_app_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKkMvn8LGAG3tBwNmABBXifXKVTs54TzE1cpX4TcadT";
in {

{
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
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
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
  services.xserver.xkb = { layout = "no"; };

  # ==================== Boot Configuration ====================
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.systemd.enable = true;

  # ==================== Users and Shells ====================
  users.users.${username} = {
    isNormalUser = true;
    home = "/home/${username}";
    createHome = true;
  };

  users.users.root.shell = pkgs.bashInteractive;
  users.defaultUserShell = pkgs.nushell;

  # ==================== Fonts ====================
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-color-emoji
    nerd-fonts.jetbrains-mono
  ];

  environment.systemPackages = with pkgs; [
    font-manager
    nil
    nixfmt-classic
    nix-index
    nix-prefetch-git
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

  # ==================== Security ====================
  security.sudo.enable = true;
  services.openssh.enable = true;
  services.pcscd.enable = true;
  services.udev.packages = [ pkgs.libfido2 ];

  # ==================== Networking ====================
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

  # ==================== Virtualization ====================
  virtualisation.containers.enable = true;
  virtualisation.docker.enable = true;

  # ==================== sops/secrets ====================
  sops = {
    defaultSopsFile = inputs.nix-secrets + "/secrets.yaml";
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };

  # ==================== SSH Configuration (centralized) ====================
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

  users.users.root.openssh.authorizedKeys.keys = [ alc_mac_key ];
  users.users.${username}.openssh.authorizedKeys.keys = [
    alc_xyz_key
    alc_mac_key
    alc_iphone_key
    alc_nux_key
    root_nux_key
    docker_app_key
  ];
}
