# modules/pkgsets.nix
# Centralized package sets for system and home-manager usage with commented
# groupings for readability.
#
# Import with:
#   let pkgsets = import ../../modules/pkgsets.nix { inherit pkgs; };
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
      libsecret

      # nix env related
      font-manager
      nil
      nixfmt
      nix-index
      nix-prefetch-git
    ];

    # Linux workstation extras (pulls in QEMU etc.)
    linuxWorkstation = with pkgs; [
      lima
    ];

    # Linux desktop-specific system packages
    linuxDesktop = with pkgs; [
      gparted
      ntfs3g
      sshfs
      xwayland-satellite
      grim
      slurp
      swappy
      ndrop
    ];
  };

  # Ready-to-use system presets (use in environment.systemPackages)
  system = {
    workstation = sys.base ++ sys.linux ++ sys.linuxWorkstation ++ sys.linuxDesktop;
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
      neovim
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
      glow
      sqlite

      # Archives & media (CLI use of ffmpeg, etc.)
      unzip
      p7zip
      #unrar
      #rar
      ffmpeg
      imagemagick

      # Secrets & smartcard / age tooling
      gopass
      yubico-piv-tool
      sops
      age
      age-plugin-yubikey
      ssh-to-age
      sshs

      # Git & version control
      git
      git-remote-gcrypt
      forge-mirror
      forgejo-cli
      gh
      gh-dash
      lazygit
      diffnav
      cloudflared

      # Misc
      lazydocker
      parallel
      agent-sync-check
      nix-deploy
    ];

    # Cloud SDKs & heavier infra tools — workstation/mac only
    cloud = with pkgs; [
      google-cloud-sdk
      shopify-cli
      pandoc
      atac
      termshark
      openldap
      minikube

      (azure-cli.withExtensions (
        with azure-cli.extensions;
        [
          ssh
          fzf
          azure-devops
          bastion
        ]
      ))
    ];

    # Linux-only CLI additions
    linux = with pkgs; [
      dgop
      nitch
      gitui
      ghostty
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

    # Kubernetes / cloud-native CLI tools are installed by
    # modules/home-manager/programs/kubernetes/default.nix so they can be
    # wrapped with per-command KUBECONFIG handling.
    k8s = [ ];

    ai = with pkgs; [
      #gemini-cli
      opencode
      claude-code
      codex
      t3code
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
      helium
      vlc
      obs-studio
      gpu-screen-recorder
      wcap
      kdePackages.kdenlive
      libreoffice
      calibre
      gimp3-with-plugins
      cameractrls
      cameractrls-gtk4
      winetricks
      wineWow64Packages.waylandFull
      nautilus
    ];

    # macOS-only desktop apps
    desktopMacOnly = with pkgs; [
      raycast
      omniwm
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
    workstationExtras = (
      with pkgs;
      [
        rbw
        bitwarden-desktop
        pinentry-gtk2
        texlive.combined.scheme-full

        jrnl
        pear-desktop
        wiki-tui
        zen-browser
      ]
    );
  };

  # =======================================================================
  # Home-manager role presets (aggregate of hm.* sets)
  # =======================================================================
  home = {
    # Workstation: CLI base + cloud + linux-specific + dev/IaC/K8s +
    # linux desktop helpers + workstation extras.
    workstation =
      hm.base
      ++ hm.cloud
      ++ hm.linux
      ++ hm.dev
      ++ hm.iac
      ++ hm.k8s
      ++ hm.linuxExtras
      ++ hm.workstationExtras
      ++ hm.desktopLinux
      ++ hm.ai
      ++ hm.gaming;

    # NUC server: base + linux + k8s + dev tools (runs k3s, builds containers).
    nuc = hm.base ++ hm.linux ++ hm.k8s;

    # Dedicated server: base + linux + k8s + dev + IaC (future powerful host).
    server = hm.base ++ hm.linux ++ hm.k8s ++ hm.dev ++ hm.iac;

    # Embedded/edge: minimal CLI base + linux-specific only.
    embedded = hm.base ++ hm.linux;

    # mac laptop: CLI base + cloud + mac-specific + dev/IaC/K8s.
    mac = hm.base ++ hm.cloud ++ hm.mac ++ hm.dev ++ hm.iac ++ hm.k8s ++ hm.ai ++ hm.desktopMac;
  };
}
