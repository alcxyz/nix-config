{
  lib,
  pkgs,
  runCommandCC,
  symlinkJoin,
}:
let
  pointerShim = runCommandCC "kdeconnect-hypr-pointer-shim" {
    nativeBuildInputs = [pkgs.pkg-config];
    buildInputs = [
      pkgs.libx11
      pkgs.libxcb
      pkgs.libxi
      pkgs.libxtst
    ];
  } ''
    install -d "$out/lib"
    "$CC" \
      -shared \
      -fPIC \
      -Wall \
      -Wextra \
      -Werror \
      $(${pkgs.pkg-config}/bin/pkg-config --cflags x11 xcb xi xtst) \
      -o "$out/lib/libkdeconnect-hypr-pointer-shim.so" \
      ${./kdeconnect-hypr-pointer-shim.c} \
      $(${pkgs.pkg-config}/bin/pkg-config --libs x11 xcb xi xtst) \
      -ldl \
      -lm
  '';
  pointerBridge = pkgs.writeShellApplication {
    name = "kdeconnect-hypr-pointer-bridge";
    runtimeInputs = [
      pkgs.python3
      pkgs.xrandr
    ];
    text = ''
      exec ${pkgs.python3}/bin/python ${./kdeconnect-hypr-pointer-bridge.py}
    '';
  };
in
symlinkJoin {
  name = "kdeconnect-hyprland-input";
  paths = [
    pointerShim
    pointerBridge
  ];
  meta.mainProgram = "kdeconnect-hypr-pointer-bridge";
}
