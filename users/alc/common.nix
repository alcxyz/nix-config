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
  hostSopsFile = (
    assert builtins.pathExists "${inputs.nix-secrets}/hosts/${hostName}/secrets.yaml"; "${inputs.nix-secrets}/hosts/${hostName}/secrets.yaml"
  );
  operatorSshKeysFile = (
    assert builtins.pathExists "${inputs.nix-secrets}/operators/ssh_keys.yaml"; "${inputs.nix-secrets}/operators/ssh_keys.yaml"
  );
  operatorSshKeyPairs = lib.optionals (hostName == "xyz") [
    "aur_key"
    "aur_paperflow"
    "docker"
    "github_actions_vps"
  ];
  operatorSshSecrets = lib.listToAttrs (
    lib.concatMap (name: [
      {
        name = "ssh.operator.${name}.private";
        value = {
          sopsFile = operatorSshKeysFile;
          key = "ssh_${name}";
          path = "${config.home.homeDirectory}/.ssh/${name}";
          mode = "0600";
        };
      }
      {
        name = "ssh.operator.${name}.public";
        value = {
          sopsFile = operatorSshKeysFile;
          key = "ssh_${name}.pub";
          path = "${config.home.homeDirectory}/.ssh/${name}.pub";
          mode = "0644";
        };
      }
    ])
    operatorSshKeyPairs
  );
in
  with lib; {
    # ==================== Imports of truly common modules ====================
    imports = [
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
    home.sessionVariables = {
      DIRENV_LOG_FORMAT = "";
      CGO_ENABLED = "1";
      FLAKE = configDir;
    };

    # Update and switch aliases (run from the nix-config checkout).
    home.shellAliases = {
      qaup = "bash scripts/update-inputs/update-maintained.sh";
      hmsw = "home-manager switch --flake .#alc-${hostName}";
    };

    # ==================== Packages ====================
    home.packages =
      pkgsets.hm.base
      ++ [
        inputs.grove.packages.${pkgs.stdenv.hostPlatform.system}.default
        inputs.canopy.packages.${pkgs.stdenv.hostPlatform.system}.default
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
    programs.workspace.enable = true;

    # Forgejo credential helper — moved to linux/common.nix and darwin/mac.nix
    # where the sops secret path is available for inline injection.

    #programs.wezterm.enable = true;

    programs.ncspot.enable = true;

    # ==================== Sops with age over ssh ====================
    # On NixOS, the system layer deploys ~/.ssh/id_ed25519(.pub) using the host
    # SSH key so first remote deploys do not depend on a Home Manager bootstrap
    # cycle. Home Manager can then use that SSH key to decrypt user/operator
    # secrets.
    sops = {
      age =
        if pkgs.stdenv.isDarwin
        then {
          keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
        }
        else {
          sshKeyPaths = ["${config.home.homeDirectory}/.ssh/id_ed25519"];
        };
      secrets =
        lib.optionalAttrs pkgs.stdenv.isDarwin {
          "ssh.${hostName}.private" = {
            sopsFile = hostSopsFile;
            key = "ssh_id_ed25519";
            path = "${config.home.homeDirectory}/.ssh/id_ed25519";
            mode = "0600";
          };
          "ssh.${hostName}.public" = {
            sopsFile = hostSopsFile;
            key = "ssh_id_ed25519.pub";
            path = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";
            mode = "0644";
          };
        }
        // operatorSshSecrets;
    };

    # Generate and manage the age key file
    home.activation.setupSopsAgeKey = lib.mkIf pkgs.stdenv.isDarwin (
      config.lib.dag.entryAfter ["writeBoundary"] ''
        age_dir="$HOME/.config/sops/age"
        age_key="$age_dir/keys.txt"
        ssh_key="$HOME/.ssh/id_ed25519"

        mkdir -p "$age_dir"
        if [ ! -f "$age_key" ] && [ -f "$ssh_key" ]; then
          ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key < "$ssh_key" > "$age_key"
          chmod 600 "$age_key"
        fi
      ''
    );

    home.activation.linkLinuxSystemSshKeys = lib.mkIf pkgs.stdenv.isLinux (
      lib.hm.dag.entryBetween ["sops-nix"] ["linkGeneration"] ''
        ssh_dir="${config.home.homeDirectory}/.ssh"
        install -d -m 0700 "$ssh_dir"

        if [ -e /run/secrets/${username}_ssh_private_key ]; then
          rm -f "$ssh_dir/id_ed25519"
          ln -s /run/secrets/${username}_ssh_private_key "$ssh_dir/id_ed25519"
        fi

        if [ -e /run/secrets/${username}_ssh_public_key ]; then
          rm -f "$ssh_dir/id_ed25519.pub"
          ln -s /run/secrets/${username}_ssh_public_key "$ssh_dir/id_ed25519.pub"
        fi
      ''
    );

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
