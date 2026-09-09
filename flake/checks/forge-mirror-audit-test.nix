{lib}: let
  credentials = {
    sopsFile = "/credentials/secrets.yaml";
    forgejoKey = "forgejo-token";
    githubKey = "github-token";
  };
  pkgs = {
    git = "/git";
    coreutils = "/coreutils";
    forge-mirror = "/forge-mirror";
    writeShellScript = _: text: text;
    writeText = name: text: "/policy/${name}-${toString (builtins.stringLength text)}";
  };
  evaluate = serviceName: serviceModule: settings:
    lib.evalModules {
      specialArgs = {
        inputs = {};
        inherit pkgs;
      };
      modules = [
        serviceModule
        {
          options = {
            assertions = lib.mkOption {type = lib.types.listOf lib.types.attrs;};
            sops = lib.mkOption {
              type = lib.types.attrsOf (lib.types.attrsOf (lib.types.attrsOf lib.types.anything));
            };
            systemd = lib.mkOption {type = lib.types.attrs;};
          };
          config = {
            services.${serviceName} =
              {
                enable = true;
                inherit credentials;
              }
              // settings;
            sops.secrets = {
              forge_mirror_forgejo_token.path = "/credentials/forgejo";
              forge_mirror_github_token.path = "/credentials/github";
            };
          };
        }
      ];
    };
  evaluateAudit = evaluate "forge-mirror-audit" ../../modules/nixos/services/forge-mirror-audit;
  evaluatePull = evaluate "forge-mirror-pull" ../../modules/nixos/services/forge-mirror-pull;
  assertionsPass = evaluated: lib.all (entry: entry.assertion) evaluated.config.assertions;
  auditExec = evaluated: evaluated.config.systemd.services.forge-mirror-audit.serviceConfig.ExecStart;
  pullExec = evaluated: evaluated.config.systemd.services.forge-mirror-pull.serviceConfig.ExecStart;

  auditPopulated = evaluateAudit {
    forgejoUrl = "https://forge.example";
    forgejoUser = "forgejo-account";
    githubUser = "github-account";
    githubPrimaryRepositories = [
      "one"
      "two"
    ];
    githubDeniedRepositories = ["blocked"];
    requiredPrivateRepositories = ["internal"];
  };
  auditEmptyPolicies = evaluateAudit {
    forgejoUrl = "https://forge.example";
    forgejoUser = "forgejo-account";
    githubUser = "github-account";
    githubPrimaryRepositories = [];
    githubDeniedRepositories = [];
    requiredPrivateRepositories = [];
  };
  auditMissingPolicy = evaluateAudit {
    forgejoUrl = "https://forge.example";
    forgejoUser = "forgejo-account";
    githubUser = "github-account";
    githubPrimaryRepositories = [];
    requiredPrivateRepositories = [];
  };
  auditEmptyScalar = evaluateAudit {
    forgejoUrl = "https://forge.example";
    forgejoUser = "";
    githubUser = "github-account";
    githubPrimaryRepositories = [];
    githubDeniedRepositories = [];
    requiredPrivateRepositories = [];
  };
  auditMissingRequired = evaluateAudit {
    forgejoUrl = "https://forge.example";
    forgejoUser = "forgejo-account";
    githubUser = "github-account";
    githubPrimaryRepositories = [];
    githubDeniedRepositories = [];
    requiredPrivateRepositories = [];
    credentials = {};
  };
  auditLegacyCredential = evaluateAudit {
    forgejoUrl = "https://forge.example";
    forgejoUser = "forgejo-account";
    githubUser = "github-account";
    githubPrimaryRepositories = [];
    githubDeniedRepositories = [];
    requiredPrivateRepositories = [];
    credentials =
      credentials
      // {
        codebergKey = "legacy-codeberg-token";
      };
  };

  pullPopulated = evaluatePull {
    forgejoUrl = "https://forge.example";
    forgejoUser = "forgejo-account";
  };
  pullEmptyScalar = evaluatePull {
    forgejoUrl = "https://forge.example";
    forgejoUser = "";
  };
  pullMissingScalar = evaluatePull {forgejoUrl = "https://forge.example";};
  pullMissingCredentials = evaluatePull {
    forgejoUrl = "https://forge.example";
    forgejoUser = "forgejo-account";
    credentials = {};
  };
  pullLegacyCredential = evaluatePull {
    forgejoUrl = "https://forge.example";
    forgejoUser = "forgejo-account";
    credentials =
      credentials
      // {
        codebergKey = "legacy-codeberg-token";
      };
  };
