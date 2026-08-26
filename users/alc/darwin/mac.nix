# users/alc/darwin/mac.nix
{
  config,
  pkgs,
  lib,
  username,
  inputs,
  configDir,
  hostName,
  hostRole,
  ...
}:
# macOS-specific packages
let
  pkgsets = import "${configDir}/modules/nixos/common/pkgsets.nix" {inherit pkgs inputs;};
in {
  imports = [
    "${configDir}/users/alc/common.nix"
    "${configDir}/users/alc/kubernetes-labs.nix"
    "${configDir}/modules/home-manager/programs/wezterm/default.nix"
    "${configDir}/modules/home-manager/services/paperflow/default.nix"
    "${configDir}/modules/home-manager/programs/karabiner/default.nix"
    "${configDir}/modules/home-manager/programs/moonlight-endpoints/default.nix"
    inputs.nix-secrets.homeManagerModules.darwinOperator
  ];

  home.packages = pkgsets.home.${hostRole.homePackageSet};

  programs.wezterm.enable = true;
  programs.karabiner.managed.enable = true;
  programs.atuin.daemon.enable = false;
  programs.moonlightEndpoints.launchers = [
    {
      hostname = "Wolf User";
      application = "Wolf UI";
      arguments = [
        "--absolute-mouse"
        "--display-mode"
        "windowed"
      ];
      lanArguments = [
        "--video-codec"
        "H.264"
        "--bitrate"
        "60000"
      ];
    }
    {
      hostname = "Wolf";
      application = "Helium";
      displayName = "Helium";
      arguments = [
        "--absolute-mouse"
        "--display-mode"
        "windowed"
      ];
      lanArguments = [
        "--video-codec"
        "H.264"
        "--bitrate"
        "60000"
      ];
    }
  ];

  home.sessionPath = [
    "${config.home.homeDirectory}/.nix-profile/bin"
    "/run/current-system/sw/bin"
    "/nix/var/nix/profiles/default/bin"
    "/opt/homebrew/bin"
    "/usr/local/bin"
    "/opt/homebrew/sbin"
    "/usr/local/sbin"
    "/usr/bin"
    "/bin"
    "/usr/sbin"
    "/sbin"
  ];

  # The official app identifies itself as "T3 Code (Alpha)", while the
  # previous source build stored its project state under "t3code". Keep the
  # established profile as the canonical one across package variants.
  home.activation.reuseT3CodeProfile = lib.hm.dag.entryAfter ["writeBoundary"] ''
    canonical="$HOME/Library/Application Support/t3code"
    official="$HOME/Library/Application Support/T3 Code (Alpha)"
    backup="$HOME/Library/Application Support/T3 Code (Alpha).pre-nix-profile"

    if [ -d "$canonical" ] && [ ! -L "$official" ]; then
      if [ -e "$official" ]; then
        if [ -e "$backup" ]; then
          echo "Refusing to replace T3 Code profile: backup already exists at $backup" >&2
          exit 1
        fi
        mv "$official" "$backup"
      fi
      ln -s "$canonical" "$official"
    fi
  '';

  home.shellAliases = {
    nxsw = "sudo /run/current-system/sw/bin/darwin-rebuild switch --flake .#mac";
  };

  # Deploy SSH key pair for macOS
  #secrets.ssh.keyPair = {
  #  enable = true;
  #  baseName = "id_ed25519";
  #  forceRefresh = false;
  #};

  programs.bash.profileExtra = ''
    if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
      . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
    fi
  '';

  programs.zsh.initContent = ''
    if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
      . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
    fi
  '';

  # Configure git signing
  programs.git.managed = {
    userName = "alcxyz";
    userEmail = "me@alc.no";
    signingKey = "${config.home.homeDirectory}/.ssh/id_ed25519.pub"; # Use the deployed public key
    signByDefault = true;

    extraConfig = {
      core = {
        editor = "nvim";
      };
      gpg.format = "ssh";
    };

    aliases = {
      co = "checkout";
      br = "branch";
      st = "status";
    };

    /*
    conditionalSigningConfigs = {
      # Condition for work projects
      "gitdir:~/work/" = {
        "user.name" = "Alc Work";
        "user.email" = "alc@company.com";
        "user.signingkey" = "${config.home.homeDirectory}/.ssh/id_ed25519_work.pub";
        "commit.gpgsign" = "true"; # Ensure work commits are signed
        # "gpg.format" = "ssh"; # Inherits global, or override if work key is different type
      };

      # Condition for a specific personal project needing a different key/email
      "gitdir:~/personal/my-special-project/" = {
        "user.email" = "alc+specialproject@personal.com";
        "user.signingkey" = "${config.home.homeDirectory}/.ssh/id_ed25519_special.pub";
        # Inherits global user.name ("alcxyz")
        # Inherits global commit.gpgsign ("true") unless explicitly set to "false"
      };

      # Condition for projects where you don't want to sign commits
      "gitdir:~/personal/no-signing-repos/" = {
        "commit.gpgsign" = "false"; # Explicitly disable signing
      };
    };
    */
  };
}
