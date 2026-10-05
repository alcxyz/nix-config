{
  configDir,
  lib,
  pkgs,
  ...
}: let
  mkWebLauncher = name: url:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [pkgs.xdg-utils];
      text = ''
        exec xdg-open ${lib.escapeShellArg url}
      '';
    };
  webLauncher = mkWebLauncher "t3code-web" "https://t3code.alc.xyz";
  bnWebLauncher = mkWebLauncher "t3code-bn-web" "https://t3code-bn.alc.xyz";
in {
  imports = ["${configDir}/modules/home-manager/services/t3code/default.nix"];

  # xyz is the canonical headless T3 environment. Keep both historical
  # desktop command names pointed at its web client so cached launchers and
  # compositor bindings cannot accidentally start a second local backend.
  home.file = {
    ".local/bin/t3code" = {
      executable = true;
      source = "${webLauncher}/bin/t3code-web";
    };
    ".local/bin/t3code-desktop" = {
      executable = true;
      source = "${webLauncher}/bin/t3code-web";
    };
  };

  # Override the package's Electron desktop entry with the canonical web
  # client. The Electron binary remains available from the package store for
  # explicit troubleshooting, but it is not part of the normal xyz workflow.
  xdg.desktopEntries.t3code = {
    name = "T3 Code (xyz)";
    comment = "Connect to the headless T3 Code service on xyz";
    icon = "t3code";
    exec = "${webLauncher}/bin/t3code-web";
    categories = ["Development"];
    settings.TryExec = "${webLauncher}/bin/t3code-web";
  };
  xdg.desktopEntries.t3code-bn = {
    name = "T3 Code bn-apps (xyz)";
    comment = "Connect to the bn-apps T3 Code instance on xyz";
    icon = "t3code";
    exec = "${bnWebLauncher}/bin/t3code-bn-web";
    categories = ["Development"];
    settings.TryExec = "${bnWebLauncher}/bin/t3code-bn-web";
  };

  services.t3code = {
    enable = true;
    channel = "fork"; # Select "upstream" to return to the upstream build.
    forkReleaseChannel = "nightly";
    port = 3773;
    # bn-apps work projects get their own server, so they never mix with
    # personal projects in the sidebar.
    instances.bn.port = 3774;
    autoUpdate = {
      packageFlakeUri = "git+https://git.alc.xyz/alcxyz/nix-packages.git?ref=promoted";
    };
  };
}
