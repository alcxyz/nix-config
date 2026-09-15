{pkgs, ...}: let
  prefix = "/games/prefixes/Cyberpunk_2077";
  icon = pkgs.fetchurl {
    name = "cyberpunk-2077.png";
    url = "https://cdn2.steamgriddb.com/grid/f39b781760a403dedaa05587e8889c1a.png";
    hash = "sha256-D/S6mhkEPvk7amL+pQtLyPbdDeaTcs+XQgKARlRQbFQ=";
  };
in {
  programs.umuApps.apps.cyberpunk-2077 = {
    displayName = "Cyberpunk 2077 (Offline)";
    comment = "Launch Cyberpunk 2077 without network access";
    icon = toString icon;
    inherit prefix;
    executable = "${prefix}/drive_c/Cyberpunk 2077/bin/x64/Cyberpunk2077.exe";
    protonPackage = import ./proton-ge-11-3.nix {inherit pkgs;};
    gameId = "0";
    networkAccess = false;
    environment = {
      PROTON_USE_XALIA = "0";
      # Use the bundled ICU 65 exports instead of Wine built-ins.
      WINEDLLOVERRIDES = "icuuc,icuin=n";
    };
  };
}
