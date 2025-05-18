# modules/system/default.nix
{ options, config, lib, pkgs, username, ... }: # These args are supplied by nixosSystem

with lib;
let
  cfg = config.system; # Accesses the option defined below
in
{
  options.system = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the base system configurations.";
    };
  };

  # These imports are now unconditional within this file.
  # The decision to enable them or their contents can be handled by config.system.enable
  # either in this file's config block or within the imported modules themselves.
  imports = [
    # Paths are relative to this file (modules/system/default.nix)
    # ./packages/default.nix # Removed, packages are now inlined below
    ./hardware/bluetooth.nix
    ./hardware/audio.nix # Your audio module
    ./fonts/default.nix
    ./env/default.nix
    ./nix/default.nix
    ./services/ssh/default.nix
    # Add other core system components here that are part of the "base"
  ];

  config = mkIf cfg.enable {
    # Configurations applied when system.enable = true;

    # Packages from the former modules/system/packages/default.nix
    environment.systemPackages = with pkgs; [
      stash
      neovim
      tmux
      tree
      wget
      atuin
      vagrant
      chezmoi
      ranger
      bunster
      portal
      age
      sshs

      # Development
      git
      git-remote-gcrypt
      lazygit
      bat
      fzf
      fd
      jq
      rustc
      cargo
      go
      gopls
      lua-language-server
      nodejs_22

      # Util
      ripgrep
      openssl
      killall
      gptfdisk
      unzip
      sshfs
      htop
      btop
      ffmpeg
      python3
      python3Packages.rencode

      xclip
      xarchiver
      xsel
      rar
      unrar

      nfs-utils
      gnumake
      gcc
      dig
      lsof
      ntfs3g
      pandoc

      bluetuith
      pavucontrol
    ];

    # Enable features from the imported modules above
    # These options should be defined within the respective imported modules
    # For example, if ./hardware/bluetooth.nix defines hardware.bluetooth.enable:
    hardware.bluetooth.enable = true;
    hardware.audio.enable = true; # Assuming ./hardware/audio.nix defines this

    # If ./nix/default.nix defines system.nix.enable (or similar):
    # system.nix.enable = true; # Example, adjust to actual option name

    # If ./fonts/default.nix defines system.fonts.enable:
    # system.fonts.enable = true; # Example

    # If ./services.ssh/default.nix defines services.openssh.enable (NixOS standard option):
    services.ssh.enable = true; # Example, assuming ssh module configures services.openssh

    # The environment module (./env/default.nix) is imported;
    # its configurations will apply if it defines them unconditionally or via its own options.
  };
}
