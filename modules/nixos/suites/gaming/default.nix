# modules/nixos/suites/gaming/default.nix
{ options, config, lib, pkgs, username, ... }:

with lib;
let
  cfg = config.suites.gaming;
in
{
  options.suites.gaming = with types; {
    enable = mkOption {
      type = bool;
      default = false;
      description = "Enable system-level gaming support (audio sink, permissions, etc.)";
    };

    steam = mkOption {
      type = submodule {
        options = {
          enable = mkOption {
            type = bool;
            default = true;
            description = "Enable Steam and related gaming features";
          };
        };
      };
      default = {};
      description = "Steam gaming configuration";
    };

    sunshine = mkOption {
      type = submodule {
        options = {
          enable = mkOption {
            type = bool;
            default = false;
            description = "Enable Sunshine game streaming server";
          };
        };
      };
      default = {};
      description = "Sunshine streaming configuration";
    };

    emulation = mkOption {
      type = submodule {
        options = {
          enable = mkOption {
            type = bool;
            default = false;
            description = "Enable emulation gaming suite with EmulationStation-DE";
          };
          
          retroarch = mkOption {
            type = bool;
            default = true;
            description = "Enable RetroArch for retro gaming";
          };
          
          dolphin = mkOption {
            type = bool;
            default = true;
            description = "Enable Dolphin for GameCube/Wii emulation";
          };
          
          pcsx2 = mkOption {
            type = bool;
            default = true;
            description = "Enable PCSX2 for PlayStation 2 emulation";
          };
        };
      };
      default = {};
      description = "Emulation gaming configuration";
    };
  };

  config = mkIf cfg.enable {
    # Base gaming system setup
    users.users.${username}.extraGroups = lib.mkAfter (
      [ "input" "render" ] ++ lib.optionals cfg.sunshine.enable [ "video" "input" ]
    );

    environment.systemPackages = with pkgs; [
      # Base gaming tools
      pipewire
      pulseaudio # For pactl compatibility
      gnugrep gawk gnused

    ] ++ optionals cfg.steam.enable [
      steam
    ] ++ optionals cfg.sunshine.enable [
      sunshine
      (pkgs.writeTextDir "share/udev/rules.d/99-sunshine-uinput.rules" ''
        KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", GROUP="${config.users.users.${username}.group}"
      '')
    ] ++ optionals cfg.emulation.enable [
      emulationstation-de
    ] ++ optionals (cfg.emulation.enable && cfg.emulation.retroarch) [
      retroarch-full
    ] ++ optionals (cfg.emulation.enable && cfg.emulation.dolphin) [
      dolphin-emu
    ] ++ optionals (cfg.emulation.enable && cfg.emulation.pcsx2) [
      pcsx2
    ];

    services.udev.extraRules = ''
      KERNEL=="event*", GROUP="input", MODE="0664"
      KERNEL=="mouse*", GROUP="input", MODE="0664"
      KERNEL=="js*", GROUP="input", MODE="0664"
      SUBSYSTEM=="input", GROUP="input", MODE="0664"
    '';

    # Steam configuration
    programs.steam.enable = lib.mkIf cfg.steam.enable true;
    programs.steam.remotePlay.openFirewall = lib.mkIf cfg.steam.enable true;

    # Sunshine configuration
    security.wrappers.sunshine = mkIf cfg.sunshine.enable {
      owner = "root";
      group = "root";
      capabilities = "cap_sys_admin+p";
      source = "${pkgs.sunshine}/bin/sunshine";
    };

    systemd.user.services.sunshine = mkIf cfg.sunshine.enable {
      description = "Sunshine game streaming server";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" "pipewire.service" "pipewire-pulse.service" ];
      
      serviceConfig = {
        Type = "simple";
        ExecStart = "/run/wrappers/bin/sunshine";
        Restart = "on-failure";
        RestartSec = "5s";
      };
      
      environment = {
        HOME = "/home/${username}";
        XDG_RUNTIME_DIR = "/run/user/${toString config.users.users.${username}.uid}";

        # --- Add/Ensure these for Wayland ---
        WAYLAND_DISPLAY = "wayland-0"; # Hyprland typically uses wayland-0. Verify if different.
        XDG_SESSION_TYPE = "wayland";

        # These might help Sunshine and its dependencies correctly identify the GPU/rendering environment
        GBM_BACKEND = "nvidia-drm";
        __GLX_VENDOR_LIBRARY_NAME = "nvidia"; # For any Xwayland components
        LIBVA_DRIVER_NAME = "nvidia";      # For VAAPI if NVENC fails

        # If Sunshine or its UI components use Qt
        QT_QPA_PLATFORM = "wayland;xcb"; # Prioritize Wayland, fallback to XCB for Xwayland
      };

    };

    # Copy Sunshine configuration files
    system.activationScripts.sunshine-config = mkIf cfg.sunshine.enable {
      text = 
        let
          sunshineConf = pkgs.replaceVars ./config/sunshine.conf { inherit username; };
          appsJson = ./config/apps.json;
        in ''
        USER_HOME="/home/${username}"
        CONFIG_DIR="$USER_HOME/.config/sunshine"
        USER_GROUP="${config.users.users.${username}.group}"

        echo "Ensuring Sunshine config directory exists and has correct ownership for user ${username} (group $USER_GROUP)..."
        mkdir -p "$CONFIG_DIR"
        chown "${username}:$USER_GROUP" "$USER_HOME/.config" || echo "Warning: Could not chown $USER_HOME/.config (might be okay if already correct/accessible)"
        chown -R "${username}:$USER_GROUP" "$CONFIG_DIR"
        
        echo "Copying Sunshine configuration files..."
        cp "${sunshineConf}" "$CONFIG_DIR/sunshine.conf"
        cp "${appsJson}" "$CONFIG_DIR/apps.json"
        
        echo "Setting ownership and permissions for Sunshine config files..."
        chown "${username}:$USER_GROUP" "$CONFIG_DIR/sunshine.conf"
        chown "${username}:$USER_GROUP" "$CONFIG_DIR/apps.json"
        chmod 640 "$CONFIG_DIR/sunshine.conf"
        chmod 640 "$CONFIG_DIR/apps.json"
        echo "Sunshine configuration script finished."
      '';
      deps = [ "users" ];
    };
    
    # Firewall rules
    networking.firewall.allowedTCPPorts = lib.optionals cfg.sunshine.enable [ 47984 47989 48010 ];
    networking.firewall.allowedUDPPorts = lib.optionals cfg.sunshine.enable [ 47998 47999 48000 48002 48010 27031 27032 27033 27034 27035 27036 ];
  };
}
