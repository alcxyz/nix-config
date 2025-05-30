# modules/nixos/suites/gaming/default.nix
{ options, config, lib, pkgs, username, ... }: # username is 'alc'

with lib;
let
  cfg = config.suites.gaming;
in
{
  options.suites.gaming = with types; {
    enable = mkOption {
      type = bool;
      default = false;
      description = "Enable the gaming suite configurations, including Steam, Gamescope, and Sunshine, running under the main user.";
    };
  };

  config = mkIf cfg.enable {
    # Ensure your main user is in all necessary groups
    # Your `hosts/xyz/configuration.nix` already adds 'alc' to:
    # "networkmanager", "wheel", "vfio", "audio", "sound", "video", "input", "tty",
    # "docker", "podman", "deluge", "stash", "media", "kvm", "libvirtd"
    # This is good. The 'media' group is key for ROMs/shared game data.
    # 'audio', 'video', 'input' are essential.

    environment.systemPackages = with pkgs; [
      # Core gaming and streaming
      steam
      gamescope
      sunshine # Sunshine itself will be installed

      # Emulation frontend
      emulationstation-de

      # Common Emulators
      retroarchFull
      dolphin-emu
      pcsx2
      # yuzu-mainline
      # ryujinx

      # Utilities
      pipewire.utils
    ];

    services.sunshine = {
      enable = true;
      openFirewall = true;
      user = username; # Run Sunshine service process as your main user ('alc')
      group = users.users.${username}.group; # Run as your main user's primary group

      # By running as your user, Sunshine's commands will execute in your user's context,
      # having access to your DISPLAY, XAUTHORITY, DBUS_SESSION_BUS_ADDRESS,
      # and your Steam session/data.

      apps = {
        "Steam Big Picture (Gamescoped Games)" = {
          # This command now runs as 'alc' and should interact with your existing Steam session.
          # It might bring Steam to the foreground if already running, or launch it.
          do-cmd = "${pkgs.steam}/bin/steam -bigpicture";
          # If you prefer Steam's desktop mode:
          # do-cmd = "${pkgs.steam}/bin/steam";

          # Optional: Wrap Steam itself in Gamescope if you want its UI streamed via Gamescope too.
          # This is good if you intend for the gaming workspace to *always* be Gamescope'd.
          # do-cmd = "${pkgs.gamescope}/bin/gamescope -W 1920 -H 1080 -r 60 -b -- ${pkgs.steam}/bin/steam -bigpicture";
        };

        "EmulationStation-DE (Gamescoped)" = {
          # This also runs as 'alc'
          do-cmd = "${pkgs.gamescope}/bin/gamescope -W 1920 -H 1080 -r 60 -f -- ${pkgs.emulationstation-de}/bin/emulationstation-de";
        };
      };

      # Settings for Sunshine can still be applied if needed
      # settings = {
      #   # encoder_bitrate = 50000;
      # };
    };

    # IMPORTANT: Environment variables for services running as a user
    # When a system service runs as a regular user, it doesn't automatically inherit
    # the full graphical session environment (like DISPLAY, XAUTHORITY, WAYLAND_DISPLAY, DBUS_SESSION_BUS_ADDRESS).
    # Sunshine might need these to correctly launch GUI applications like Steam within your active session.
    #
    # There are several ways to handle this:
    # 1. Sunshine's own mechanisms (check its documentation for passing environment vars to commands).
    # 2. Systemd `PassEnvironment` or `EnvironmentFile` for the sunshine.service.
    # 3. A wrapper script for `do-cmd` that sources these variables.

    # For Hyprland (Wayland), the key variables are often:
    # DISPLAY (for XWayland apps like Steam)
    # WAYLAND_DISPLAY
    # XDG_RUNTIME_DIR
    # DBUS_SESSION_BUS_ADDRESS
    # XAUTHORITY (usually points to a file in XDG_RUNTIME_DIR for XWayland)

    # NixOS allows setting environment variables for systemd services:
    systemd.services.sunshine.serviceConfig = {
      # These are common variables needed for GUI apps to connect to your user's session.
      # They are typically set when you log in.
      # We need a way to get the *current* values for user 'alc'.
      # This can be tricky as they are session-specific.

      # Approach A: Hardcoding (less flexible, only works if they are static or you know them)
      # Environment = [
      #   "DISPLAY=:0" # Or whatever your XWayland display is
      #   "WAYLAND_DISPLAY=wayland-1" # Check `echo $WAYLAND_DISPLAY` in your session
      #   "XDG_RUNTIME_DIR=/run/user/${toString config.users.users.${username}.uid}"
      #   "DBUS_SESSION_BUS_ADDRESS=unix:path=${config.systemd.user.runtimeDir}/bus" # Check `echo $DBUS_SESSION_BUS_ADDRESS`
      #   "XAUTHORITY=${config.users.users.${username}.home}/.Xauthority" # Or path in XDG_RUNTIME_DIR
      # ];

      # Approach B (More Robust): Use a wrapper script for Sunshine's commands
      # that sources these variables from the user's environment or uses `systemd run --user ...`
      # This is generally preferred over hardcoding in the system service unit.
      # For now, we'll omit explicitly setting them here and see if Sunshine/Steam
      # can pick them up when Sunshine runs as your user. If not, this is the area to revisit.
      # Modern systems with systemd user sessions sometimes make this easier.
    };

    # Ensure programs.steam.enable = true; is set in your main configuration
    # (it is in your hosts/xyz/configuration.nix).
  };
}
