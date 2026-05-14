# nix-config/modules/nixos/common/default.nix
{
  config,
  pkgs,
  inputs,
  username,
  hostName,
  configDir,
  lib,
  ...
}: let
  pkgsets = import "${configDir}/modules/shared/pkgsets.nix" {
    inherit pkgs inputs;
  };

  sshKeys = import ./ssh-keys.nix;
  humanLoginKeys = sshKeys.groups.humanLogin sshKeys.keys;
  mobileAppKeys = sshKeys.groups.mobileApps sshKeys.keys;
  distributedBuildClientKeys = sshKeys.groups.distributedBuildClients sshKeys.keys;
  userHome = "/home/${username}";
  shellPackages = {
    bash = pkgs.bashInteractive;
    nu = pkgs.nushell;
    nushell = pkgs.nushell;
    zsh = pkgs.zsh;
  };
in {
  # ==================== Imports ====================
  imports = [
    ../../shared/host-metadata.nix
    ../../shared/shell.nix
    ./distributed-build-client.nix
  ];

  # ==================== Nix Configuration ====================
  programs.ssh.knownHosts = {
    xyz = {
      hostNames = [
        "xyz"
        "192.168.1.10"
      ];
      publicKey = sshKeys.keys.xyz_host_ed25519;
    };
    xev = {
      hostNames = [
        "xev"
        "192.168.1.13"
      ];
      publicKey = sshKeys.keys.xev_host_ed25519;
    };
  };

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      accept-flake-config = true;
      warn-dirty = false;
      sandbox = true;
      auto-optimise-store = true;
      trusted-users = [
        "root"
        username
      ];
      allowed-users = [
        "root"
        username
      ];
      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
        "https://cuda-maintainers.cachix.org"
      ];
      trusted-substituters = lib.optionals (hostName != "xyz") ["ssh://alc@xyz"];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
        "xyz:qRbAg2a0Z9A7lm2G+lfdBvXXIJ/NuBtw07vhsJoxV4s="
      ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      # Only free dead store paths, never delete profile generations
      # automatically. See docs/adr/0013-safe-nix-gc-no-generation-deletion.md.
      options = "--max-freed 10G";
    };
    package = pkgs.nixVersions.latest;
  };

  # ==================== System Configuration ====================
  networking.hostName = hostName;
  system.stateVersion = "24.11";

  i18n.defaultLocale = "en_US.UTF-8";
  time.timeZone = "Europe/Oslo";
  console.useXkbConfig = true;
  services.xserver.xkb = {
    layout = "us";
  };

  # ==================== Boot Configuration ====================
  boot.loader =
    if pkgs.stdenv.isAarch64
    then {
      systemd-boot.enable = false;
      generic-extlinux-compatible.enable = true;
    }
    else {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

  boot.initrd.systemd.enable = true;

  # ==================== Users & Shells ========================
  users = {
    users = {
      ${username} = {
        isNormalUser = true;
        home = "/home/${username}";
        createHome = true;
        shell = shellPackages.${config.alc.shell.default};
        extraGroups = [
          "networkmanager"
          "wheel"
          "audio"
          "sound"
          "input"
          "tty"
          "rtkit"
          "pcscd"
          "docker"
        ];

        openssh.authorizedKeys.keys =
          [
          ]
          ++ humanLoginKeys ++ mobileAppKeys;
      };

      root = {
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys =
          humanLoginKeys
          ++ lib.optionals (builtins.elem hostName ["xev" "xyz"]) distributedBuildClientKeys;
      };
    };
  };

  environment.shells = with pkgs; [
    bashInteractive
    nushell
    zsh
  ];

  # ==================== Fonts ====================
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-color-emoji
    nerd-fonts.jetbrains-mono
  ];

  environment.variables = {
    LOG_ICONS = "true";
    XDG_CACHE_HOME = "$HOME/.cache";
    XDG_CONFIG_HOME = "$HOME/.config";
    XDG_DATA_HOME = "$HOME/.local/share";
    XDG_BIN_HOME = "$HOME/.local/bin";
    XDG_DESKTOP_DIR = "$HOME";
    LESSHISTFILE = "$XDG_CACHE_HOME/less.history";
    WGETRC = "$XDG_CONFIG_HOME/wgetrc";
    EDITOR = "nvim";
    VISUAL = "nvim";
  };

  # ==================== Nix-ld ====================
  # Provides the missing dynamic linker for pre-built binaries (Mason, npm, AppImages, etc.)
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    icu
  ];

  # ==================== Security ====================
  security.sudo.enable = true;
  services.pcscd.enable = true;

  # libfido2 ships udev rules that reference the traditional "plugdev" group.
  # We keep libfido2 for FIDO2/YubiKey support and create the group to avoid
  # udev warnings on NixOS.
  users.groups.plugdev = {};

  services.udev.packages = [pkgs.libfido2];

  # ==================== Networking ====================
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

  # ==================== Virtualisation ====================
  virtualisation.containers.enable = true;
  virtualisation.docker.enable = true;
  systemd.services.docker.path = with pkgs; [
    iptables
    nftables
  ];

  # ==================== sops/secrets ====================
  sops = {
    defaultSopsFile = "${inputs.nix-secrets}/hosts/${hostName}/secrets.yaml";
    age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    secrets = {
      "${username}_ssh_private_key" = {
        key = "ssh_id_ed25519";
        path = "${userHome}/.ssh/id_ed25519";
        owner = username;
        group = "users";
        mode = "0600";
      };
      "${username}_ssh_public_key" = {
        key = "ssh_id_ed25519.pub";
        path = "${userHome}/.ssh/id_ed25519.pub";
        owner = username;
        group = "users";
        mode = "0644";
      };
    };
    #secrets = {
    #  from_shared= { sopsFile = "${inputs.nix-secrets.secrets.files.shared.${hostName}}"; };
    #  from_host = { sopsFile = "${inputs.nix-secrets.secrets.files.hosts.${hostName}}"; };
    #};
  };

  systemd.tmpfiles.rules = [
    "d ${userHome}/.ssh 0700 ${username} users - -"
  ];

  # ==================== SSH ====================
  services.openssh = {
    enable = true;
    ports = [22];
    openFirewall = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      PubkeyAuthentication = true;
    };
  };

  # ==================== Audio ====================
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    wireplumber.enable = true;
    pulse.enable = true;
  };
  services.pulseaudio.enable = false;

  # ==================== Bluetooth ====================
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        FastConnectable = true;
        JustWorksRepairing = "always";
        Privacy = "device";
      };
      Policy.AutoEnable = true;
    };
  };
}
