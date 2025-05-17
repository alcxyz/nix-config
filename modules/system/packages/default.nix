{ config, pkgs, lib, ... }:

{
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
}
