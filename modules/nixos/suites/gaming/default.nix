# modules/nixos/suites/gaming/default.nix
{ options, config, lib, pkgs, username /* assuming username is passed as a specialArg */, ... }:

with lib;
let
  cfg = config.suites.gaming;
in
{
  options.suites.gaming = with types; {
    enable = mkOption {
      type = bool;
      default = false;
      description = "Enable the gaming suite configurations, including Steam, Gamescope, and Sunshine.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      # Core gaming and streaming
      steam # Already enabled via programs.steam.enable, but good for suite completeness
      gamescope
      sunshine

      # Emulation frontend (ES-DE)
      # Option 1: If available in nixpkgs (check `nix search nixpkgs emulationstation-de`)
      # emulationstation-de
      # Option 2: If using Flatpak (ensure services.flatpak.enable = true in main config)
      # You would then install ES-DE via `flatpak install flathub org.es_de.emulationstation-de`
      # For now, this package is a placeholder. We'll need to decide on the source.

      # Common Emulators (add more as needed)
      retroarchFull # Includes many cores
      dolphin-emu   # GameCube/Wii
      pcsx2         # PS2
      # yuzu-mainline # Switch (ensure you handle firmware/keys appropriately)
      # ryujinx       # Switch (ensure you handle firmware/keys appropriately)

      # Utilities for audio scripting and inspection
      pipewire.utils # For pw-cli, pw-cat, etc.
      # pavucontrol is already in your base nixos module
      # qpwgraph      # Optional: GUI for PipeWire graph
      # helvum        # Optional: Another GUI for PipeWire graph
    ];

    # Sunshine - Game Streaming Host
    services.sunshine = {
      enable = true;
      openFirewall = true; # Automatically open necessary firewall ports.
                           # If set to false, you'll need to manually add ports:
                           # TCP: 47984 (Web UI), 47989 (Control), 48010 (General)
                           # UDP: 47990 (Control), 47998 (Discovery), 47999 (Discovery), 48000 (Video/Audio), 48002 (Discovery), 48010 (Video/Audio)
                           # (Check Sunshine docs for the most up-to-date port list)

      # Ensure Sunshine runs with access to necessary resources.
      # The NixOS module usually handles adding the 'sunshine' user to 'video' and 'input' groups.
      # If hardware encoding issues arise, ensure NVIDIA drivers are correctly set up system-wide
      # (your hardware/nvidia.nix should cover this). Sunshine typically auto-detects NVENC.

      apps = {
        "Steam Big Picture (Gamescoped Games)" = {
          # This command launches Steam. Gamescope for individual games
          # will be handled by Steam's per-game launch options.
          # The user Sunshine runs as needs to be able to launch Steam.
          # Consider if Steam needs to be launched as your main user.
          # If so, Sunshine might need to run commands via `sudo -u ${username}` or similar,
          # which adds complexity. Often, running Steam under the sunshine user is fine
          # if its config/data directories are set up correctly or if it's a separate Steam instance.
          # For simplicity, let's assume Steam can be launched directly.
          # If Steam is already running under your user session, Sunshine might not be able to
          # launch another instance easily. This is a common point of friction.
          #
          # A common approach is to have Sunshine launch a script that ensures Steam is running
          # (or starts it) in the correct user session, potentially using systemd user services.
          #
          # For now, a direct launch:
          do-cmd = "${pkgs.steam}/bin/steam -bigpicture";
          # If you prefer Steam's desktop mode:
          # do-cmd = "${pkgs.steam}/bin/steam";

          # Alternative: Wrap Steam itself in Gamescope if you only interact with it
          # via streaming or on the dedicated gaming workspace.
          # do-cmd = "${pkgs.gamescope}/bin/gamescope -W 1920 -H 1080 -r 60 -b -- ${pkgs.steam}/bin/steam -bigpicture";
        };

        # Optional: Direct entry for ES-DE (if you want to launch it outside of Steam sometimes)
        "EmulationStation-DE (Gamescoped)" = {
          # This assumes ES-DE is installed and in PATH or you provide the full path.
          # Replace `/path/to/your/emulationstation-de` with the actual command.
          # This command needs to be determined based on how ES-DE is installed.
          # If using Flatpak: "flatpak run org.es_de.emulationstation-de"
          do-cmd = "${pkgs.gamescope}/bin/gamescope -W 1920 -H 1080 -r 60 -f -- /path/to/your/emulationstation-de";
          # Use -f for fullscreen gamescope.
        };
      };

      # If you need to pass specific settings to sunshine.conf, you can use:
      # settings = {
      #   # Example for NVIDIA, though often auto-detected:
      #   # hevc_encoder = "nvenc";
      #   # av1_encoder = "nvenc";
      #   # encoder_bitrate = 50000; # Example bitrate in kbps
      # };
    };

    # Ensure necessary groups for gaming/streaming related tasks.
    # Your main user `${username}` is already in "audio", "video", "input".
    # The `sunshine` user created by its service module should also be in these.
    users.users.sunshine.extraGroups = [ "audio" "video" "input" ];


    # If ES-DE is installed via Flatpak, enable Flatpak support
    # services.flatpak.enable = true; # You might already have this.
  };
}
