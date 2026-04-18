# modules/pkgsets.nix
# Centralized package sets for system and home-manager usage with commented
# groupings for readability.
#
# Import with:
#   let pkgsets = import ../../modules/pkgsets.nix { inherit pkgs inputs; };
#
# Then use:
#   - pkgsets.system.<role>     for environment.systemPackages
#   - pkgsets.home.<role>       for home.packages
#   - pkgsets.sys.* / pkgsets.hm.* for finer-grained sets
{
  pkgs,
  inputs ? null,
}:

let
  lib = pkgs.lib;
  system = pkgs.stdenv.hostPlatform.system;

  # Optional external package (zen browser) from inputs if provided
  zenPkg =
    if inputs != null && inputs ? zen-browser then
      inputs.zen-browser.packages.${system}.default
    else
      null;

  # Optional external ndrop from your nix-packages input (used on xyz)
  ndropPkg =
    if inputs != null && inputs ? nix-packages then
      inputs.nix-packages.packages.${system}.ndrop
    else
      null;
in

rec {
  # =======================================================================
  # System (global) packages
  # =======================================================================
  sys = {
    # Shared across all machines (NixOS + nix-darwin)
    base = with pkgs; [
      home-manager
      openssl
      lsof
      dig
    ];

    # Linux-only system bits (keep in systemPackages)
    linux = with pkgs; [
      nfs-utils
      gptfdisk
      lima

      # nix env related
      font-manager
      nil
      nixfmt
      nix-index
      nix-prefetch-git
    ];

    # Linux desktop-specific system packages
    linuxDesktop =
      with pkgs;
      [
        gparted
        ntfs3g
        sshfs
        xwayland-satellite
        grim
        slurp
        swappy
        imagemagick
      ]
      ++ lib.optionals (ndropPkg != null) [ ndropPkg ];
  };

  # Ready-to-use system presets (use in environment.systemPackages)
  system = {
    workstation = sys.base ++ sys.linux ++ sys.linuxDesktop;
    server = sys.base ++ sys.linux;
    mac = sys.base;
  };

  # =======================================================================
  # Home-manager package sets
  # =======================================================================
  hm = rec {
    /*
      -------------------------------------------------------------------
      CLI / non-GUI base: cross-platform
      -------------------------------------------------------------------
    */
    base = with pkgs; [
      # Editors & UI-ish TUI
      #neofetch
      tree
      bat

      # Monitoring / top-like tools
      htop
      btop

      # Shell & portability helpers
      tmux
      wget
      killall

      # Search & fuzzy / file utilities
      ripgrep
      ripgrep-all
      fd
      fzf
      xh
      portal
      croc
      dua
      yazi

      # Text processing, viewers & docs
      jq
      yq
      pandoc
      glow
      sqlite

      # Archives & media (CLI use of ffmpeg, etc.)
      unzip
      #unrar
      #rar
      ffmpeg

      # Secrets & smartcard / age tooling
      gopass
      yubico-piv-tool
      sops
      age
      age-plugin-yubikey
      ssh-to-age
      sshs

      # Git & auth / cloud CLI
      git
      git-remote-gcrypt
      gh
      gh-dash
      lazygit
      diffnav
      google-cloud-sdk
      cloudflared
      shopify-cli

      (azure-cli.withExtensions (
        with azure-cli.extensions;
        [
          ssh
          fzf
          azure-devops
        ]
      ))

      # Misc / infra helpers
      atac
      termshark
      openldap
      minikube
      lazydocker
    ];

    # Linux-only CLI additions
    linux = with pkgs; [
      nitch
      gitui
    ];

    # macOS-only CLI additions
    mac = with pkgs; [
      mas
    ];

    /*
      -------------------------------------------------------------------
      Dev / IaC / K8s (CLI tooling)
      -------------------------------------------------------------------
    */
    dev = with pkgs; [
      rustup
      go
      gopls
      lua-language-server
      nodejs_22
      #node2nix
      python3
      python3Packages.rencode
      gnumake
      gcc
      pkg-config

      # Dev helper
      commitizen
      devbox
    ];

    # Infrastructure-as-Code
    iac = with pkgs; [
      terraform
      opentofu
      ansible
    ];

    # Kubernetes / cloud-native CLI tools
    k8s = with pkgs; [
      kubectl
      kubernetes-helm
      k9s
      kubeswitch
    ];

    ai = with pkgs; [
      #gemini-cli
      #goose-cli
      opencode
      #opencode-desktop
      claude-code
      codex
      #cursor-cli
      #code-cursor
    ];

    gaming = with pkgs; [
      heroic
      gamescope
      mangohud
      crosspipe
      moonlight-qt
    ];

    /*
      -------------------------------------------------------------------
      Desktop / GUI apps
      We split into:
      - desktopCommon      (intended for both Linux + mac where supported)
      - desktopLinuxOnly   (Linux-specific or very Linux-centric)
      - desktopMacOnly     (mac-specific, currently empty placeholder)
      -------------------------------------------------------------------
    */

    # Common desktop apps you might want on both Linux and macOS
    desktopCommon = with pkgs; [
      obsidian
      thunderbird
      brave
      # Add more truly cross‑platform desktop apps here later
    ];

    # Linux-only (or strongly Linux-oriented) desktop apps
    desktopLinuxOnly = with pkgs; [
      t3code
      helium
      vlc
      obs-studio
      kdePackages.kdenlive
      libreoffice
      calibre
      rustdesk
      gimp3-with-plugins
      cameractrls
      cameractrls-gtk4
      winetricks
      wineWow64Packages.waylandFull
      lens
      nautilus
    ];

    # macOS-only desktop apps
    desktopMacOnly = with pkgs; [
      raycast
      skhd
    ];

    # Convenience combined sets
    desktopLinux = desktopCommon ++ desktopLinuxOnly;
    desktopMac = desktopCommon ++ desktopMacOnly;

    # Linux desktop/user utilities (Wayland/X11 helpers etc.)
    linuxExtras = with pkgs; [
      wl-clipboard
      xarchiver
      bluetuith
      xclip
    ];

    /*
      Workstation (xyz) GUI / desktop extras (user-level)
      — includes the GUI apps you had scattered under xyz.nix
    */
    workstationExtras =
      (with pkgs; [
        rbw
        bitwarden-desktop
        pinentry-gtk2
        texlive.combined.scheme-full

        jrnl
        pear-desktop
        wiki-tui
      ])
      ++ lib.optionals (zenPkg != null) [ zenPkg ];
  };

  # =======================================================================
  # Home-manager role presets (aggregate of hm.* sets)
  # =======================================================================
  home = {
    # Workstation: CLI base + linux-specific + dev/IaC/K8s +
    # linux desktop helpers + workstation extras.
    # (Desktop GUI apps themselves are pulled via NixOS desktop suite.)
    workstation =
      hm.base
      ++ hm.linux
      ++ hm.dev
      ++ hm.iac
      ++ hm.k8s
      ++ hm.linuxExtras
      ++ hm.workstationExtras
      ++ hm.desktopLinux
      ++ hm.ai
      ++ hm.gaming;

    # Server: CLI base + linux-specific only.
    server = hm.base ++ hm.linux ++ hm.dev;

    # mac laptop: CLI base + mac-specific + dev/IaC/K8s.
    # (Desktop GUI apps for mac can be added via hm.desktopCommon/desktopMac.)
    mac = hm.base ++ hm.mac ++ hm.dev ++ hm.iac ++ hm.k8s ++ hm.ai ++ hm.desktopMac;
  };
}
