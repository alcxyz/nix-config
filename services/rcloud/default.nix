{ options
, config
, lib
, pkgs
, ...
}:
with lib;
with lib.custom; let
  cfg = config.system.shell;
in
{
  options.system.shell = with types; {
    shell = mkOpt (enum [ "nushell" "bash" "zsh" ]) "nushell" "What shell to use";
  };

  config = {

# ~/.config/nixpkgs/home.nix (or wherever your home.nix is)
{ pkgs, config, ... }:

let
  # Define paths relative to the user's home directory
  rcloneConfigPath = "${config.home.homeDirectory}/.config/rclone/rclone.conf";
  rcloneLogDir = "${config.home.homeDirectory}/.cache/rclone"; # Or use xdg.cacheHome
  gdriveLocalDir = "${config.home.homeDirectory}/gdrive_local";
  dropboxLocalDir = "${config.home.homeDirectory}/dropbox_local";
in
{
  home.packages = [ pkgs.rclone ];

  # Optional: Create the local sync directories if they don't exist
  # Though you'll likely create these manually or rclone will.
  # home.file."${gdriveLocalDir}".source = pkgs.runCommand "empty-dir" {} "mkdir -p $out";
  # home.file."${dropboxLocalDir}".source = pkgs.runCommand "empty-dir" {} "mkdir -p $out";

  # Ensure the rclone log directory exists
  # This creates an empty directory managed by home-manager
  home.file."${rcloneLogDir}" = {
    source = pkgs.runCommand "empty-dir" {} "mkdir -p $out";
    recursive = true;
  };

  # Note: You will still need to run `rclone config` manually once
  # to generate the ${rcloneConfigPath} file with your tokens.
  # For managing the rclone.conf content declaratively with secrets,
  # you'd look into tools like sops-nix or agenix.

  systemd.user.services."rclone-gdrive-sync" = {
    Unit = {
      Description = "Rclone sync for Google Drive";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = ''
        ${pkgs.rclone}/bin/rclone sync \
          "${gdriveLocalDir}" \
          gdrive:NixOS_Sync \
          --config "${rcloneConfigPath}" \
          --verbose \
          --log-file "${rcloneLogDir}/gdrive-sync.log" \
          --create-empty-src-dirs
      '';
      # Consider adding --retries 3, --low-level-retries 10 for robustness
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
    };
    Install = {
      WantedBy = [ "timers.target" ]; # This enables the timer
    };
  };

  # Similar service and timer for Dropbox
  systemd.user.services."rclone-dropbox-sync" = {
    Unit = {
      Description = "Rclone sync for Dropbox";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = ''
        ${pkgs.rclone}/bin/rclone sync \
          "${dropboxLocalDir}" \
          dropbox_personal:NixOS_Sync \
          --config "${rcloneConfigPath}" \
          --verbose \
          --log-file "${rcloneLogDir}/dropbox-sync.log" \
          --create-empty-src-dirs
      '';
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
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  # If you haven't already, ensure lingering is enabled for your user
  # so user services run even without a graphical session.
  # This is typically done in /etc/nixos/configuration.nix:
  # users.users.yourusername.linger = true;
  # Or if you manage your user fully with home-manager, it might have an option.
  # However, `linger` is a system-level property of the user account.
}

