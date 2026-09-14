{pkgs, ...}: let
  protonGe10_4 =
    (pkgs.proton-ge-bin.overrideAttrs (finalAttrs: _: {
      version = "GE-Proton10-4";
      src = pkgs.fetchzip {
        url = "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${finalAttrs.version}/${finalAttrs.version}.tar.gz";
        hash = "sha256-Si/CQ2PINfhmsC+uW3iFBUoSczZdkqwCZ8FAFuipu68=";
      };
    })).steamcompattool;
  battleNetPrefix = "/ext4/games/Heroic/Prefixes/default/Battle.net";
  battleNetEnvironment = {
    DRI_PRIME = "1";
    DXVK_CONFIG = "dxgi.maxFrameRate = 120";
    DXVK_FRAME_RATE = "120";
    TZ = "Europe/Oslo";
    # Avoid the pinned Proton's Bluetooth-driver loop; host input uses separate drivers.
    WINEDLLOVERRIDES = "winebth.sys=";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    __NV_PRIME_RENDER_OFFLOAD = "1";
  };
  battleNetIcon = pkgs.fetchurl {
    name = "battle-net.png";
    url = "https://lutris.net/games/icon/battlenet.png";
    hash = "sha256-Otx9a99ZJx++nqBj/5ljwALoFFoxRPXao3zFaZpGyao=";
  };
  heroesProfileIcon = pkgs.fetchurl {
    name = "heroes-profile.png";
    url = "https://raw.githubusercontent.com/Heroes-Profile/HeroesProfile.Uploader/f73fa675d197875237a8973c2f2a899b293b6f09/Heroesprofile.Uploader.Windows/Resources/heroesprofilelogo.png";
    hash = "sha256-T1XhH5DmAAFvFJhD3qbwaqXIvHczbt77Wi7kPZuuo+0=";
  };
in {
  programs.umuApps = {
    enable = true;
    apps = {
      battle-net = {
        displayName = "Battle.net";
        comment = "Launch Battle.net directly through UMU";
        icon = toString battleNetIcon;
        prefix = battleNetPrefix;
        executable = "${battleNetPrefix}/pfx/drive_c/Program Files (x86)/Battle.net/Battle.net.exe";
        protonPackage = protonGe10_4;
        environment = battleNetEnvironment;
        staleRecoveryWindowMatchers = [
          {
            classRegex = "^steam_app_default$";
            titleRegex = "^Battle[.]net$";
          }
          {
            classRegex = "^steam_app_default$";
            titleRegex = "^Heroes of the Storm$";
          }
        ];
      };
      heroes-profile = {
        displayName = "Heroes Profile";
        comment = "Launch the Heroes Profile uploader in the Battle.net compatibility prefix";
        icon = toString heroesProfileIcon;
        prefix = battleNetPrefix;
        executable = "${battleNetPrefix}/pfx/drive_c/users/steamuser/AppData/Local/Heroesprofile/Heroesprofile.Uploader.exe";
        protonPackage = protonGe10_4;
        role = "companion";
        environment = battleNetEnvironment;
      };
    };
  };
}
