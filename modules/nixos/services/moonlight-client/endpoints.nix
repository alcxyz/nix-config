{
  cfg,
  lib,
  pkgs,
  browserStreamEnabled,
  browserSelectorHost,
  browserSelectorLocalAddress,
  browserSelectorRemoteAddress,
  selectorMoonlightExecutable,
}: let
  streamEndpointPolicyEnabled = cfg.streamLocalAddress != null && cfg.streamRemoteAddress != null;
  browserStreamEndpointPolicyEnabled =
    cfg.browserStreamLocalAddress != null && cfg.browserStreamRemoteAddress != null;
  browserSelectorEndpointPolicyEnabled =
    browserSelectorLocalAddress != null && browserSelectorRemoteAddress != null;
  browserStreamReadinessHosts =
    if browserStreamEndpointPolicyEnabled
    then
      lib.unique (
        if cfg.browserStreamEndpointMode == "lan-only"
        then [cfg.browserStreamLocalAddress]
        else if cfg.browserStreamEndpointMode == "remote-only"
        then [cfg.browserStreamRemoteAddress]
        else [
          cfg.browserStreamLocalAddress
          cfg.browserStreamRemoteAddress
        ]
      )
    else lib.optional browserStreamEnabled cfg.browserStreamHost;
  streamReadinessHosts =
    if streamEndpointPolicyEnabled
    then
      lib.unique (
        if cfg.streamEndpointMode == "lan-only"
        then [cfg.streamLocalAddress]
        else if cfg.streamEndpointMode == "remote-only"
        then [cfg.streamRemoteAddress]
        else [
          cfg.streamLocalAddress
          cfg.streamRemoteAddress
        ]
      )
    else lib.optional (cfg.streamReadinessHost != null) cfg.streamReadinessHost;
  reconcileMoonlightEndpoints = pkgs.writeShellApplication {
    name = "reconcile-moonlight-endpoints";
    runtimeInputs = [pkgs.python3];
    text = ''
      exec python3 ${./reconcile-endpoints.py} "$@"
    '';
  };
  mkMoonlightEndpointSetup = name: profileDirectory: reconcileStream: reconcileBrowser: selector: let
    reconciliationEnabled =
      (reconcileStream && streamEndpointPolicyEnabled)
      || (
        reconcileBrowser
        && (
          if selector
          then browserSelectorEndpointPolicyEnabled
          else browserStreamEndpointPolicyEnabled
        )
      );
  in
    pkgs.writeShellApplication {
      name = "moonlight-endpoint-setup-${name}";
      text = ''
        ${lib.optionalString reconciliationEnabled ''
          config_file=${
            if profileDirectory == null
            then ''"$HOME/.config/Moonlight Game Streaming Project/Moonlight.conf"''
            else lib.escapeShellArg "${profileDirectory}/config/Moonlight Game Streaming Project/Moonlight.conf"
          }
        ''}
        ${lib.optionalString (reconcileStream && streamEndpointPolicyEnabled) ''
          ${lib.getExe reconcileMoonlightEndpoints} \
            "$config_file" \
            ${lib.escapeShellArg cfg.streamHost} \
            ${lib.escapeShellArg cfg.streamEndpointMode} \
            ${lib.escapeShellArg cfg.streamLocalAddress} \
            ${lib.escapeShellArg cfg.streamRemoteAddress}
        ''}
        ${lib.optionalString (reconcileBrowser && browserStreamEndpointPolicyEnabled) ''
          ${lib.getExe reconcileMoonlightEndpoints} \
            "$config_file" \
            ${lib.escapeShellArg (
            if selector
            then browserSelectorHost
            else cfg.browserStreamHost
          )} \
            ${lib.escapeShellArg cfg.browserStreamEndpointMode} \
            ${
            lib.escapeShellArg (
              if selector
              then browserSelectorLocalAddress
              else cfg.browserStreamLocalAddress
            )
          } \
            ${
            lib.escapeShellArg (
              if selector
              then browserSelectorRemoteAddress
              else cfg.browserStreamRemoteAddress
            )
          } ${lib.optionalString selector ''
            ${
              lib.escapeShellArg (
                if cfg.browserStreamSelectorPort == null
                then ""
                else toString cfg.browserStreamSelectorPort
              )
            } \
            ${lib.escapeShellArg cfg.browserStreamHost}
          ''}
        ''}
      '';
    };
  moonlightEndpointSetup = mkMoonlightEndpointSetup "default" null true true false;
  browserSelectorEndpointSetup =
    mkMoonlightEndpointSetup "browser-selector" cfg.browserStreamSelectorProfileDirectory false true
    true;
  browserSelectorPair = pkgs.writeShellApplication {
    name = "couch-moonlight-pair-private";
    text = ''
      if [ "$#" -ne 1 ] || ! [[ "$1" =~ ^[0-9]{4}$ ]]; then
        echo "usage: couch-moonlight-pair-private FOUR_DIGIT_PIN" >&2
        exit 2
      fi
      exec ${pkgs.coreutils}/bin/env \
        QT_QPA_PLATFORM=${
        lib.escapeShellArg (
          if cfg.enableCompositedSession
          then cfg.moonlightPlatform
          else "offscreen"
        )
      } \
        ${selectorMoonlightExecutable} pair --pin "$1" ${
        lib.escapeShellArg (
          if browserSelectorLocalAddress == null
          then browserSelectorHost
          else
            browserSelectorLocalAddress
            + lib.optionalString (
              cfg.browserStreamSelectorPort != null
            ) ":${toString cfg.browserStreamSelectorPort}"
        )
      }
    '';
  };
in {
  inherit
    browserSelectorEndpointSetup
    browserSelectorPair
    browserStreamEndpointPolicyEnabled
    browserStreamReadinessHosts
    moonlightEndpointSetup
    streamEndpointPolicyEnabled
    streamReadinessHosts
    ;
}
