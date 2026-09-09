{
  audioOutputControl,
  autoLayoutExternalOutputs,
  browserSelectorEnabled,
  browserStreamEnabled,
  cfg,
  closeActiveWindow,
  controllerDaemon,
  couchBrowser,
  couchBrowserNewWindow,
  couchBrowserStartup,
  couchControlHelp,
  couchFallbackBrowser,
  couchStreamControl,
  couchTerminal,
  couchWorkspace,
  defaultOutputMode,
  directDrmBrowserEnabled,
  directDrmBrowserSelectorSession,
  directDrmBrowserSession,
  directDrmStreamEnabled,
  directDrmStreamSession,
  displayLayoutControl,
  displayMirrorToggle,
  dynamicExternalLayoutEnabled,
  dynamicMonitorConfigFile,
  lib,
  mergedDmsServiceControl,
  mirrorOutputMode,
  mirrorSourceOutputs,
  modeStateFile,
  moonlightSession,
  persistentDirectDrmBrowserDefault,
  pkgs,
  pointerSync,
  protectedBrowser,
  sessionMode,
  sessionSplashLaunch,
  softwareMirror,
}: let
  couchApplications = pkgs.runCommand "couch-session-applications" {} ''
    mkdir -p "$out/share/applications"

    ${lib.optionalString cfg.enableLocalBrowser ''
      cat > "$out/share/applications/couch-browser.desktop" <<EOF
      [Desktop Entry]
      Name=Helium (Couch)
      Comment=Open the couch web browser
      Exec=${lib.getExe couchBrowser}
      Icon=helium
      Terminal=false
      Type=Application
      Categories=Network;WebBrowser;
      EOF
    ''}

    ${lib.optionalString (cfg.enableLocalBrowser && cfg.fallbackBrowserPackage != null) ''
      cat > "$out/share/applications/couch-browser-fallback.desktop" <<EOF
      [Desktop Entry]
      Name=Brave (Couch fallback)
      Comment=Open the compatibility web browser
      Exec=${lib.getExe couchFallbackBrowser.package}
      Icon=brave-browser
      Terminal=false
      Type=Application
      Categories=Network;WebBrowser;
      EOF
    ''}

    ${lib.optionalString browserStreamEnabled ''
      cat > "$out/share/applications/couch-remote-browser.desktop" <<EOF
      [Desktop Entry]
      Name=Helium (Remote)
      Comment=Stream the public Helium browser through Moonlight and Wolf
      Exec=${lib.getExe couchStreamControl} remote-browser
      Icon=helium
      Terminal=false
      Type=Application
      Categories=Network;WebBrowser;
      EOF
    ''}

    ${lib.optionalString browserSelectorEnabled ''
      cat > "$out/share/applications/couch-private-browser.desktop" <<EOF
      [Desktop Entry]
      Name=User (Remote)
      Comment=Open the PIN-protected remote user profile
      Exec=${lib.getExe couchStreamControl} private-browser
      Icon=system-users
      Terminal=false
      Type=Application
      Categories=Network;WebBrowser;
      EOF
    ''}

    ${lib.optionalString directDrmBrowserEnabled ''
      cat > "$out/share/applications/couch-direct-drm-browser.desktop" <<EOF
      [Desktop Entry]
      Name=Helium (Direct display)
      Comment=Stream Helium with Moonlight owning the display
      Exec=${lib.getExe sessionMode} direct-browser
      Icon=helium
      Terminal=false
      Type=Application
      Categories=Network;WebBrowser;
      EOF

      ${lib.optionalString browserSelectorEnabled ''
        cat > "$out/share/applications/couch-direct-drm-private.desktop" <<EOF
        [Desktop Entry]
        Name=User (Direct display)
        Comment=Open the protected remote user profile with Moonlight owning the display
        Exec=${lib.getExe sessionMode} direct-private
        Icon=system-users
        Terminal=false
        Type=Application
        Categories=Network;WebBrowser;
        EOF
      ''}
    ''}

    ${lib.optionalString directDrmStreamEnabled ''
      cat > "$out/share/applications/couch-direct-drm-stream.desktop" <<EOF
      [Desktop Entry]
      Name=Steam Stream (Direct display)
      Comment=Stream Steam with Moonlight owning the display
      Exec=${lib.getExe sessionMode} direct-stream
      Icon=steam
      Terminal=false
      Type=Application
      Categories=Game;
      EOF
    ''}

    ${lib.optionalString cfg.enableControllerShortcuts ''
      cat > "$out/share/applications/couch-steam-stream.desktop" <<EOF
      [Desktop Entry]
      Name=Steam Stream
      Comment=Start Steam Big Picture through Moonlight
      Exec=${lib.getExe couchStreamControl} start
      Icon=steam
      Terminal=false
      Type=Application
      Categories=Game;
      EOF
    ''}

    ${lib.optionalString (cfg.desktopSessionCommand != null) ''
      cat > "$out/share/applications/xps-desktop-mode.desktop" <<EOF
      [Desktop Entry]
      Name=Switch to Desktop Mode
      Comment=Leave the couch session and start the normal desktop
      Exec=${lib.getExe sessionMode} desktop
      Icon=preferences-desktop
      Terminal=false
      Type=Application
      Categories=System;
      EOF

      cat > "$out/share/applications/xps-couch-mode.desktop" <<EOF
      [Desktop Entry]
      Name=Switch to Couch Mode
      Comment=Leave the desktop and start the TV couch session
      Exec=${lib.getExe sessionMode} couch
      Icon=video-display
      Terminal=false
      Type=Application
      Categories=System;
      EOF

      ${lib.optionalString cfg.enableMergedProfile ''
        cat > "$out/share/applications/xps-merged-mode.desktop" <<EOF
        [Desktop Entry]
        Name=Switch to Merged Couch Mode
        Comment=Use the controller-first TV session with an auto-hiding DMS shell
        Exec=${lib.getExe sessionMode} merged
        Icon=video-display
        Terminal=false
        Type=Application
        Categories=System;
        EOF
      ''}
    ''}
  '';

  hyprlandConfig = pkgs.writeText "moonlight-hyprland.conf" ''
    monitor = , ${defaultOutputMode}, auto, ${toString cfg.outputScale}
    ${lib.concatMapStringsSep "\n" (
        output: "monitor = ${output}, ${mirrorOutputMode}, 0x0, ${toString cfg.outputScale}"
      )
      mirrorSourceOutputs}
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        output: source: "monitor = ${output}, ${mirrorOutputMode}, 0x0, ${toString cfg.outputScale}, mirror, ${source}"
      )
      cfg.mirrorOutputs
    )}
    ${lib.concatStringsSep "\n" (map (rule: "monitor = ${rule}") cfg.extraMonitorRules)}
    ${lib.concatStringsSep "\n" (map (rule: "workspace = ${rule}") cfg.extraWorkspaceRules)}
    ${lib.optionalString dynamicExternalLayoutEnabled "source = ${dynamicMonitorConfigFile}"}
    ${lib.optionalString cfg.disableInternalDisplay ''
      monitor = eDP-1, disable
      monitor = LVDS-1, disable
    ''}

    env = QT_QPA_PLATFORM,wayland
    env = QT_QPA_PLATFORMTHEME,gtk3
    env = QT_QPA_PLATFORMTHEME_QT6,gtk3
    ${lib.optionalString (cfg.cursorThemePackage != null) ''
      env = XCURSOR_THEME,${cfg.cursorTheme}
      env = XCURSOR_SIZE,${toString cfg.cursorSize}
    ''}

    exec-once = ${pkgs.systemd}/bin/systemctl --user import-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP DBUS_SESSION_BUS_ADDRESS
    ${lib.optionalString cfg.enableKdeConnect "exec-once = ${pkgs.systemd}/bin/systemctl --user restart kdeconnect.service"}
    exec-once = ${pkgs.systemd}/bin/systemctl --user start waynergy.service
    exec-once = ${pkgs.systemd}/bin/systemctl --user start xdg-desktop-portal-gtk.service
    ${lib.optionalString dynamicExternalLayoutEnabled "exec-once = ${lib.getExe autoLayoutExternalOutputs}"}
    ${lib.optionalString (
      cfg.sessionSplashCommand != null
    ) "exec-once = ${lib.getExe sessionSplashLaunch}"}
    ${lib.optionalString cfg.autoStartBrowser "exec-once = ${
      lib.getExe (
        if cfg.preferRemoteBrowserAtStartup
        then couchBrowserStartup
        else couchBrowser
      )
    }"}
    ${lib.optionalString cfg.autoStartStream "exec-once = [workspace 1 silent] ${lib.getExe moonlightSession}"}
    ${lib.optionalString cfg.enableControllerShortcuts "exec-once = ${lib.getExe controllerDaemon}"}
    ${lib.optionalString cfg.enableAudioOutputCycle "exec-once = ${lib.getExe audioOutputControl} initialize"}
    # Hyprland's portal does not implement RemoteDesktop. Keep KDE Connect and
    # couch browsers on XWayland so its phone keyboard, clicks, and scrolling
    # can be injected through XTest. Translate XTest-only pointer movement into
    # Hyprland coordinates; the bridge ignores native physical/Wayland motion.
    ${lib.optionalString cfg.enableKdeConnect "exec-once = ${lib.getExe pointerSync}"}
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        output: source: "exec-once = ${lib.getExe softwareMirror} ${lib.escapeShellArg output} ${lib.escapeShellArg source}"
      )
      cfg.softwareMirrorOutputs
    )}
    # Import the live compositor environment immediately above, then hand DMS
    # to systemd so a transient startup failure or later crash cannot leave the
    # shell absent for the remainder of the session.
    ${lib.optionalString cfg.enableDms "exec-once = ${pkgs.systemd}/bin/systemctl --user start couch-dms.service"}
    ${lib.optionalString cfg.enableMergedProfile "exec-once = ${lib.getExe mergedDmsServiceControl}"}

    input {
      kb_layout = ${cfg.keyboardLayouts}
      kb_options = ${cfg.keyboardOptions}
      numlock_by_default = true

      touchpad {
        natural_scroll = true
      }
    }

    # The couch controls must remain available while Moonlight or another
    # fullscreen client asks the compositor to inhibit global shortcuts.
    binds {
      disable_keybind_grabbing = true
    }

    general {
      gaps_in = 0
      gaps_out = 0
      border_size = 0
    }

    decoration {
      rounding = 0

      shadow {
        enabled = false
      }
    }

    animations {
      enabled = false
    }

    misc {
      disable_hyprland_logo = true
      disable_splash_rendering = true
      background_color = rgb(0b0c0f)
    }

    cursor {
      # Couch pointers are often controlled from a phone or another computer.
      # Keep the cursor visible long enough to reacquire it between gestures.
      inactive_timeout = ${toString cfg.remotePointerInactiveTimeout}
      # Network input backends can expose absolute axes even when they are
      # semantically mice. Never let that classification hide Waynergy or KDE
      # Connect motion; retain the normal inactivity timeout above.
      hide_on_touch = false
    }

    windowrule = match:class CouchBrowser, workspace 2
    bind = SUPER, 1, exec, ${lib.getExe couchWorkspace} switch 1
    bind = SUPER, 2, exec, ${lib.getExe couchWorkspace} switch 2
    bind = SUPER, 3, exec, ${lib.getExe couchWorkspace} switch 3
    bind = SUPER, 4, exec, ${lib.getExe couchWorkspace} switch 4
    bind = SUPER, 5, exec, ${lib.getExe couchWorkspace} switch 5
    bind = SUPER, 6, exec, ${lib.getExe couchWorkspace} switch 6
    bind = SUPER, 7, exec, ${lib.getExe couchWorkspace} switch 7
    bind = SUPER, 8, exec, ${lib.getExe couchWorkspace} switch 8
    bind = SUPER, 9, exec, ${lib.getExe couchWorkspace} switch 9
    ${
      if cfg.enableControllerShortcuts
      then "bind = SUPER, M, exec, ${lib.getExe couchStreamControl} start"
      else "bind = SUPER, M, workspace, 1"
    }
    bind = SUPER, B, exec, ${lib.getExe couchStreamControl} browser
    ${lib.optionalString browserStreamEnabled "bind = SUPER, R, exec, ${lib.getExe couchStreamControl} remote-browser"}
    ${lib.optionalString browserSelectorEnabled "bind = SUPER SHIFT, R, exec, ${lib.getExe couchStreamControl} private-browser"}
    ${lib.optionalString cfg.enableMirrorToggle "bind = SUPER SHIFT, M, exec, ${lib.getExe displayMirrorToggle} toggle"}
    ${lib.optionalString cfg.enableAdaptiveDisplayLayout "bind = SUPER SHIFT, D, exec, ${lib.getExe displayLayoutControl} cycle"}
    ${lib.optionalString cfg.enableAudioOutputCycle "bind = SUPER SHIFT, A, exec, ${lib.getExe audioOutputControl} cycle"}
    bind = SUPER, H, exec, ${lib.getExe couchControlHelp}
    ${lib.optionalString cfg.enableLocalBrowser "bind = SUPER, V, exec, ${lib.getExe couchBrowserNewWindow}"}
    ${lib.optionalString (
      cfg.protectedBrowserPackage != null
    ) "bind = SUPER, Z, exec, ${lib.getExe protectedBrowser}"}
    ${lib.optionalString cfg.enableLocalUtilities "bind = ALT, RETURN, exec, ${lib.getExe couchTerminal}"}
    ${lib.optionalString (
      cfg.enableDms || cfg.enableMergedProfile
    ) "bind = SUPER, SPACE, exec, $HOME/.nix-profile/bin/dms ipc call spotlight toggle"}
    bind = SUPER, W, exec, ${lib.getExe closeActiveWindow}
    bind = SUPER, RETURN, fullscreen
    bind = SUPER, S, togglefloating

    bind = SUPER, J, exec, ${lib.getExe couchWorkspace} previous
    bind = SUPER, K, exec, ${lib.getExe couchWorkspace} next
    bind = SUPER, down, exec, ${lib.getExe couchWorkspace} previous
    bind = SUPER, up, exec, ${lib.getExe couchWorkspace} next
    bind = SUPER, TAB, workspace, previous

    bind = SUPER SHIFT, J, exec, ${lib.getExe couchWorkspace} move-previous
    bind = SUPER SHIFT, K, exec, ${lib.getExe couchWorkspace} move-next
    bind = SUPER SHIFT, down, exec, ${lib.getExe couchWorkspace} move-previous
    bind = SUPER SHIFT, up, exec, ${lib.getExe couchWorkspace} move-next
    bind = SUPER SHIFT, 1, exec, ${lib.getExe couchWorkspace} move 1
    bind = SUPER SHIFT, 2, exec, ${lib.getExe couchWorkspace} move 2
    bind = SUPER SHIFT, 3, exec, ${lib.getExe couchWorkspace} move 3
    bind = SUPER SHIFT, 4, exec, ${lib.getExe couchWorkspace} move 4
    bind = SUPER SHIFT, 5, exec, ${lib.getExe couchWorkspace} move 5
    bind = SUPER SHIFT, 6, exec, ${lib.getExe couchWorkspace} move 6
    bind = SUPER SHIFT, 7, exec, ${lib.getExe couchWorkspace} move 7
    bind = SUPER SHIFT, 8, exec, ${lib.getExe couchWorkspace} move 8
    bind = SUPER SHIFT, 9, exec, ${lib.getExe couchWorkspace} move 9

    bindel = , XF86AudioRaiseVolume, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-volume @DEFAULT_AUDIO_SINK@ 3%+
    bindel = , XF86AudioLowerVolume, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-volume @DEFAULT_AUDIO_SINK@ 3%-
    bindl = , XF86AudioMute, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-mute @DEFAULT_AUDIO_SINK@ toggle
    bindel = , F10, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-volume @DEFAULT_AUDIO_SINK@ 3%+
    bindel = , F9, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-volume @DEFAULT_AUDIO_SINK@ 3%-
    bindl = , F8, exec, ${lib.getExe' pkgs.wireplumber "wpctl"} set-mute @DEFAULT_AUDIO_SINK@ toggle

    # Emergency exit back to greetd if the couch session cannot be closed normally.
    bind = SUPER SHIFT, escape, exit
    bind = SUPER SHIFT, Q, exit
  '';

  sessionLauncher = pkgs.writeShellScript "moonlight-hyprland-session" ''
    # Hyprland writes its startup banner and backend discovery to the launch
    # TTY before the first frame. Its own per-session log remains available
    # under XDG_RUNTIME_DIR, so keep the media-center handoff visually quiet.
    exec ${pkgs.hyprland}/bin/start-hyprland -- --config ${hyprlandConfig} \
      >/dev/null 2>&1
  '';

  sessionPackage = pkgs.writeTextFile {
    name = "moonlight-hyprland-session";
    destination = "/share/wayland-sessions/moonlight-hyprland.desktop";
    passthru.providedSessions = ["moonlight-hyprland"];
    text = ''
      [Desktop Entry]
      Name=Couch (Hyprland)
      Comment=Moonlight, browser, and phone-friendly TV session
      Exec=${sessionLauncher}
      Type=Application
      DesktopNames=Hyprland
    '';
  };

  sessionCommand =
    if cfg.enableCompositedSession
    then sessionLauncher
    else lib.getExe directDrmBrowserSession;

  sessionDispatcher = pkgs.writeShellApplication {
    name = "couch-session-dispatcher";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      persist_mode() {
        mode_tmp="$(mktemp ${lib.escapeShellArg "${modeStateFile}.XXXXXX"})"
        printf '%s\n' "$1" > "$mode_tmp"
        chmod 0644 "$mode_tmp"
        mv -f "$mode_tmp" ${lib.escapeShellArg modeStateFile}
      }
      mode="$(tr -d '[:space:]' < ${lib.escapeShellArg modeStateFile} 2>/dev/null || true)"
      mode_name="''${mode%%:*}"
      mode_token=""
      if [ "$mode" != "$mode_name" ]; then
        mode_token="''${mode#*:}"
      fi
      if [ "$mode_name" != merged ]; then
        systemctl --user stop couch-merged-dms.service >/dev/null 2>&1 || true
      fi
      case "$mode_name" in
        ${lib.optionalString (cfg.desktopSessionCommand != null) ''
        desktop)
          exec ${cfg.desktopSessionCommand}
          ;;
      ''}
        ${lib.optionalString cfg.enableMergedProfile ''
        merged)
          exec ${sessionCommand}
          ;;
      ''}
        ${lib.optionalString directDrmStreamEnabled ''
        direct-stream)
          boot_id="$(tr -d '[:space:]' < /proc/sys/kernel/random/boot_id)"
          if [ "$mode_token" = "$boot_id" ]; then
            exec ${lib.getExe directDrmStreamSession}
          fi
          persist_mode ${lib.escapeShellArg cfg.defaultSessionMode}
          exec ${sessionCommand}
          ;;
      ''}
        ${lib.optionalString directDrmBrowserEnabled ''
        direct-browser)
          boot_id="$(tr -d '[:space:]' < /proc/sys/kernel/random/boot_id)"
          if [ "$mode_token" = "$boot_id" ]${lib.optionalString persistentDirectDrmBrowserDefault " || [ -z \"$mode_token\" ]"}; then
            exec ${lib.getExe directDrmBrowserSession}
          fi
          persist_mode ${lib.escapeShellArg cfg.defaultSessionMode}
          exec ${sessionCommand}
          ;;
        ${lib.optionalString browserSelectorEnabled ''
          direct-private)
            boot_id="$(tr -d '[:space:]' < /proc/sys/kernel/random/boot_id)"
            if [ "$mode_token" = "$boot_id" ]; then
              exec ${lib.getExe directDrmBrowserSelectorSession}
            fi
            persist_mode ${lib.escapeShellArg cfg.defaultSessionMode}
            exec ${sessionCommand}
            ;;
        ''}
      ''}
        couch | *)
          exec ${sessionCommand}
          ;;
      esac
    '';
  };
in {
  inherit
    couchApplications
    sessionCommand
    sessionDispatcher
    sessionPackage
    ;
}
