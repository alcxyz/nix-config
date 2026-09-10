{
  configDir,
  lib,
  pkgs,
  ...
}: let
  webUrl = "https://t3code.alc.xyz";
  webLauncher = pkgs.writeShellApplication {
    name = "t3code-web";
    runtimeInputs = [pkgs.xdg-utils];
    text = ''
      exec xdg-open ${lib.escapeShellArg webUrl}
    '';
  };
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

  services.t3code = {
    enable = true;
    channel = "fork"; # Select "upstream" to return to the upstream build.
    port = 3773;
    autoUpdate = {
      packageFlakeUri = "git+https://git.alc.xyz/alcxyz/nix-packages.git?ref=dev";
      promotionFlakeUri = "git+https://git.alc.xyz/alcxyz/nix-config.git?ref=dev";
      calendar = lib.mkForce "*-*-* 09:30:00";
      randomizedDelaySec = lib.mkForce "0";
    };
  };
}
