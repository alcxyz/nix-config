# nix-config/hosts/madsil/configuration.nix
{
  pkgs,
  inputs,
  username,
  hostRole,
  configDir,
  lib,
  ...
}: let
  pkgsets = import "${configDir}/modules/shared/pkgsets.nix" {
    inherit pkgs inputs;
  };
in {
  imports = [
    ./hardware-configuration.nix
    inputs.home-manager.nixosModules.home-manager
    "${configDir}/modules/nixos/common/default.nix"
    "${configDir}/modules/nixos/services/flatpak/default.nix"
    "${configDir}/modules/nixos/services/heroic-sideload/default.nix"
    "${configDir}/modules/nixos/services/netbird/default.nix"
  ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

  environment.systemPackages = pkgsets.system.${hostRole.systemPackageSet};

  hardware.enableRedistributableFirmware = true;

  alc.shell = {
    default = "bash";
    enableNushell = false;
  };

  users.users.madsil = {
    isNormalUser = true;
    description = "Madsil";
    createHome = true;
    shell = pkgs.bashInteractive;
    initialPassword = "changeme";
    extraGroups = [
      "audio"
      "input"
      "networkmanager"
      "video"
    ];
  };

  programs.hyprlock.enable = true;
  services.accounts-daemon.enable = true;
  services.displayManager.gdm.enable = false;
  services.greetd = {
    enable = true;
    settings = {
      initial_session = {
        command = "${pkgs.uwsm}/bin/uwsm start hyprland-uwsm.desktop";
        user = "madsil";
      };
      default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --sessions /run/current-system/sw/share/wayland-sessions";
        user = "greeter";
      };
    };
  };
  systemd.services.greetd.serviceConfig = {
    Type = "idle";
    StandardInput = "tty";
    StandardOutput = "tty";
    StandardError = "journal";
    TTYReset = true;
    TTYVHangup = true;
    TTYVTDisallocate = true;
  };
  systemd.services.greetd = {
    after = ["home-manager-madsil.service"];
    wants = ["home-manager-madsil.service"];
  };

  services.xserver.enable = true;
  programs.hyprland = {
    enable = true;
    withUWSM = true;
    xwayland.enable = true;
  };
  services.gnome.sushi.enable = true;
  services.gnome.gnome-keyring.enable = true;
  services.udisks2.enable = true;
  services.gvfs.enable = true;
  security.polkit.enable = true;
  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [xdg-desktop-portal-gtk];
    config.common.default = ["gtk"];
    config.hyprland.default = [
      "hyprland"
      "gtk"
    ];
    xdgOpenUsePortal = true;
  };

  programs.dconf = {
    enable = true;
    profiles.user.databases = [
      {
        settings = {
          "org/gnome/settings-daemon/plugins/power" = {
            sleep-inactive-ac-type = "nothing";
            sleep-inactive-battery-type = "nothing";
            power-button-action = "interactive";
          };
        };
      }
    ];
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = {
      inherit inputs configDir hostRole;
      hostName = "madsil";
      username = "madsil";
      system = pkgs.stdenv.hostPlatform.system;
    };
    users.madsil = import "${configDir}/users/madsil/linux/madsil.nix";
  };
  systemd.services.home-manager-madsil = {
    after = ["nix-daemon.service"];
    wants = ["nix-daemon.service"];
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "10s";
    };
    unitConfig = {
      StartLimitBurst = 6;
      StartLimitIntervalSec = "2m";
    };
  };

  services.fwupd.enable = true;
  services.printing.enable = true;
  services.power-profiles-daemon.enable = true;
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    IdleAction = "ignore";
  };
  services.flatpak.managed = {
    enable = true;
    packages = [
      "com.heroicgameslauncher.hgl"
    ];
    overrides."com.heroicgameslauncher.hgl" = [
      "--filesystem=/nix/store:ro"
      "--filesystem=home"
    ];
  };

  programs.steam.enable = true;
  programs.gamemode.enable = true;

  services.heroicSideload = {
    enable = true;
    user = "madsil";
    apps.totem-quest = {
      title = "Totem Quest";
      appName = "rcFYseiJyPmfqM9tn2Di7a";
      source = "/var/lib/madsil-games/sources/Totem-Quest_Win_EN_Full.zip";
      installDir = "/home/madsil/Games/Totem_Quest";
      executable = "TotemQuest.exe";
      art = "https://www.myabandonware.com/media/screenshots/t/totem-quest-1c8k/webp/totem-quest_1.webp";
      protonPackage = pkgs.proton-ge-bin.steamcompattool;
      desktopShortcut = true;
    };
  };

  services.netbird.managed = {
    enable = true;
    disableDns = true;
  };

  networking.hosts = {
    "100.82.58.0" = ["madsil"];
  };

  nix.settings = {
    allowed-users = ["madsil"];
    max-jobs = 4;
  };

  system.stateVersion = lib.mkForce "25.11";
}
