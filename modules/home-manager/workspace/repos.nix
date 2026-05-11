[
  {
    path = "infra/nix-config";
    url = "git@git-ssh.alc.xyz:alcxyz/nix-config.git";
    branch = "dev";
    profiles = [ "infra-admin" ];
  }
  {
    path = "infra/nix-secrets";
    url = "git@git-ssh.alc.xyz:alcxyz/nix-secrets.git";
    branch = "main";
    profiles = [ "infra-admin" ];
  }
  {
    path = "infra/nix-packages";
    url = "git@git-ssh.alc.xyz:alcxyz/nix-packages.git";
    branch = "dev";
    profiles = [ "infra-admin" ];
  }
  {
    path = "infra/gitops";
    url = "git@git-ssh.alc.xyz:alcxyz/gitops.git";
    branch = "dev";
    profiles = [ "infra-admin" ];
  }
  {
    path = "apps/beautyzone";
    url = "git@git-ssh.alc.xyz:alcxyz/beautyzone.git";
    branch = "main";
    profiles = [ "apps" ];
  }
  {
    path = "apps/canopy";
    url = "git@github.com:alcxyz/canopy.git";
    branch = "dev";
    profiles = [ "apps" ];
  }
  {
    path = "apps/erpctl";
    url = "git@git-ssh.alc.xyz:alcxyz/erpctl.git";
    branch = "main";
    profiles = [ "apps" ];
  }
  {
    path = "apps/grove";
    url = "git@github.com:alcxyz/grove.git";
    branch = "dev";
    profiles = [ "apps" ];
  }
  {
    path = "apps/kjekkmann";
    url = "git@git-ssh.alc.xyz:alcxyz/kjekkmann.git";
    branch = "main";
    profiles = [ "apps" ];
  }
  {
    path = "apps/leantime-bot";
    url = "git@git-ssh.alc.xyz:alcxyz/leantime-bot.git";
    branch = "main";
    profiles = [ "apps" ];
  }
  {
    path = "apps/nssupply";
    url = "git@git-ssh.alc.xyz:alcxyz/nssupply.git";
    branch = "main";
    profiles = [ "apps" ];
  }
  {
    path = "apps/paperflow";
    url = "git@github.com:alcxyz/paperflow.git";
    branch = "dev";
    profiles = [ "apps" ];
  }
  {
    path = "apps/paperflow-telegram";
    url = "git@git-ssh.alc.xyz:alcxyz/paperflow-telegram.git";
    branch = "dev";
    profiles = [ "apps" ];
  }
  {
    path = "apps/telegram-bot";
    url = "git@git-ssh.alc.xyz:alcxyz/telegram-bot.git";
    branch = "dev";
    profiles = [ "apps" ];
  }
  {
    path = "apps/timebank";
    url = "git@git-ssh.alc.xyz:alcxyz/timebank.git";
    branch = "dev";
    profiles = [ "apps" ];
  }
  {
    path = "apps/valuta-quotes";
    url = "git@git-ssh.alc.xyz:alcxyz/valuta-quotes.git";
    branch = "main";
    profiles = [ "apps" ];
  }
  {
    path = "forks/NB.no-Downloader";
    url = "git@git-ssh.alc.xyz:alcxyz/NB.no-Downloader.git";
    branch = "epub-output";
    profiles = [ "forks" ];
  }
  {
    path = "forks/Terraform-Associate-Labs";
    url = "git@git-ssh.alc.xyz:alcxyz/Terraform-Associate-Labs.git";
    branch = "main";
    profiles = [ "forks" ];
  }
  {
    path = "forks/dms-plugin-registry";
    url = "git@git-ssh.alc.xyz:alcxyz/dms-plugin-registry.git";
    branch = "add-dankcalendar";
    profiles = [ "forks" ];
  }
  {
    path = "forks/frappe_docker";
    url = "git@git-ssh.alc.xyz:alcxyz/frappe_docker.git";
    branch = "main";
    profiles = [ "forks" ];
  }
  {
    path = "forks/nvim-treesitter";
    url = "git@git-ssh.alc.xyz:alcxyz/nvim-treesitter.git";
    branch = "alc/fixes";
    profiles = [ "forks" ];
  }
  {
    path = "clones/JimsGarage";
    url = "git@github.com:JamesTurland/JimsGarage.git";
    branch = "main";
    profiles = [ "clones" ];
  }
  {
    path = "clones/dms-qcal-calendar";
    url = "https://github.com/szabolcsf/dms-qcal-calendar";
    branch = "main";
    profiles = [ "clones" ];
  }
  {
    path = "clones/telegram-media-downloader";
    url = "git@github.com:vinodkr494/telegram-media-downloader.git";
    branch = "master";
    profiles = [ "clones" ];
  }
]
