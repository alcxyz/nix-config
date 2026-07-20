{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.moonlightEndpoints;
  preferenceDomain = "com.moonlight-stream.Moonlight";
  preferenceFile =
    "${config.home.homeDirectory}/Library/Preferences/${preferenceDomain}.plist";
  policy = pkgs.writeText "moonlight-endpoint-policy.json" (builtins.toJSON cfg.hosts);
  reconcile = pkgs.writeShellApplication {
    name = "reconcile-moonlight-endpoints";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      set -eu

      preference_file=${lib.escapeShellArg preferenceFile}
      if [ ! -f "$preference_file" ]; then
        exit 0
      fi

      host_count="$(
        /usr/bin/defaults read ${lib.escapeShellArg preferenceDomain} "hosts.size" \
          2>/dev/null || printf '0\n'
      )"

      while IFS= read -r host; do
        hostname="$(printf '%s\n' "$host" | jq -r .hostname)"
        index=""
        for candidate in $(seq 1 "$host_count"); do
          current_hostname="$(
            /usr/bin/defaults read ${lib.escapeShellArg preferenceDomain} \
              "hosts.$candidate.hostname" 2>/dev/null || true
          )"
          if [ "$current_hostname" = "$hostname" ]; then
            index="$candidate"
            break
          fi
        done
        if [ -z "$index" ]; then
          continue
        fi

        local_address="$(printf '%s\n' "$host" | jq -r .localAddress)"
        remote_address="$(printf '%s\n' "$host" | jq -r .remoteAddress)"
        for assignment in \
          "localaddress=$local_address" \
          "manualaddress=$local_address" \
          "remoteaddress=$remote_address"; do
          field="''${assignment%%=*}"
          desired="''${assignment#*=}"
          key="hosts.$index.$field"
          current="$(
            /usr/bin/defaults read ${lib.escapeShellArg preferenceDomain} "$key" \
              2>/dev/null || true
          )"
          if [ "$current" != "$desired" ]; then
            /usr/bin/defaults write ${lib.escapeShellArg preferenceDomain} "$key" -string "$desired"
          fi
        done
      done < <(jq -c '.[]' ${policy})
    '';
  };
in
{
  options.programs.moonlightEndpoints = {
    enable = lib.mkEnableOption "declarative Moonlight host endpoint routing on macOS";

    hosts = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            hostname = lib.mkOption {
              type = lib.types.str;
              description = "Moonlight paired-host name.";
            };
            localAddress = lib.mkOption {
              type = lib.types.str;
              description = "Preferred address on the local network.";
            };
            remoteAddress = lib.mkOption {
              type = lib.types.str;
              description = "Fallback address used away from the local network.";
            };
          };
        }
      );
      default = [ ];
      description = "Paired Moonlight hosts whose endpoint order is reconciled.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "programs.moonlightEndpoints is currently supported only on macOS";
      }
    ];

    launchd.agents.moonlight-endpoint-reconcile = {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe reconcile) ];
        RunAtLoad = true;
        StartInterval = 60;
        ProcessType = "Background";
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/moonlight-endpoints.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/moonlight-endpoints.err.log";
      };
    };
  };
}
