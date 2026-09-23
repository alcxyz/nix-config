# users/alc/common.nix
{
  config,
  pkgs,
  lib,
  username,
  accountUsername,
  accountHomeDirectory,
  hostName,
  configDir,
  inputs,
  system,
  ...
}: let
  pkgsets = import "${configDir}/modules/shared/pkgsets.nix" {
    inherit pkgs inputs;
  };
  forgeMirrorRequiredSessionVariables = [
    "FORGEJO_URL"
    "FORGEJO_USER"
    "FORGEJO_SSH_HOST"
    "FORGE_MIRROR_SCAN_ROOTS_FILE"
    "FORGE_MIRROR_GITHUB_PRIMARY_REPOS_FILE"
  ];
  forgeMirrorEnvironment =
    if
      lib.all (
        name:
          builtins.hasAttr name config.home.sessionVariables
          && toString config.home.sessionVariables.${name} != ""
      )
      forgeMirrorRequiredSessionVariables
    then config.home.sessionVariables
    else throw "forgejoPrimary requires the private forge-mirror operator policy module.";
  forgeMirrorCommandEnvironment = lib.escapeShellArgs (
    map (name: "${name}=${forgeMirrorEnvironment.${name}}") forgeMirrorRequiredSessionVariables
    ++ lib.optional (forgeMirrorEnvironment ? FORGEJO_TOKEN_FILE)
    "FORGEJO_TOKEN_FILE=${forgeMirrorEnvironment.FORGEJO_TOKEN_FILE}"
  );
in
  with lib; {
    # ==================== Imports of truly common modules ====================
    imports = [
      inputs.nix-secrets.homeManagerModules.sshIdentityPolicy
      # These are modules that are guaranteed to work on both OSes
      # or handle their own platform differences internally if needed
      "${configDir}/modules/home-manager/shell/default.nix"
      #"${configDir}/modules/home-manager/programs/wezterm/default.nix"
      "${configDir}/modules/home-manager/programs/git/default.nix"
      "${configDir}/modules/home-manager/programs/kubernetes/default.nix"
      "${configDir}/modules/home-manager/programs/ssh/default.nix"
      "${configDir}/modules/home-manager/workspace/default.nix"
      "${configDir}/modules/shared/host-metadata.nix"
    ];

    # ==================== Home Manager Core Settings ====================
    home.username = accountUsername;
    home.homeDirectory = accountHomeDirectory;
    home.stateVersion = "24.11";

    programs.home-manager.enable = true;

    # ==================== Nix-Colors Settings ====================
    colorscheme.name = "catppuccin-mocha";

    # ==================== User Environment ====================
    # Keep interface language English while using Norwegian dates for this
    # account only. Empty LC_ALL lets individual locale categories take effect,
    # including in sessions that inherited the old all-English override.
    home.language.time = lib.mkIf (accountUsername == username) "nb_NO.UTF-8";

    home.sessionVariables = {
      DIRENV_LOG_FORMAT = "";
      CGO_ENABLED = "1";
      FLAKE = configDir;
      LC_ALL = lib.mkIf (accountUsername == username) (lib.mkForce "");
      LOCALE_ARCHIVE =
        lib.mkIf (accountUsername == username && pkgs.stdenv.isLinux)
        "${pkgs.glibcLocales}/lib/locale/locale-archive";
    };

    programs.nushell.environmentVariables = lib.mkIf (accountUsername == username) {
      LC_ALL = lib.mkForce "";
      LC_TIME = config.home.language.time;
    };

    # Update and switch aliases (run from the nix-config checkout).
    home.shellAliases = {
      dms-update = "bash scripts/update-inputs/update-maintained.sh --dms-only";
      apps-update = "bash scripts/update-inputs/update-maintained.sh";
      # Compatibility with the former QA-specific name.
      qaup = "bash scripts/update-inputs/update-maintained.sh";
      hmsw = "home-manager switch --flake .#alc-${hostName}";
    };

    # ==================== Packages ====================
    home.packages =
      pkgsets.hm.base
      ++ [
        inputs.grove.packages.${pkgs.stdenv.hostPlatform.system}.default
        inputs.canopy.packages.${pkgs.stdenv.hostPlatform.system}.default
        inputs.paw.packages.${pkgs.stdenv.hostPlatform.system}.paw
      ];

    # ==================== Symlinked configs (live editing, all hosts) ====================
    xdg.configFile."television".source =
      config.lib.file.mkOutOfStoreSymlink "${configDir}/users/alc/configs/television";

    xdg.configFile."llm/config.toml".source =
      config.lib.file.mkOutOfStoreSymlink "${configDir}/users/alc/configs/llm/config.toml";

    home.file.".claude/CLAUDE.md".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/src/infra/nix-secrets/shared/claude/CLAUDE.md";

    home.file.".codex/AGENTS.md".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/AGENTS.md";

    home.file."AGENTS.md".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/src/infra/nix-secrets/shared/AGENTS.md";

    # ==================== Files ====================
    home.file = {
      "Music/.keep".text = "";
      "Pictures/.keep".text = "";
      # Profile picture is usually common regardless of OS
      ".face".source = ./profile.jpg; # Relative to users/alc/
      "Pictures/profile.jpg".source = ./profile.jpg;

      # If you have general dotfiles that are always the same
      # e.g., a common nvim config
      # ".config/nvim/init.lua".source = ../../path/to/common/nvim/init.lua;
    };

    # ==================== Program Enabling for Common Programs ====================
    programs.ssh.enable = true;

    programs.git.managed.enable = true;
    # PAW workspaces are reached as Git remotes through the ext:: transport
    # (paw workspace repository remote), which Git disables unless allowed.
    programs.git.settings.protocol.ext.allow = "user";
    programs.workspace.enable = true;

    # Forgejo credential helper — moved to linux/common.nix and darwin/mac.nix
    # where the sops secret path is available for inline injection.

    #programs.wezterm.enable = true;

    programs.ncspot.enable = true;

    # Configure Forgejo as the local primary remote for repos that exist on
    # Forgejo. Runs on every home-manager switch and remains non-blocking when
    # the remote is unavailable.
    home.activation.forgejoPrimary =
      lib.hm.dag.entryAfter [
        "linkGeneration"
        "workspaceDirs"
        "sops-nix"
      ] ''
        if ! ${pkgs.coreutils}/bin/env PATH="${lib.makeBinPath [pkgs.git]}:$PATH" ${forgeMirrorCommandEnvironment} ${lib.getExe pkgs.forge-mirror} primary; then
          echo "forge-mirror primary could not update repository remotes; continuing" >&2
        fi
      '';
  }
