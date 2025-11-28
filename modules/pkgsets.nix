# modules/pkgsets.nix
# Centralized package sets for system and home-manager usage with commented groupings for readability.
# Import with: let pkgsets = import ../../modules/pkgsets.nix { inherit pkgs inputs; };
# Then use pkgsets.system.<role> for environment.systemPackages and
# pkgsets.home.<role> for home.packages.
{ pkgs, inputs ? null }:

let
  lib = pkgs.lib;
  system = pkgs.stdenv.hostPlatform.system;

  /* Optional external package (zen browser) from inputs if provided */
  zenPkg =
    if inputs != null && inputs ? zen-browser
    then inputs.zen-browser.packages.${system}.default
    else null;

  /* Optional external ndrop from your custom-packages input (used on xyz) */
  ndropPkg =
    if inputs != null && inputs ? custom-packages
    then inputs.custom-packages.packages.${system}.ndrop
    else null;
in

rec {
  # -----------------------
  # System (global) packages
  # -----------------------
  sys = {
    /* Shared across all machines (NixOS + nix-darwin) */
    base = with pkgs; [
      home-manager
      openssl
      lsof
      dig
    ];

    /* Linux-only system bits (keep in systemPackages) */
    linux = with pkgs; [
      nfs-utils
      gptfdisk
    ];

    /* Linux desktop-specific system packages */
    linuxDesktop = with pkgs; [
      ntfs3g
      sshfs
    ];

    /* Wayland desktop specific system packages (grabs, slurp, etc.) */
    waylandDesktop = with pkgs; [
      xwayland-satellite
      grim
      slurp
      swappy
      imagemagick
    ] ++ lib.optionals (ndropPkg != null) [ ndropPkg ];
  };

  /* Ready-to-use system presets (use in environment.systemPackages) */
  system = {
    workstation = sys.base ++ sys.linux ++ sys.linuxDesktop ++ sys.waylandDesktop;
    server = sys.base ++ sys.linux;
    mac = sys.base;
  };

  # -----------------------
  # Home-manager package sets (with inline headings)
  # -----------------------
  hm = {
    /* ---------------------------------------------------------------------
       Base: core user tools & daily CLI utilities (cross-platform)
       --------------------------------------------------------------------- */
    base = with pkgs; [
      /* Editors & UI */
      neovim
      neofetch

      /* Monitoring / top-like tools */
      htop
      btop

      /* Shell & portability helpers */
      tmux
      wget
      uutils-coreutils-noprefix
      killall

      /* Search & fuzzy / file utilities */
      ripgrep
      ripgrep-all
      fd
      fzf
      xh
      portal
      dua
      yazi

      /* Text processing, viewers & docs */
      bat
      jq
      yq
      pandoc
      glow

      /* Archives & media */
      #unzip
      #unrar
      #rar
      #ffmpeg

      /* Secrets & smartcard / age tooling */
      gopass
      yubico-piv-tool
      sops
      age
      age-plugin-yubikey
      ssh-to-age
      sshs

      /* Git & auth / cloud CLI */
      gh
      git-remote-gcrypt
      azure-cli
      google-cloud-sdk

      /* Misc / infra helpers */
      devbox
      atac
      termshark
      openldap
      minikube
    ];

    /* Small linux-only user additions you had scattered */
    linux = with pkgs; [
      nitch
      gitui
    ];

    /* macOS-only additions */
    mac = with pkgs; [
      mas
    ];

    /* Developer toolchains and language servers */
    dev = with pkgs; [
      rustc
      cargo
      go
      gopls
      lua-language-server
      nodejs_22
      node2nix
      python3
      python3Packages.rencode
      gnumake
      gcc
    ];

    /* Infrastructure-as-Code */
    iac = with pkgs; [
      terraform
      opentofu
      ansible
    ];

    /* Kubernetes / cloud-native CLI tools */
    k8s = with pkgs; [
      kubectl
      kubernetes-helm
      k9s
      kubeswitch
    ];

    /* Linux desktop/user utilities */
    linuxExtras = with pkgs; [
      wl-clipboard
      xarchiver
      bluetuith
      xclip
    ];

    /* Workstation (xyz) GUI / desktop extras (user-level)
       — includes the GUI apps you had scattered under xyz.nix */
    workstationExtras =
      (with pkgs; [
        rbw
        thunderbird-bin
        brave
        bitwarden-cli
        pinentry-gtk2
        seafile-client
        celeste
        signal-cli
        texlive.combined.scheme-full
        jrnl
        croc
        youtube-music
        wiki-tui
      ])
      ++ lib.optionals (zenPkg != null) [ zenPkg ];
  };

  /* Ready-to-use home-manager presets (use in home.packages) */
  home = {
    workstation =
      hm.base
      ++ hm.linux
      ++ hm.dev
      ++ hm.iac
      ++ hm.k8s
      ++ hm.linuxExtras
      ++ hm.workstationExtras;

    server = hm.base ++ hm.linux;

    mac = hm.base ++ hm.mac ++ hm.dev ++ hm.iac ++ hm.k8s;
  };
}
