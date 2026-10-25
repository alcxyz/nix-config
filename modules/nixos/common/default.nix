# nix-config/modules/nixos/common/default.nix
{
  config,
  pkgs,
  inputs,
  username,
  accountUsername,
  accountHomeDirectory,
  hostName,
  hostRole,
  configDir,
  lib,
  ...
}: let
  pkgsets = import "${configDir}/modules/shared/pkgsets.nix" {
    inherit pkgs inputs;
  };

  shellPackages = {
    bash = pkgs.bashInteractive;
    zsh = pkgs.zsh;
  };
  nixGenerationRetention = pkgs.writeShellScript "nix-generation-retention" ''
    export SUDO_BIN=/run/wrappers/bin/sudo
    exec ${lib.getExe pkgs.nix-gc-maintenance} \
      --automatic-retention \
      --keep ${toString config.alc.nix.keepGenerations} \
      --user ${lib.escapeShellArg accountUsername} \
      --home ${lib.escapeShellArg accountHomeDirectory}
  '';
in {
  # ==================== Imports ====================
  imports = [
    inputs.nix-secrets.nixosModules.sshIdentityPolicy
    inputs.nix-secrets.nixosModules.sshAccessPolicy
    ../../shared/host-metadata.nix
    ../../shared/shell.nix
    inputs.nix-secrets.nixosModules.distributedBuildClientPolicy
    ./nsswitch.nix
    ./pki.nix
    ./nix-retention.nix
    ../security/credential-consent/default.nix
    ../services/nixfleet-boot-check/default.nix
    ../services/nixfleet-reboot-guard/default.nix
    ../services/snapshot-restic-home/default.nix
    ../services/storage-health-monitor/default.nix
    ../virtualisation/container-netns/default.nix
  ];

  # ==================== Nix Configuration ====================
  programs.zsh.enable = config.alc.shell.enableZsh;

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
      # Emergency backstop: when free space drops below min-free during a
      # build or substitution, Nix collects dead paths until max-free is
      # available. Like scheduled GC, it never deletes generations (ADR-0013).
      min-free = 10 * 1024 * 1024 * 1024;
      max-free = 50 * 1024 * 1024 * 1024;
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
      ];
      trusted-substituters = lib.optionals (hostName != "xyz") ["ssh://alc@xyz"];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "xyz:qRbAg2a0Z9A7lm2G+lfdBvXXIJ/NuBtw07vhsJoxV4s="
      ];
    };
    gc = {
      automatic = true;
      # Collects every dead path, uncapped, and never deletes generations:
      # a size cap let dead paths accumulate faster than daily runs freed
      # them. Guarded generation retention runs separately before this
      # service; see ADR-0013.
      dates = "daily";
    };
    package = pkgs.nixVersions.latest;
  };

  # Someone may be using an interactive host, so nixfleet asks its guard
  # before a reboot (nix-packages #548).
  services.nixfleet-reboot-guard.enable = lib.mkDefault (hostRole.interactive or false);

  # ==================== System Configuration ====================
  networking.hostName = hostName;
  system.stateVersion = "24.11";

  i18n.defaultLocale = "en_US.UTF-8";
  time.timeZone = "Europe/Oslo";
  console.useXkbConfig = true;
  services.xserver.xkb = {
    layout = "us";
  };

  # Remove old coredumps once stored dumps exceed 1G, instead of systemd's
  # default of 10% of the filesystem capped at 4GiB.
  systemd.coredump.settings.Coredump.MaxUse = lib.mkDefault "1G";

  # ==================== Boot Configuration ====================
  boot.loader =
    if pkgs.stdenv.hostPlatform.isAarch64
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
        # Pinned so installer images that ship their own user cannot shift it.
        uid = 1000;
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
      };

      root = {
        shell = pkgs.bashInteractive;
      };
    };
  };

  environment.shells = with pkgs; [
    bashInteractive
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
  systemd.services = lib.mkMerge [
    {
      # Guarded generation retention is a distinct prerequisite of automatic
      # GC. It only prunes verified profiles when the fleet-wide pressure/count
      # policy triggers; nix-gc remains responsible for dead store paths.
      nix-generation-retention = {
        description = "Apply guarded Nix generation retention";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = nixGenerationRetention;
          Nice = 10;
          IOSchedulingClass = "idle";
        };
      };
      nix-gc = {
        requires = ["nix-generation-retention.service"];
        after = ["nix-generation-retention.service"];
      };
    }
    (lib.mkIf config.virtualisation.docker.enable {
      docker.path = with pkgs; [
        iptables
        nftables
      ];
    })
  ];

  systemd.tmpfiles.rules = [
    "d /home/${username}/.ssh 0700 ${username} users - -"
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
