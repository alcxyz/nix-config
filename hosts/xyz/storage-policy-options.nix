{lib, ...}: {
  options.xyz.storage.policy = lib.mkOption {
    type = lib.types.submodule {
      options = {
        runtime = {
          pool = lib.mkOption {type = lib.types.str;};
          datasets = {
            docker = lib.mkOption {type = lib.types.str;};
            steam-headless = lib.mkOption {type = lib.types.str;};
            forgejo-docker = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional dedicated Forgejo build-daemon runtime dataset.";
            };
          };
          forgejoDockerQuota = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional quota for the dedicated Forgejo build-daemon runtime dataset.";
          };
          retiredK3sDataset = lib.mkOption {type = lib.types.str;};
        };
        appState.datasets = {
          calibre = lib.mkOption {type = lib.types.str;};
          calibre-web = lib.mkOption {type = lib.types.str;};
          plex = lib.mkOption {type = lib.types.str;};
          qbittorrent = lib.mkOption {type = lib.types.str;};
          stash = lib.mkOption {type = lib.types.str;};
        };
        localBackup = {
          pool = lib.mkOption {type = lib.types.str;};
          lockLabel = lib.mkOption {type = lib.types.strMatching "[A-Za-z0-9._-]+";};
          appStateRoot = lib.mkOption {type = lib.types.str;};
          k8sDataset = lib.mkOption {type = lib.types.str;};
          k8sRoot = lib.mkOption {type = lib.types.str;};
          appStateSchedule = lib.mkOption {type = lib.types.str;};
          k8sSchedule = lib.mkOption {type = lib.types.str;};
        };
        games = {
          pool = lib.mkOption {type = lib.types.str;};
          dataset = lib.mkOption {type = lib.types.str;};
          mountpoint = lib.mkOption {type = lib.types.str;};
        };
      };
    };
    description = "Private host values consumed by xyz's public storage assembly.";
  };
}
