{
  config,
  lib,
  pkgs,
  gameWindowGeometryPolicies,
}: let
  mailWorkspaceScript = builtins.readFile ./desktop-scripts/mail-workspace.sh;
  mailWorkspace = pkgs.writeShellApplication {
    name = "hyprland-mail-workspace";
    runtimeInputs = [
      pkgs.hyprland
      pkgs.jq
      pkgs.thunderbird
    ];
    text = mailWorkspaceScript;
  };
  closeActiveWindowScript = builtins.readFile ./desktop-scripts/close-active-window.sh;
  closeActiveWindow = pkgs.writeShellApplication {
    name = "hyprland-close-active-window";
    runtimeInputs = [
      pkgs.gawk
      pkgs.hyprland
      pkgs.jq
      pkgs.systemd
    ];
    text = closeActiveWindowScript;
  };
  xwaylandPrimaryOutput = pkgs.writeShellApplication {
    name = "hyprland-xwayland-primary-output";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.hyprland
      pkgs.jq
      pkgs.socat
      pkgs.xrandr
    ];
    text = builtins.readFile ./desktop-scripts/xwayland-primary-output.sh;
  };
  gameWindowGeometryGuard = pkgs.writeShellApplication {
    name = "hyprland-game-window-geometry-guard";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
      pkgs.socat
    ];
    text =
      ''
        policies=${lib.escapeShellArg (builtins.toJSON gameWindowGeometryPolicies)}
      ''
      + builtins.readFile ./desktop-scripts/game-window-geometry-guard.sh;
  };
  droptermToggle = pkgs.writeShellApplication {
    name = "dropterm-toggle";
    runtimeInputs = [
      config.programs.hyprscratch.package
      pkgs.coreutils
      pkgs.hyprland
      pkgs.jq
      pkgs.netcat-openbsd
      pkgs.systemd
    ];
    text = builtins.readFile ./desktop-scripts/dropterm-toggle.sh;
  };
in {
  inherit mailWorkspaceScript mailWorkspace closeActiveWindowScript closeActiveWindow xwaylandPrimaryOutput gameWindowGeometryGuard droptermToggle;
}
