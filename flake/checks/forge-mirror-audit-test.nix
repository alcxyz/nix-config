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
    curl = "/curl";
    gnugrep = "/gnugrep";
    python3 = "/python3";
    writeShellScript = _: text: text;
    writeText = name: text: "/policy/${name}-${toString (builtins.stringLength text)}";
  };
  evaluateWith = extra: serviceName: serviceModule: settings:
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
            # Stand-ins for the common modules the audit alert reads and
            # extends.
            services.storage-health-monitor = {
              enable = lib.mkEnableOption "storage monitor stand-in";
              pingBaseFile = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
            };
            networking.hostName = lib.mkOption {
              type = lib.types.str;
              default = "Fixture";
            };
            services.nixfleet-boot-check.ignoredFailedUnits = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
            };
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
        {config = extra;}
      ];
    };
  evaluate = evaluateWith {};
  evaluateAudit = evaluate "forge-mirror-audit" ../../modules/nixos/services/forge-mirror-audit;
  evaluatePull = evaluate "forge-mirror-pull" ../../modules/nixos/services/forge-mirror-pull;
  auditSettings = {
    forgejoUrl = "https://forge.example";
    forgejoUser = "forgejo-account";
    githubUser = "github-account";
    githubPrimaryRepositories = [];
    githubDeniedRepositories = [];
    requiredPrivateRepositories = [];
  };
  monitored = {
    services.storage-health-monitor = {
      enable = true;
      pingBaseFile = "/run/fixture-project-base";
    };
  };
  evaluateMonitoredAudit = evaluateWith monitored "forge-mirror-audit" ../../modules/nixos/services/forge-mirror-audit;
  auditAlertMessage = "services.forge-mirror-audit.alert needs a project pingBaseFile, supplied explicitly or by storage-health-monitor.pingBaseFile.";
  failedAssertion = evaluated: message:
    lib.any (entry: !entry.assertion && entry.message == message) evaluated.config.assertions;
  auditAlertOff = evaluateMonitoredAudit auditSettings;
  auditAlertMonitored = evaluateMonitoredAudit (auditSettings // {alert.enable = true;});
  auditAlertExplicit = evaluateAudit (auditSettings
    // {
      alert = {
        enable = true;
        pingBaseFile = "/run/fixture-explicit-base";
        slug = "fixture-audit";
      };
    });
  auditAlertMissingBase = evaluateAudit (auditSettings // {alert.enable = true;});
  auditService = evaluated: evaluated.config.systemd.services.forge-mirror-audit.serviceConfig;
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
  auditSeparateForgejoFile = evaluateAudit {
    forgejoUrl = "https://forge.example";
    forgejoUser = "forgejo-account";
    githubUser = "github-account";
    githubPrimaryRepositories = [];
    githubDeniedRepositories = [];
    requiredPrivateRepositories = [];
    credentials = credentials // {forgejoSopsFile = "/credentials/forgejo.yaml";};
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

  pullPopulated = evaluatePull {
    forgejoUrl = "https://forge.example";
    forgejoUser = "forgejo-account";
  };
  pullSeparateForgejoFile = evaluatePull {
    forgejoUrl = "https://forge.example";
    forgejoUser = "forgejo-account";
    credentials = credentials // {forgejoSopsFile = "/credentials/forgejo.yaml";};
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
in
  assert assertionsPass auditPopulated;
  assert auditPopulated.config.sops.secrets.forge_mirror_forgejo_token.sopsFile == credentials.sopsFile;
  assert auditSeparateForgejoFile.config.sops.secrets.forge_mirror_forgejo_token.sopsFile == "/credentials/forgejo.yaml";
  assert auditSeparateForgejoFile.config.sops.secrets.forge_mirror_github_token.sopsFile == credentials.sopsFile;
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
  assert assertionsPass pullPopulated;
  assert pullPopulated.config.sops.secrets.forge_mirror_forgejo_token.sopsFile == credentials.sopsFile;
  assert pullSeparateForgejoFile.config.sops.secrets.forge_mirror_forgejo_token.sopsFile == "/credentials/forgejo.yaml";
  assert pullSeparateForgejoFile.config.sops.secrets.forge_mirror_github_token.sopsFile == credentials.sopsFile;
  assert lib.hasInfix "export FORGEJO_USER=forgejo-account" (pullExec pullPopulated);
  assert lib.hasInfix "https://forge.example" (pullExec pullPopulated);
  assert lib.hasInfix "GITHUB_MIRROR_PAT_FILE=\"/credentials/github\"" (pullExec pullPopulated);
  assert lib.hasInfix "exec /forge-mirror/bin/forge-mirror pull" (pullExec pullPopulated);
  assert !(lib.hasInfix "GITHUB_USER=" (pullExec pullPopulated));
  assert !(builtins.tryEval (pullExec pullEmptyScalar)).success;
  assert !(builtins.tryEval (pullExec pullMissingScalar)).success;
  assert !(assertionsPass pullMissingCredentials);
  # The alert defaults follow the storage monitor and leave the unit alone
  # until enabled.
  assert auditAlertOff.config.services.forge-mirror-audit.alert.slug == "forge-mirror-audit-fixture";
  assert auditAlertOff.config.services.forge-mirror-audit.alert.pingBaseFile == "/run/fixture-project-base";
  assert (evaluateAudit auditSettings).config.services.forge-mirror-audit.alert.pingBaseFile == null;
  assert auditAlertOff.config.services.nixfleet-boot-check.ignoredFailedUnits == [];
  assert lib.hasInfix "exec /forge-mirror/bin/forge-mirror audit" (auditExec auditAlertOff);
  assert !(auditService auditAlertOff ? RuntimeDirectory);
  # Enabled, it pings the shared project base and no longer fails the boot
  # check.
  assert assertionsPass auditAlertMonitored;
  assert auditAlertMonitored.config.services.nixfleet-boot-check.ignoredFailedUnits == ["forge-mirror-audit.service"];
  assert (auditService auditAlertMonitored).RuntimeDirectory == "forge-mirror-audit";
  assert lib.hasInfix "base /run/fixture-project-base forge-mirror-audit-fixture" (auditExec auditAlertMonitored);
  assert lib.hasInfix "send_ping /start" (auditExec auditAlertMonitored);
  assert lib.hasInfix "send_ping /fail" (auditExec auditAlertMonitored);
  assert lib.hasInfix "exit \"$status\"" (auditExec auditAlertMonitored);
  assert !(lib.hasInfix "exec /forge-mirror/bin/forge-mirror audit" (auditExec auditAlertMonitored));
  assert lib.hasInfix "base /run/fixture-explicit-base fixture-audit" (auditExec auditAlertExplicit);
  # Without a project base the alert is refused.
  assert failedAssertion auditAlertMissingBase auditAlertMessage;
  assert !(failedAssertion auditAlertMonitored auditAlertMessage); true
