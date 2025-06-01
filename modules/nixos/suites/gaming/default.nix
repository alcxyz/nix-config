{ options, config, lib, pkgs, username, ... }:

with lib;
let
  cfg = config.suites.gaming;

  # Script for creating the game sink (now from a separate file)
  createGameSinkScript = pkgs.writeShellScriptBin "create-game-sink" (
    builtins.readFile ./scripts/create-game-sink.sh
  );

  # Script for removing the game sink (now from a separate file)
  removeGameSinkScript = pkgs.writeShellScriptBin "remove-game-sink" (
    builtins.readFile ./scripts/remove-game-sink.sh
  );

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
  };

  config = mkIf cfg.enable {
    # Base gaming system setup
    users.users.${username}.extraGroups = lib.mkAfter (
      [ "input" "render" ] ++ lib.optionals cfg.sunshine.enable [ "video" "input" ] # Ensure 'input' for uinput
    );

    environment.systemPackages = with pkgs; [
      # Base gaming tools
      pipewire # For pw-cli used in sink scripts
      pulseaudio # For pactl if any script still uses it (should transition to pw-*)
      gnugrep gawk gnused # For script utilities
    ] ++ optionals cfg.steam.enable [
      # Steam-specific packages
      steam
    ] ++ optionals cfg.sunshine.enable [
      # Streaming-specific packages
      sunshine
      (pkgs.writeTextDir "share/udev/rules.d/99-sunshine-uinput.rules" ''
        KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", GROUP="${config.users.users.${username}.group}"
      '')
    ];

    services.udev.extraRules = ''
      KERNEL=="event*", GROUP="input", MODE="0664"
      KERNEL=="mouse*", GROUP="input", MODE="0664"
      KERNEL=="js*", GROUP="input", MODE="0664"
      SUBSYSTEM=="input", GROUP="input", MODE="0664"
      #SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="render", MODE="0664"
    '';

    # Steam configuration
    programs.steam.enable = lib.mkIf cfg.steam.enable true;
    programs.steam.remotePlay.openFirewall = lib.mkIf cfg.steam.enable true;

    # Sunshine configuration
    security.wrappers.sunshine = mkIf cfg.sunshine.enable {
      owner = "root";
      group = "root";
      capabilities = "cap_sys_admin+p"; # For KMS
      source = "${pkgs.sunshine}/bin/sunshine";
    };

    # Systemd service that uses the security wrapper
    systemd.user.services.sunshine = mkIf cfg.sunshine.enable {
      description = "Sunshine game streaming server";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" "pipewire.service" "pipewire-pulse.service" "pipewire-game-sink.service" ];
      
      serviceConfig = {
        Type = "simple";
        ExecStart = "/run/wrappers/bin/sunshine";
        Restart = "on-failure";
        RestartSec = "5s";
      };
      
      environment = {
        HOME = "/home/${username}";
        XDG_RUNTIME_DIR = "/run/user/${toString config.users.users.${username}.uid}";
        GBM_BACKEND = "nvidia-drm";
        __GLX_VENDOR_LIBRARY_NAME = "nvidia";
      };
    };

    # Copy Sunshine configuration files
    system.activationScripts.sunshine-config = mkIf cfg.sunshine.enable {
      text = 
        let
          sunshineConf = pkgs.replaceVars ./sunshine.conf { inherit username; };
          # apps.json doesn't need username substitution, so use it directly
          appsJson = ./apps.json;
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

    # Gaming audio sink (now using separate scripts)
    systemd.user.services.pipewire-game-sink = {
      description = "Create persistent PipeWire game audio sink";
      wantedBy = [ "pipewire.service" ]; # Ensures it starts with PipeWire
      after = [ "pipewire.service" "wireplumber.service" ];
      before = [ "sunshine.service" ]; 

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true; 
        ExecStart = "${createGameSinkScript}/bin/create-game-sink"; 
        ExecStop = "${removeGameSinkScript}/bin/remove-game-sink";  
      };
    };
    
    # Firewall rules
    networking.firewall.allowedTCPPorts = lib.optionals cfg.sunshine.enable [ 47984 47989 48010 ];
    networking.firewall.allowedUDPPorts = lib.optionals cfg.sunshine.enable [ 47998 47999 48000 48002 48010 ];
  };
}
