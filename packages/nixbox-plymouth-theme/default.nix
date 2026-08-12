{
  stdenvNoCC,
  lib,
  fetchurl,
  imagemagick,
  librsvg,
}:
stdenvNoCC.mkDerivation {
  pname = "nixbox-plymouth-theme";
  version = "1.0.0";

  src = ./.;
  dontBuild = true;

  nativeBuildInputs = [
    imagemagick
    librsvg
  ];

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

    theme="$out/share/plymouth/themes/nixbox"
    install -d "$theme"
    install -Dm644 nixbox.script "$theme/nixbox.script"
    substitute nixbox.plymouth "$theme/nixbox.plymouth" \
      --replace-fail '@themeDir@' "$theme"

    # Plymouth's script renderer cannot select Space Grotesk reliably. Render
    # the final typography at 2x and let the theme downscale for each output.
    for letter in N I X B O; do
      magick -background none -fill '#e9edf4' \
        -font "$spaceGrotesk" -weight 300 -pointsize 176 \
        -size 208x212 -gravity center "label:$letter" \
        "$theme/letter-$letter.png"
    done

    magick -background none -fill '#5c6470' \
      -font "$spaceGrotesk" -weight 400 -pointsize 48 -kerning 16 \
      -size 1200x68 -gravity center 'label:POWERING OFF' \
      "$theme/subtitle-powering-off.png"

    # Keep the original large white asset for the already-approved shutdown
    # sequence. Boot uses a compact pre-rendered mark below the wordmark so the
    # early renderer never has to scale a multi-megapixel transparent image.
    rsvg-convert --width 2228 --height 2228 "$snowflake" \
      --output "$theme/nix-snowflake-white.png"
    magick "$theme/nix-snowflake-white.png" \
      -resize 512x512 \
      -channel RGB -fill '#5c6470' -colorize 100% +channel \
      -define png:color-type=6 \
      "$theme/nix-snowflake-compact.png"
    magick -size 1040x20 xc:'#343b47' \
      -define png:color-type=2 "$theme/progress-track.png"
    magick -size 1040x20 xc:'#b8cce5' \
      -define png:color-type=2 "$theme/progress-fill.png"

    runHook postInstall
  '';

  meta = {
    description = "NIXBOX animated Plymouth theme";
    license = [
      lib.licenses.mit
      lib.licenses.cc-by-40
    ];
    platforms = lib.platforms.linux;
  };
}
