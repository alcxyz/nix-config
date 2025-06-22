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

  config = mkIf cfg.enable {

    environment.systemPackages = with pkgs; [
      neovim
      tmux
      tree
      wget
      vagrant
      chezmoi
      bunster
      portal
      sops
      age
      ssh-to-age
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
