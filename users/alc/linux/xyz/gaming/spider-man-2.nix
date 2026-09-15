{pkgs, ...}: let
  prefix = "/games/prefixes/Spider-Man_2";
  icon = pkgs.fetchurl {
    name = "spider-man-2.png";
    url = "https://cdn2.steamgriddb.com/grid/11d9eeb2879bf6829d075c26fe111cd3.png";
    hash = "sha256-Z2293z9cUjBmZGrX/1vKMYxBSHZE6IvF3jPG4TAv4oU=";
  };
in {
  programs.umuApps.apps.spider-man-2 = {
    displayName = "Spider-Man 2 (Offline)";
    comment = "Launch Spider-Man 2 without network access";
    icon = toString icon;
    inherit prefix;
    executable = "${prefix}/drive_c/Program Files (x86)/DODI-Repacks/Marvels SpiderMan 2/Spider-Man2.exe";
    protonPackage = import ./proton-ge-11-3.nix {inherit pkgs;};
    gameId = "0";
    networkAccess = false;
    steamLauncher = true;
    environment = {
      PROTON_USE_XALIA = "0";
    };
  };
}
