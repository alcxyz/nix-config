{
  stdenvNoCC,
  lib,
  makeWrapper,
  coreutils,
  hyprland,
  jq,
  quickshell,
  fetchurl,
}:
stdenvNoCC.mkDerivation {
  pname = "nixbox-session-splash";
  version = "1.0.0";

  src = ./.;
  dontBuild = true;

  nativeBuildInputs = [makeWrapper];

  snowflake = fetchurl {
    url = "https://raw.githubusercontent.com/NixOS/nixos-artwork/9d2cdedd73d64a068214482902adea3d02783ba8/logo/nix-snowflake-white.svg";
    hash = "sha256-J/t94Bz0fUCL92m1JY9gznu0DLfy6uIQO6AJGK3CEAY=";
  };

  spaceGrotesk = fetchurl {
    url = "https://raw.githubusercontent.com/google/fonts/389b770410cc0b7c21c85673bfa2077420fe7f65/ofl/spacegrotesk/SpaceGrotesk%5Bwght%5D.ttf";
    name = "SpaceGrotesk.ttf";
    hash = "sha256-rK1t4fyTQ29cDx9BN3Ue8E8a6jBj5wNlNZcP/PvXn3I=";
  };

  installPhase = ''
      runHook preInstall

    install -Dm644 shell.qml "$out/share/nixbox-session-splash/shell.qml"
    install -Dm644 "$snowflake" "$out/share/nixbox-session-splash/nix-snowflake-white.svg"
    install -Dm644 "$spaceGrotesk" "$out/share/fonts/truetype/SpaceGrotesk.ttf"
    makeWrapper ${coreutils}/bin/timeout "$out/bin/nixbox-session-splash" \
      --run 'for attempt in $(${coreutils}/bin/seq 1 100); do monitors="$(${hyprland}/bin/hyprctl -j monitors 2>/dev/null || true)"; if printf %s "$monitors" | ${jq}/bin/jq -e "any(.[]; .dpmsStatus == true)" >/dev/null 2>&1; then break; fi; ${coreutils}/bin/sleep 0.1; done' \
      --add-flags "15 ${quickshell}/bin/quickshell -p $out/share/nixbox-session-splash" \
      --set QT_QPA_FONTDIR "$out/share/fonts/truetype"

      runHook postInstall
  '';

  meta = {
    description = "Non-blocking NIXBOX graphical-session splash";
    license = [lib.licenses.mit lib.licenses.cc-by-40];
    platforms = lib.platforms.linux;
    mainProgram = "nixbox-session-splash";
  };
}
