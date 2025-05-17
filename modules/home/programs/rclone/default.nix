{
  options,
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfg = config.programs.rclone;
  # Define paths relative to the user's home directory (Home Manager handles these)
  rcloneConfigPath = "${config.home.homeDirectory}/.config/rclone/rclone.conf";
  # Using xdg.cacheHome is generally preferred for cache files
  rcloneLogDir = "${config.xdg.cacheHome}/rclone";
  gdriveLocalDir = "${config.home.homeDirectory}/gdrive_local"; # Assuming this is the desired local sync location
  dropboxLocalDir = "${config.home.homeDirectory}/dropbox_local"; # Assuming this is the desired local sync location
in
{
  options.programs.rclone = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Home Manager configuration for Rclone sync services.";
    };
  };

  config = mkIf cfg.enable {
    # Install Rclone package
    home.packages = [ pkgs.rclone ];

    # Ensure the rclone log directory exists
    # This creates an empty directory managed by home-manager
    home.file."${rcloneLogDir}" = {
      source = pkgs.runCommand "empty-dir" {} "mkdir -p $out";
      recursive = true;
    };

    # Systemd user service and timer for Google Drive sync
    systemd.user.services."rclone-gdrive-sync" = {
      Unit = {
        Description = "Rclone sync for Google Drive";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Type = "oneshot"; # oneshot is appropriate for a simple sync
        ExecStart = ''
          ${pkgs.rclone}/bin/rclone sync \
            "${gdriveLocalDir}" \
            gdrive:NixOS_Sync \
            --config "${rcloneConfigPath}" \
            --verbose \
            --log-file "${rcloneLogDir}/gdrive-sync.log" \
            --create-empty-src-dirs
        '';
        # Consider adding --retries 3, --low-level-retries 10 for robustness if needed
        # Restart=on-failure and RestartSec=5s might be better if the sync is expected to run continuously or on failure
        # For a timer, oneshot is generally fine.
      };
      Install = {
        WantedBy = [ "default.target" ]; # Target for user services
      };
    };

    systemd.user.timers."rclone-gdrive-sync" = {
      Unit = {
        Description = "Timer for Rclone Google Drive sync";
      };
      Timer = {
        OnCalendar = "hourly"; # e.g., "*-*-* *:0/15:0" for every 15 mins
        Persistent = true;   # Run on next boot if missed
        Unit = "rclone-gdrive-sync.service";
        # AccuracySec = "1min"; # Optional: Schedule events more accurately
      };
      Install = {
        WantedBy = [ "timers.target" ]; # This enables the timer
      };
    };

    # Similar service and timer for Dropbox sync
    systemd.user.services."rclone-dropbox-sync" = {
      Unit = {
        Description = "Rclone sync for Dropbox";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Type = "oneshot"; # oneshot is appropriate for a simple sync
        ExecStart = ''
          ${pkgs.rclone}/bin/rclone sync \
            "${dropboxLocalDir}" \
            dropbox_personal:NixOS_Sync \
            --config "${rcloneConfigPath}" \
            --verbose \
            --log-file "${rcloneLogDir}/dropbox-sync.log" \
            --create-empty-src-dirs
        '';
        # Consider adding --retries 3, --low-level-retries 10 for robustness if needed
        # Restart=on-failure and RestartSec=5s might be better if the sync is expected to run continuously or on failure
        # For a timer, oneshot is generally fine.
      };
      Install = {
        WantedBy = [ "default.target" ]; # Target for user services
      };
    };

    systemd.user.timers."rclone-dropbox-sync" = {
      Unit = {
        Description = "Timer for Rclone Dropbox sync";
      };
      Timer = {
        OnCalendar = "hourly";
        Persistent = true;
        Unit = "rclone-dropbox-sync.service";
        # AccuracySec = "1min"; # Optional: Schedule events more accurately
      };
      Install = {
        WantedBy = [ "timers.target" ];
      };
    };

    # Note: You will still need to run `rclone config` manually once
    # to generate the ${rcloneConfigPath} file (~/.config/rclone/rclone.conf)
    # with your tokens. For managing the rclone.conf content declaratively with secrets,
    # you'd look into tools like sops-nix or agenix.

    # Also, ensure lingering is enabled for your user on the system side
    # if you want user services/timers to run without a graphical session.
    # This is a system-level user configuration option: users.users.yourusername.linger = true;

  };
}