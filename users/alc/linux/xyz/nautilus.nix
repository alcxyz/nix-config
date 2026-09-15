{pkgs, ...}: let
  # Keep the renderer workaround local to Nautilus, including D-Bus activation.
  launcher = pkgs.writeShellScript "nautilus-opengl" ''
    export GSK_RENDERER=gl
    exec ${pkgs.nautilus}/bin/nautilus "$@"
  '';
  desktop = pkgs.runCommand "nautilus-opengl.desktop" {} ''
    cp ${pkgs.nautilus}/share/applications/org.gnome.Nautilus.desktop "$out"
    substituteInPlace "$out" --replace-fail 'Exec=nautilus' 'Exec=${launcher}'
  '';
in {
  home.file.".local/bin/nautilus".source = launcher;
  xdg.dataFile."applications/org.gnome.Nautilus.desktop".source = desktop;
  xdg.dataFile."dbus-1/services/org.gnome.Nautilus.service".text = ''
    [D-BUS Service]
    Name=org.gnome.Nautilus
    Exec=${launcher} --gapplication-service
  '';
}
