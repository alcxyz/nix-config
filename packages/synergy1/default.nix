{
  lib,
  stdenv,
  requireFile,
  undmg,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "synergy1";
  version = "1.20.4";

  src = requireFile {
    name = "synergy_1.20.4_mac_arm64.dmg";
    url = "https://symless.com/synergy/download/synergy1-personal/v1.20.4";
    hash = "sha256-CNM2FYqyUsbleLdlOMxWEtSZKNk3kSwyEfekwo69RqA=";
  };

  nativeBuildInputs = [undmg];
  sourceRoot = ".";

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/Applications"
    cp -R Synergy.app "$out/Applications/"

    runHook postInstall
  '';

  meta = {
    description = "Synergy 1 keyboard and mouse sharing app";
    homepage = "https://symless.com/synergy";
    license = lib.licenses.gpl2Only;
    platforms = ["aarch64-darwin"];
    sourceProvenance = with lib.sourceTypes; [binaryNativeCode];
    hydraPlatforms = [];
  };
})
