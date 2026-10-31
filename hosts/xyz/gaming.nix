# Host-local gaming services and streaming integration.
{
  config,
  lib,
  pkgs,
  username,
  ...
}: {
  programs.steam = {
    enable = true;
  };

  # Steam Stream
  # Keep Sunshine's fixed service ports out of the ephemeral client-port pool.
  boot.kernel.sysctl."net.ipv4.ip_local_reserved_ports" = "47984,47989-47990,47998-48000,48002,48010";

  # One definition of "a game runs here" (ADR-0106) for the CI runner hold,
  # the Podman store reset, background builds and the reboot guard.
  services.gameSignal = {
    enable = true;
    user = username;
    # Heroes of the Storm and the sideloaded Heroic games, by the executable
    # each runs under Wine; the Battle.net launcher is no game.
    wineArgv0Basenames = lib.unique (["HeroesOfTheStorm_x64.exe"]
      ++ lib.mapAttrsToList (_: app: app.executable)
      (lib.filterAttrs (name: _: name != "battle-net") config.services.heroicSideload.apps));
    # Steam runs each game under reaper, alive only while the game runs, also
    # inside SteamHeadless, whose games run as this user's uid. Not
    # wineserver: non-game Wine apps keep one here too.
    processNames = ["reaper"];
    # Sunshine, here SteamHeadless on the host network, binds its video port
    # only while a client streams, whoever runs the game.
    streamUdpPorts = [47998];
  };

  users.groups.steamheadless = {
    gid = 2001;
  };
  users.users.steamheadless = {
    isSystemUser = true;
    uid = 2001;
    group = "steamheadless";
    extraGroups = [
      "users"
      "media"
      "video"
      "render"
    ];
  };

  services.heroicSideload = {
    enable = true;
    user = username;
    apps.battle-net = {
      title = "Battle.net";
      appName = "tiJeeLoWxRnVACPf7WYvkr";
      installDir = "/ext4/games/Heroic/Prefixes/default/Battle.net/pfx/drive_c/Program Files (x86)/Battle.net";
      executable = "Battle.net.exe";
      art = "https://cdn2.steamgriddb.com/grid/18c968e3898f39820946387c9e8aa5c8.png";
      manageGameConfig = false;
    };
    apps.totem-quest = {
      title = "Totem Quest";
      appName = "rcFYseiJyPmfqM9tn2Di7a";
      source = "/var/lib/xyz-games/sources/Totem-Quest_Win_EN_Full.zip";
      installDir = "/ext4/games/Totem_Quest";
      executable = "TotemQuest.exe";
      art = "https://www.myabandonware.com/media/screenshots/t/totem-quest-1c8k/webp/totem-quest_1.webp";
      protonPackage = pkgs.proton-ge-bin.steamcompattool;
    };
  };
}
