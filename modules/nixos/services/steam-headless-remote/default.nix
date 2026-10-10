{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.steam-headless-remote;

  # The client may authenticate with this machine's SSH host identity only to
  # start or stop SteamHeadless on xyz. The corresponding key is bound to a
  # forced dispatcher there and cannot open a shell. Clients using this are at
  # home: reach xyz on the LAN even when NetBird's DNS resolves its name to the
  # overlay, and keep verifying xyz's host key.
  xyzLanAddress = config.services.moonlight-client.streamLocalAddress;
  mkSteamCommand = name: action:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [pkgs.openssh];
      text = ''
        exec ssh \
          -T \
          -i /etc/ssh/ssh_host_ed25519_key \
          -o IdentitiesOnly=yes \
          -o BatchMode=yes \
          -o ConnectTimeout=5 \
          ${lib.optionalString (xyzLanAddress != null) "-o HostKeyAlias=xyz -o Hostname=${lib.escapeShellArg xyzLanAddress}"} \
          root@xyz \
          ${lib.escapeShellArg action}
      '';
    };
  steamStart = mkSteamCommand "steam-start" "start";
  steamStop = mkSteamCommand "steam-stop" "stop";
  # Keep the old name available while callers migrate to steam-start.
  steamWake = mkSteamCommand "steam-wake" "wake";
in {
  options.services.steam-headless-remote = {
    enable = lib.mkEnableOption "starting and stopping SteamHeadless on xyz through its forced dispatcher";

    user = lib.mkOption {
      type = lib.types.str;
      description = "User allowed to run the Steam lifecycle commands, which need the host key, through sudo.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      steamStart
      steamStop
      steamWake
    ];

    security.sudo.extraRules = [
      {
        users = [cfg.user];
        commands = [
          {
            command = "${steamStart}/bin/steam-start";
            options = ["NOPASSWD"];
          }
          {
            command = "${steamStop}/bin/steam-stop";
            options = ["NOPASSWD"];
          }
          {
            command = "${steamWake}/bin/steam-wake";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];

    services.moonlight-client.streamHostStartCommand = ''
      /run/wrappers/bin/sudo -- ${steamStart}/bin/steam-start
    '';
  };
}
