{
  options,
  config,
  pkgs,
  lib,
  ...
}:
with lib;
with lib.custom; let
  cfg = config.apps.misc;
in {
  options.apps.misc = with types; {
    enable = mkBoolOpt false "Enable or disable misc apps";
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      tmux

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
      btop
      ffmpeg
      python3
      python3Packages.rencode
    ];
  };
}
