{ options
, config
, lib
, pkgs
, ...
}:
with lib;
with lib.custom; let
  cfg = config.suites.common;
in
{
  options.suites.common = with types; {
    enable = mkBoolOpt false "Enable the common suite";
  };

  config = mkIf cfg.enable {

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
    
    environment.variables = {
      EDITOR = "nvim";
    };

    hardware.audio.enable = true;
    hardware.networking.enable = true;

    services.ssh.enable = true;

    services.blueman.enable = true;

    hardware.bluetooth = {
      enable = true;
      settings = {
        General = {
          FastConnectable = true;
          JustWorksRepairing = "always";
          Privacy = "device";
        };
        Policy = with pkgs; {
          AutoEnable = true;
        };
      };
    };

    programs.dconf.enable = true;

    system = {
      nix.enable = true;
      security.doas.enable = true;
      fonts.enable = true;
      locale.enable = true;
      time.enable = true;
      xkb.enable = true;
    };
  };
}
