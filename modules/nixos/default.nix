# modules/nixos/default.nix
{ options, config, lib, pkgs, username, ... }:

with lib;
let
  cfg = config.nixosBase;
in
{
  options.nixosBase = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the base nixos configurations.";
    };
  };

  # These imports are now unconditional within this file.
  # The decision to enable them or their contents can be handled by config.nixosBase.enable
  # either in this file's config block or within the imported modules themselves.
  imports = [
    # Paths are relative to this file (modules/nixos/default.nix)
    ./fonts/default.nix
    ./env/default.nix
    ./nix/default.nix
    ./services/ssh/default.nix
  ];

  config = mkIf cfg.enable {

    system.fonts.enable = true;

    services.ssh.enable = true;

    environment.variables = {
      EDITOR = "nvim";
      VISUAL = "nvim";
    };

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
      sops
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
      sshfs
      htop
      btop
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
