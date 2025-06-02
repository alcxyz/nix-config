# modules/nixos/packages/default.nix
{ options, config, lib, pkgs, username, ... }:

with lib;
let
  cfg = config.packages.managed;
in
{
  options.packages.managed = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the base nixos configurations.";
    };
  };

  # These imports are now unconditional within this file.
  # The decision to enable them or their contents can be handled by config.packages.managed.enable
  # either in this file's config block or within the imported modules themselves.
  #imports = [
  #  # Paths are relative to this file (modules/nixos/default.nix)
  #];

  config = mkIf cfg.enable {

    environment.systemPackages = with pkgs; [
      neovim
      tmux
      tree
      wget
      atuin
      vagrant
      chezmoi
      bunster
      portal
      sops
      age
      sshs

      # Development
      git
      git-remote-gcrypt
      lazygit
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
      sshfs
      ffmpeg
      python3
      python3Packages.rencode

      wl-clipboard
      xclip
      xarchiver
      rar
      unrar
      unzip

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

  };
}
