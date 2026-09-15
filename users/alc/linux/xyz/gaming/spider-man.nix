{pkgs, ...}: let
  protonGe11_3 = import ./proton-ge-11-3.nix {inherit pkgs;};
  prefix = "/games/prefixes/Spider-Man Remastered";
  icon = pkgs.fetchurl {
    name = "spider-man-remastered.png";
    url = "https://cdn2.steamgriddb.com/grid/a85d6bc329aeaf43fe76fbb48b8b9325.png";
    hash = "sha256-bLHTH7ztWSIhSXz8Q5q1dq5NymjeWf8iAZWkYVvToSg=";
  };
  game = {
    icon = toString icon;
    inherit prefix;
    executable = "${prefix}/drive_c/games/Marvel's Spider-Man Remastered/Spider-Man.exe";
    protonPackage = protonGe11_3;
    networkAccess = false;
    environment.PROTON_USE_XALIA = "0";
  };
in {
  programs.umuApps = {
    enable = true;
    apps.spider-man =
      game
      // {
        displayName = "Spider-Man Remastered (Offline)";
        comment = "Launch Spider-Man Remastered without network access";
      };
    apps.spider-man-couch =
      game
      // {
        displayName = "Spider-Man Remastered (Couch, Offline)";
        comment = "Start Spider-Man Remastered offline without the settings launcher";
        arguments = ["-nolauncher"];
      };
  };
}
