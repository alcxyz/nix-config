{
  audioOutputControl,
  browserSelectorEnabled,
  browserStreamEnabled,
  cfg,
  couchBrowser,
  directDrmBrowserEnabled,
  directDrmStreamEnabled,
  displayLayoutControl,
  displayMirrorToggle,
  kdeConnectDirectInputEnabled,
  kdeConnectExecutable,
  kdeConnectHyprlandInput,
  lib,
  mergedUiControl,
  modeStateFile,
  pkgs,
  sessionMode,
}: let
  couchStreamControl = pkgs.writeShellApplication {
    name = "couch-stream-control";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.procps
      pkgs.systemd
    ];
    text = ''
      case "''${1:-}" in
        start)
          systemctl --user start couch-moonlight-stream.service
          hyprctl dispatch workspace 1 >/dev/null 2>&1 || true
          ;;
        remote-browser)
          systemctl --user start couch-moonlight-browser-stream.service
          hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
          ;;
        private-browser)
          systemctl --user start couch-moonlight-browser-selector.service
          hyprctl dispatch workspace 3 >/dev/null 2>&1 || true
          ;;
        browser)
          ${
        if browserStreamEnabled
        then ''
          systemctl --user start couch-moonlight-browser-stream.service
          hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
        ''
        else if cfg.enableLocalBrowser
        then ''
          ${lib.getExe mergedUiControl} browser
          hyprctl dispatch workspace 2 >/dev/null 2>&1 || true
          if ! pgrep -u "$USER" -f -- ${lib.escapeShellArg cfg.browserProfileDirectory} \
            >/dev/null 2>&1; then
            ${lib.getExe couchBrowser} >/dev/null 2>&1 &
          fi
        ''
        else ''
          echo "No local or remote browser is configured" >&2
          exit 1
        ''
      }
          ;;
        *)
          echo "usage: couch-stream-control {start|remote-browser|private-browser|browser}" >&2
          exit 2
          ;;
      esac
    '';
  };

  closeActiveWindow = pkgs.writeShellApplication {
    name = "couch-close-active-window";
    runtimeInputs = [
      pkgs.gawk
      pkgs.hyprland
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      active_pid="$(hyprctl -j activewindow 2>/dev/null | jq -r '.pid // 0')"
      managed_unit=""

      if [[ "$active_pid" =~ ^[1-9][0-9]*$ ]] && [ -r "/proc/$active_pid/cgroup" ]; then
        cgroup="$(awk -F: '$1 == "0" { print $3; exit }' "/proc/$active_pid/cgroup")"
        case "$cgroup" in
          */couch-moonlight-stream.service)
            managed_unit=couch-moonlight-stream.service
            ;;
          */couch-moonlight-browser-stream.service)
            managed_unit=couch-moonlight-browser-stream.service
            ;;
          */couch-moonlight-browser-selector.service)
            managed_unit=couch-moonlight-browser-selector.service
            ;;
        esac
      fi

      if [ -n "$managed_unit" ]; then
        # A stalled decoder can leave Moonlight's GUI event loop unable to
        # honor Hyprland's close request. Stop the owning cgroup instead; the
        # unit applies a bounded graceful timeout before killing leftovers.
        exec systemctl --user --no-block stop "$managed_unit"
      fi

      exec hyprctl dispatch killactive
    '';
  };

  couchControlHelp = pkgs.writeShellApplication {
    name = "couch-control-help";
    text = ''
      dms="$HOME/.nix-profile/bin/dms"
      if [ ! -x "$dms" ]; then
        echo "DMS is not installed in the user profile" >&2
        exit 1
      fi

      exec "$dms" ipc call keybinds toggle xps-media-center
    '';
  };

  controllerPython = pkgs.python3.withPackages (pythonPackages: [pythonPackages.evdev]);
  renderSource = name: template: substitutions: let
    names = builtins.attrNames substitutions;
    # The file has already been read as source data. Drop only its path context
    # so an unchanged rendered script retains its content-derived store path.
    templateText = builtins.unsafeDiscardStringContext (builtins.readFile template);
    rendered =
      builtins.replaceStrings (
        map (parameter: "@${parameter}@") names
      ) (map (parameter: substitutions.${parameter}) names)
      templateText;
  in
    pkgs.writeText name rendered;
  optionalSource = condition: source:
    if condition
    then source
    else "    \n";

  controllerDaemonSource = renderSource "couch-controller.py" ./controller-daemon.py.in {
    controllerDeviceName = builtins.toJSON cfg.controllerDeviceName;
    controllerHoldSeconds = toString cfg.controllerHoldSeconds;
    couchStreamControl = lib.getExe couchStreamControl;
    couchControlHelp = lib.getExe couchControlHelp;
    displayMirrorToggle = lib.getExe displayMirrorToggle;
    displayLayoutControl = lib.getExe displayLayoutControl;
    audioOutputControl = lib.getExe audioOutputControl;
    controllerRemoteBrowserAction = optionalSource browserStreamEnabled "    \"remote_browser\": {ecodes.BTN_MODE, ecodes.BTN_NORTH},\n\n";
    controllerBrowserAction = optionalSource (browserStreamEnabled || cfg.enableLocalBrowser) "    \"browser\": {ecodes.BTN_THUMBL, ecodes.BTN_THUMBR},\n\n";
    controllerHelpAction = optionalSource (cfg.enableDms || cfg.enableMergedProfile) "    \"help\": {ecodes.BTN_SELECT, ecodes.BTN_SOUTH},\n\n";
    controllerMirrorAction = optionalSource cfg.enableMirrorToggle "    \"mirror\": {ecodes.BTN_SELECT, ecodes.BTN_START},\n\n";
    controllerLayoutAction = optionalSource cfg.enableAdaptiveDisplayLayout "    \"layout\": {ecodes.BTN_SELECT, ecodes.BTN_NORTH},\n\n";
    controllerAudioAction = optionalSource cfg.enableAudioOutputCycle "    \"audio\": {ecodes.BTN_SELECT, ecodes.BTN_WEST},\n\n";
    controllerRemoteBrowserCommand = optionalSource browserStreamEnabled "    \"remote_browser\": [\"${lib.getExe couchStreamControl}\", \"remote-browser\"],\n\n";
    controllerBrowserCommand = optionalSource (browserStreamEnabled || cfg.enableLocalBrowser) "    \"browser\": [\"${lib.getExe couchStreamControl}\", \"browser\"],\n\n";
    controllerHelpCommand = optionalSource (cfg.enableDms || cfg.enableMergedProfile) "    \"help\": [\"${lib.getExe couchControlHelp}\"],\n\n";
    controllerMirrorCommand = optionalSource cfg.enableMirrorToggle "    \"mirror\": [\"${lib.getExe displayMirrorToggle}\", \"toggle\"],\n\n";
    controllerLayoutCommand = optionalSource cfg.enableAdaptiveDisplayLayout "    \"layout\": [\"${lib.getExe displayLayoutControl}\", \"cycle\"],\n\n";
    controllerAudioCommand = optionalSource cfg.enableAudioOutputCycle "    \"audio\": [\"${lib.getExe audioOutputControl}\", \"cycle\"],\n\n";
  };

  controllerDaemon = pkgs.writeShellApplication {
    name = "couch-controller";
    text = ''
      exec ${controllerPython}/bin/python ${controllerDaemonSource}
    '';
  };

  directModeInputDaemonSource = renderSource "nixbox-direct-input.py" ./direct-input-daemon.py.in {
    modeStateFile = builtins.toJSON modeStateFile;
    controllerDeviceName = builtins.toJSON cfg.controllerDeviceName;
    controllerHoldSeconds = toString cfg.controllerHoldSeconds;
    kdeConnectDirectInput =
      if kdeConnectDirectInputEnabled
      then "True"
      else "False";
    sessionMode = lib.getExe sessionMode;
    directBrowserCommand = optionalSource directDrmBrowserEnabled "    \"direct-browser\": [\"${lib.getExe sessionMode}\", \"direct-browser\"],\n\n";
    directStreamCommand = optionalSource directDrmStreamEnabled "    \"direct-stream\": [\"${lib.getExe sessionMode}\", \"direct-stream\"],\n\n";
    directPrivateCommand = optionalSource (directDrmBrowserEnabled && browserSelectorEnabled) "    \"direct-private\": [\"${lib.getExe sessionMode}\", \"direct-private\"],\n\n";
    directPrivateKeyboardAction = optionalSource (directDrmBrowserEnabled && browserSelectorEnabled) "    if shift and ecodes.KEY_R in pressed:\n        return \"direct-private\"\n\n";
    directBrowserKeyboardAction = optionalSource directDrmBrowserEnabled "    if not shift and ecodes.KEY_R in pressed:\n        return \"direct-browser\"\n\n";
    directStreamKeyboardAction = optionalSource directDrmStreamEnabled "    if not shift and ecodes.KEY_M in pressed:\n        return \"direct-stream\"\n\n";
    directPrivateControllerAction = optionalSource (directDrmBrowserEnabled && browserSelectorEnabled) "    if (\n        state[\"hat_up\"]\n        and ecodes.BTN_START in pressed\n        and ecodes.BTN_TR in pressed\n    ):\n        return \"direct-private\"\n\n";
    directBrowserControllerAction = optionalSource directDrmBrowserEnabled "    if ecodes.BTN_MODE in pressed and ecodes.BTN_NORTH in pressed:\n        return \"direct-browser\"\n\n";
    directStreamControllerAction = optionalSource directDrmStreamEnabled "    if ecodes.BTN_MODE in pressed and ecodes.BTN_EAST in pressed:\n        return \"direct-stream\"\n\n";
  };

  directModeInputDaemon = pkgs.writeShellApplication {
    name = "nixbox-direct-input";
    text = ''
      exec ${controllerPython}/bin/python ${directModeInputDaemonSource}
    '';
  };

  # As above, this is source text that has already been read, not an undeclared
  # store path opened by a build.
  kdeConnectPointerShimSource = pkgs.writeText "kdeconnect-hypr-pointer-shim.c" (
    builtins.unsafeDiscardStringContext (builtins.readFile ./kdeconnect-pointer-shim.c)
  );

  kdeConnectPointerShim =
    pkgs.runCommandCC "kdeconnect-hypr-pointer-shim"
    {
      nativeBuildInputs = [pkgs.pkg-config];
      buildInputs = [
        pkgs.libx11
        pkgs.libxcb
        pkgs.libxi
        pkgs.libxtst
      ];
    }
    ''
      install -d "$out/lib"
      "$CC" \
        -shared \
        -fPIC \
        -Wall \
        -Wextra \
        -Werror \
        $(${pkgs.pkg-config}/bin/pkg-config --cflags x11 xcb xi xtst) \
        -o "$out/lib/libkdeconnect-hypr-pointer-shim.so" \
        ${kdeConnectPointerShimSource} \
        $(${pkgs.pkg-config}/bin/pkg-config --libs x11 xcb xi xtst) \
        -ldl
    '';

  kdeConnectSessionLauncher = pkgs.writeShellApplication {
    name = "nixbox-kdeconnect-session";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.xorg-server
    ];
    text = ''
      mode="$(
        tr -d '[:space:]' \
          < ${lib.escapeShellArg modeStateFile} \
          2>/dev/null \
          || true
      )"
      case "''${mode%%:*}" in
        direct-*) ;;
        *)
          export DISPLAY=:0
          exec ${kdeConnectExecutable} --replace
          ;;
      esac

      display_file="$(mktemp -p "''${XDG_RUNTIME_DIR:-/tmp}" kdeconnect-xvfb.XXXXXX)"
      xvfb_pid=
      kdeconnect_pid=

      cleanup() {
        trap - EXIT INT TERM
        if [ -n "$kdeconnect_pid" ]; then
          kill "$kdeconnect_pid" >/dev/null 2>&1 || true
        fi
        if [ -n "$xvfb_pid" ]; then
          kill "$xvfb_pid" >/dev/null 2>&1 || true
        fi
        rm -f "$display_file"
      }
      terminate() {
        exit 0
      }
      trap cleanup EXIT
      trap terminate INT TERM

      ${lib.getExe' pkgs.xorg-server "Xvfb"} \
        -displayfd 3 \
        -nolisten tcp \
        -noreset \
        -screen 0 2560x1440x24 \
        3>"$display_file" &
      xvfb_pid=$!

      for _attempt in $(seq 1 50); do
        if [ -s "$display_file" ]; then
          break
        fi
        if ! kill -0 "$xvfb_pid" >/dev/null 2>&1; then
          echo "KDE Connect Xvfb exited before becoming ready" >&2
          exit 1
        fi
        sleep 0.1
      done
      if [ ! -s "$display_file" ]; then
        echo "KDE Connect Xvfb did not become ready" >&2
        exit 1
      fi

      display_number="$(tr -d '[:space:]' < "$display_file")"
      export DISPLAY=":$display_number"
      ${kdeConnectExecutable} --replace &
      kdeconnect_pid=$!
      wait "$kdeconnect_pid"
    '';
  };

  pointerSync = kdeConnectHyprlandInput;

  kdeConnectDbusServiceOverride = pkgs.writeTextFile {
    name = "kdeconnect-dbus-systemd-service";
    destination = "/share/dbus-1/services/org.kde.kdeconnect.service";
    text = ''
      [D-BUS Service]
      Name=org.kde.kdeconnect
      Exec=${pkgs.systemd}/bin/systemctl --user start kdeconnect.service
      SystemdService=kdeconnect.service
    '';
  };
in {
  inherit
    closeActiveWindow
    controllerDaemon
    couchControlHelp
    couchStreamControl
    directModeInputDaemon
    kdeConnectDbusServiceOverride
    kdeConnectSessionLauncher
    pointerSync
    ;
}