in
  assert assertionsPass auditPopulated;
  assert lib.hasInfix "export FORGEJO_USER=forgejo-account" (auditExec auditPopulated);
  assert lib.hasInfix "export GITHUB_USER=github-account" (auditExec auditPopulated);
  assert lib.hasInfix "https://forge.example" (auditExec auditPopulated);
  assert lib.hasInfix
  "FORGE_MIRROR_GITHUB_PRIMARY_REPOS_FILE=/policy/forge-mirror-github-primary-repos-7"
  (auditExec auditPopulated);
  assert lib.hasInfix
  "FORGE_MIRROR_GITHUB_DENIED_REPOS_FILE=/policy/forge-mirror-github-denied-repos-7"
  (auditExec auditPopulated);
  assert lib.hasInfix
  "FORGE_MIRROR_REQUIRED_PRIVATE_REPOS_FILE=/policy/forge-mirror-required-private-repos-8"
  (auditExec auditPopulated);
  assert lib.hasInfix "GITHUB_MIRROR_PAT_FILE=\"/credentials/github\"" (auditExec auditPopulated);
  assert !(lib.hasInfix "CODEBERG_MIRROR_PAT" (auditExec auditPopulated));
  assert lib.hasInfix "exec /forge-mirror/bin/forge-mirror audit" (auditExec auditPopulated);
  assert lib.hasInfix
  "FORGE_MIRROR_GITHUB_PRIMARY_REPOS_FILE=/policy/forge-mirror-github-primary-repos-0"
  (auditExec auditEmptyPolicies);
  assert lib.hasInfix
  "FORGE_MIRROR_GITHUB_DENIED_REPOS_FILE=/policy/forge-mirror-github-denied-repos-0"
  (auditExec auditEmptyPolicies);
  assert lib.hasInfix
  "FORGE_MIRROR_REQUIRED_PRIVATE_REPOS_FILE=/policy/forge-mirror-required-private-repos-0"
  (auditExec auditEmptyPolicies);
  assert !(builtins.tryEval (auditExec (evaluateAudit {}))).success;
  assert !(builtins.tryEval (auditExec auditMissingPolicy)).success;
  assert !(builtins.tryEval (auditExec auditEmptyScalar)).success;
  assert !(assertionsPass auditMissingRequired);
  assert assertionsPass auditLegacyCredential;
  assert !(auditLegacyCredential.config.sops.secrets ? forge_mirror_codeberg_token);
  assert !(lib.hasInfix "CODEBERG_MIRROR_PAT" (auditExec auditLegacyCredential));
  assert assertionsPass pullPopulated;
  assert lib.hasInfix "export FORGEJO_USER=forgejo-account" (pullExec pullPopulated);
  assert lib.hasInfix "https://forge.example" (pullExec pullPopulated);
  assert lib.hasInfix "GITHUB_MIRROR_PAT_FILE=\"/credentials/github\"" (pullExec pullPopulated);
  assert !(lib.hasInfix "CODEBERG_MIRROR_PAT" (pullExec pullPopulated));
  assert lib.hasInfix "exec /forge-mirror/bin/forge-mirror pull" (pullExec pullPopulated);
  assert !(lib.hasInfix "GITHUB_USER=" (pullExec pullPopulated));
  assert !(builtins.tryEval (pullExec pullEmptyScalar)).success;
  assert !(builtins.tryEval (pullExec pullMissingScalar)).success;
  assert !(assertionsPass pullMissingCredentials);
  assert assertionsPass pullLegacyCredential;
  assert !(pullLegacyCredential.config.sops.secrets ? forge_mirror_codeberg_token);
  assert !(lib.hasInfix "CODEBERG_MIRROR_PAT" (pullExec pullLegacyCredential)); true
