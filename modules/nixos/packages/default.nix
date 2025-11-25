# modules/nixos/packages/default.nix
{ options, config, lib, pkgs, pkgs-unstable, inputs, username, ... }:

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
      sops
      age
      ssh-to-age
      sshs
      #carapace-bridge

      # Development
      git
      git-remote-gcrypt
      rustc
      cargo
      go
      gopls
      lua-language-server
      nodejs_22
      node2nix

      # Util
      uutils-coreutils-noprefix
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

      #networkmanagerapplet
      bluetuith
      #pavucontrol
      #easyeffects
    ] 
    ++ [
      # Use your custom packages instead of unstable
        #(inputs.custom-packages.packages.${pkgs.stdenv.hostPlatform.system}.carapace)
        #(inputs.custom-packages.packages.${pkgs.stdenv.hostPlatform.system}.carapace-bridge)
    ];

  };
}
