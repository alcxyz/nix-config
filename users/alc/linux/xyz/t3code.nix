{
  config,
  configDir,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.t3code;
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

  # The desktop app is only a client here: it connects to the headless
  # servers over loopback (127.0.0.1:3773 and :3774, added once under
  # Settings > Connections with a `t3 pair` token) and never starts its own.
  # Its state lives apart from the servers' base directories, since a desktop
  # app pointed at a running server's base directory refuses to start.
  desktopHome = "${config.home.homeDirectory}/.t3-desktop";
  desktopSettings = "${desktopHome}/userdata/desktop-settings.json";
  # Follow the server's executable, so client and server change together.
  desktopExecutable =
    if cfg.autoUpdate.enable
    then "${config.home.homeDirectory}/.local/state/nix/profiles/ai-stack/bin/t3code-desktop"
    else "${cfg.package}/bin/t3code-desktop";
  desktopLauncher = pkgs.writeShellApplication {
    name = "t3code-desktop";
    text = ''
      export T3CODE_HOME=${lib.escapeShellArg desktopHome}
      # Nix replaces the app; its own updater must not.
      export T3CODE_DISABLE_AUTO_UPDATE=1
      exec ${lib.escapeShellArg desktopExecutable} "$@"
    '';
  };
in {
  imports = ["${configDir}/modules/home-manager/services/t3code/default.nix"];

  # Both historical command names open the desktop client; `t3code-web` keeps
  # the browser route for when the app is unavailable.
  home.file = {
    ".local/bin/t3code" = {
      executable = true;
      source = "${desktopLauncher}/bin/t3code-desktop";
    };
    ".local/bin/t3code-desktop" = {
      executable = true;
      source = "${desktopLauncher}/bin/t3code-desktop";
    };
    ".local/bin/t3code-web" = {
      executable = true;
      source = "${webLauncher}/bin/t3code-web";
    };
  };

  # The app writes this file itself (window bounds, preferences), so merge the
  # one setting that matters instead of linking a read-only copy.
  home.activation.t3codeDesktopClientOnly = lib.hm.dag.entryAfter ["writeBoundary"] ''
    settings=${lib.escapeShellArg desktopSettings}
    run mkdir -p "$(dirname "$settings")"
    if [ -s "$settings" ] && ${pkgs.jq}/bin/jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
      current=$(${pkgs.jq}/bin/jq -c . "$settings")
    else
      current='{}'
    fi
    if [ "$(printf '%s' "$current" | ${pkgs.jq}/bin/jq '.localEnvironmentEnabled')" != false ]; then
      if [[ -v DRY_RUN ]]; then
        echo "Would turn off the T3 desktop app's own server in $settings"
      else
        printf '%s' "$current" | ${pkgs.jq}/bin/jq '.localEnvironmentEnabled = false' > "$settings.tmp"
        mv "$settings.tmp" "$settings"
      fi
    fi
  '';

  xdg.desktopEntries.t3code = {
    name = "T3 Code (xyz)";
    comment = "T3 Code desktop app for the headless servers on xyz";
    icon = "t3code";
    exec = "${desktopLauncher}/bin/t3code-desktop";
    categories = ["Development"];
    settings = {
      TryExec = "${desktopLauncher}/bin/t3code-desktop";
      StartupWMClass = "com.t3tools.T3Code";
    };
  };
  xdg.desktopEntries.t3code-web = {
    name = "T3 Code web (xyz)";
    comment = "Open the headless T3 Code service on xyz in the browser";
    icon = "t3code";
    exec = "${webLauncher}/bin/t3code-web";
    categories = ["Development"];
    settings.TryExec = "${webLauncher}/bin/t3code-web";
  };
  xdg.desktopEntries.t3code-bn = {
    name = "T3 Code work web (xyz)";
    comment = "Open the work T3 Code instance on xyz in the browser";
    icon = "t3code";
    exec = "${bnWebLauncher}/bin/t3code-bn-web";
    categories = ["Development"];
    settings.TryExec = "${bnWebLauncher}/bin/t3code-bn-web";
  };

  services.t3code = {
    enable = true;
    port = 3773;
    # Work projects get their own server, so they never mix with
    # personal projects in the sidebar.
    instances.bn.port = 3774;
    autoUpdate = {
      packageFlakeUri = "git+https://git.alc.xyz/alcxyz/nix-packages.git?ref=promoted";
    };
  };
}
