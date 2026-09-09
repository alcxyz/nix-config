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

  hyprPluginDir = pkgs.symlinkJoin {
    name = "hyprland-plugins";
    paths = [];
  };
in {
  # ==================== Users ====================
  users.users.${username} = {
    extraGroups = [
      "vfio"
      "video"
    ];
  };

  services.accounts-daemon.enable = true;

  system.activationScripts.accountsServiceProfileIcon.text = ''
    icon_target="/var/lib/AccountsService/icons/${username}"
    user_target="/var/lib/AccountsService/users/${username}"

    install -Dm0644 "${configDir}/users/${username}/profile.jpg" "$icon_target"
    install -d -m 0700 /var/lib/AccountsService/users

    tmp="$(mktemp)"
    if [ -f "$user_target" ]; then
      cp "$user_target" "$tmp"
      if ${pkgs.gnugrep}/bin/grep -q '^Icon=' "$tmp"; then
        ${pkgs.gnused}/bin/sed -i "s|^Icon=.*|Icon=$icon_target|" "$tmp"
      elif ${pkgs.gnugrep}/bin/grep -q '^\[User\]' "$tmp"; then
        ${pkgs.gnused}/bin/sed -i "/^\[User\]/a Icon=$icon_target" "$tmp"
      else
        {
          printf '[User]\n'
          printf 'Icon=%s\n' "$icon_target"
          cat "$tmp"
        } > "$tmp.new"
        mv "$tmp.new" "$tmp"
      fi
    else
      {
        printf '[User]\n'
        printf 'Icon=%s\n' "$icon_target"
      } > "$tmp"
    fi

    install -m 0600 "$tmp" "$user_target"
    rm -f "$tmp"
  '';

  # ==================== System Packages ====================
  environment.systemPackages = pkgsets.system.${hostRole.systemPackageSet};

  environment.sessionVariables = {
    HYPR_PLUGIN_DIR = "${hyprPluginDir}";
  };

  environment.etc."fuse.conf".text = ''
    user_allow_other
  '';

  boot.supportedFilesystems.ntfs = true;

  # ==================== Emulation (for aarch64 remote builds) ====================
  boot.binfmt.emulatedSystems = ["aarch64-linux"];

  # ==================== Hardware ====================
  hardware.enableRedistributableFirmware = true;

  # ==================== Security & PAM ====================
  security.pam.services = {
    login.u2fAuth = true;
    sudo.u2fAuth = true;
  };

  # ==================== Desktop Environment ====================
  services.xserver.enable = true;

  #services.displayManager.gdm.enable = true;

  # Disable GDM
  services.displayManager.gdm.enable = false;

  # Enable greetd
  services.greetd = {
    enable = true;
    settings = {
      initial_session = {
        command = "${pkgs.uwsm}/bin/uwsm start -g -1 -e -D Hyprland hyprland.desktop";
        user = username;
      };
      default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --cmd '${pkgs.uwsm}/bin/uwsm start -g -1 -e -D Hyprland hyprland.desktop'";
        user = "greeter";
      };
    };
  };

  # Ensure TTYs are handled correctly for tuigreet
  systemd.services.greetd.serviceConfig = {
    Type = "idle";
    StandardInput = "tty";
    StandardOutput = "tty";
    StandardError = "journal";
    TTYReset = true;
    TTYVHangup = true;
    TTYVTDisallocate = true;
  };

  /*
  programs.dankMaterialShell.greeter = {
    enable = true;
    compositor.name = "hyprland";
    configHome = "/home/${username}";
    logs = {
      save = true;
      path = "/tmp/dms-greeter.log";
    };
    quickshell.package = inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default;
  };
  */

  programs.niri.enable = true;
  programs.hyprland = {
    enable = true;
    withUWSM = true;
    xwayland.enable = true;
    #package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
    #portalPackage = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
  };

  services.gnome.sushi.enable = true;
  services.udisks2.enable = true;
  services.gvfs.enable = true;
  security.polkit.enable = true;
  # DMS provides the graphical authentication agent, but pkexec still needs
  # the privileged NixOS wrapper to hand approved commands to Polkit.
  security.wrappers.pkexec.enable = lib.mkForce true;
  programs.dconf.enable = true;

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

  # ==================== Services ====================

  # ==================== Keyboard Remapping ====================
  services.kanata = {
    enable = true;
    package = pkgs.kanata;
    keyboards.main = {
      config = builtins.readFile "${configDir}/users/${username}/configs/kanata/kanata.kbd";
      extraDefCfg = lib.mkDefault ''
        process-unmapped-keys yes
        ;; Streaming servers create synthetic keyboards that must remain
        ;; available to their own input stack instead of being exclusively
        ;; grabbed by Kanata.
        linux-dev-names-exclude (
          "Keyboard passthrough"
          "waynergy keyboard"
        )
      '';
    };
  };
  systemd.services.kanata-main.serviceConfig = {
    Restart = "on-failure";
    RestartSec = "2s";
  };

  virtualisation.docker = {
    enable = true;
    daemon.settings = {
      log-driver = "journald";
      features = {
        cdi = true;
      };
    };
  };
}
