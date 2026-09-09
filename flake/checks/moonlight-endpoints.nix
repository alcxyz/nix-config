{
  lib,
  pkgs,
}: let
  mkEndpoints = overrides: selectorAddresses:
    import ../../modules/nixos/services/moonlight-client/endpoints.nix {
      inherit lib pkgs;
      cfg =
        {
          streamLocalAddress = null;
          streamRemoteAddress = null;
          streamReadinessHost = null;
          browserStreamLocalAddress = null;
          browserStreamRemoteAddress = null;
          browserStreamHost = "browser-fixture";
          browserStreamEndpointMode = "lan-first";
          browserStreamSelectorProfileDirectory = null;
          browserStreamSelectorPort = 48000;
          enableCompositedSession = false;
        }
        // overrides;
      browserStreamEnabled = true;
      browserSelectorHost = "selector-fixture";
      browserSelectorLocalAddress = selectorAddresses.local;
      browserSelectorRemoteAddress = selectorAddresses.remote;
      selectorMoonlightExecutable = "unused-fixture-command";
    };
  addresses = {
    local = "192.168.50.2";
    remote = "203.0.113.2";
  };
  selectorOnly = mkEndpoints {} addresses;
  ordinary =
    mkEndpoints {
      browserStreamLocalAddress = addresses.local;
      browserStreamRemoteAddress = addresses.remote;
    }
    addresses;
  remoteOnly = mkEndpoints {browserStreamEndpointMode = "remote-only";} addresses;
  disabled = mkEndpoints {} {
    local = null;
    remote = null;
  };
  cases = [
    {
      command = lib.getExe selectorOnly.browserSelectorEndpointSetup;
      host = "selector-fixture";
      local = addresses.local;
      remote = addresses.remote;
      port = true;
    }
    {
      command = lib.getExe ordinary.browserSelectorEndpointSetup;
      host = "selector-fixture";
      local = addresses.local;
      remote = addresses.remote;
      port = true;
    }
    {
      command = lib.getExe ordinary.moonlightEndpointSetup;
      host = "browser-fixture";
      local = addresses.local;
      remote = addresses.remote;
      port = false;
    }
    {
      command = lib.getExe remoteOnly.browserSelectorEndpointSetup;
      host = "selector-fixture";
      local = addresses.remote;
      remote = addresses.remote;
      port = true;
    }
    {
      command = lib.getExe disabled.browserSelectorEndpointSetup;
      unchanged = true;
    }
  ];
in
  pkgs.runCommand "moonlight-endpoint-setup-contract" {nativeBuildInputs = [pkgs.python3];} ''
    python3 ${./test-moonlight-endpoints.py} ${pkgs.writeText "endpoint-cases.json" (builtins.toJSON cases)}
    touch "$out"
  ''
