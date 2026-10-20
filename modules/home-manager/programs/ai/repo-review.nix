# modules/home-manager/programs/ai/repo-review.nix
#
# Whole-repository reviews with revkit (nix-packages ADR-0011, #557). The
# package ships no reviewers or lenses; this module generates its versioned
# JSON configuration and installs `revkit` with it. Reviews are read-only and
# write a local report and findings store under $XDG_STATE_HOME/revkit; a run
# files nothing. `revkit findings file` files only the findings the operator
# picks, and only once the private configuration sets `issueTokenFile`.
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
with lib; let
  cfg = config.programs.ai;
  rr = cfg.repoReview;

  repositoryType = types.submodule {
    options = {
      context = mkOption {
        type = types.lines;
        default = "";
        description = "What the repository is, told to every reviewer before the lens.";
      };
      lenses = mkOption {
        type = types.attrsOf types.lines;
        description = "Lens name to its prompt: one review job per lens and reviewer.";
      };
      issues = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            url = mkOption {
              type = types.str;
              default = "https://git.alc.xyz";
              description = "Forge whose issue tracker `revkit findings file` files in.";
            };
            owner = mkOption {type = types.str;};
            repo = mkOption {type = types.str;};
            limit = mkOption {
              type = types.ints.positive;
              default = 5;
              description = "Issues one `revkit findings file` command may file.";
            };
          };
        });
        default = null;
        description = "Tracker for the repository's findings; filed with `repoReview.issueTokenFile`.";
      };
    };
  };

  adrDrift = ''
    ADR drift. Read the accepted ADRs in docs/adr/ (index docs/adr/README.md),
    newest first, at most fifteen. For each, compare what the Decision and its
    amendments say with the code and configuration they apply to ("Applies
    to" line, and paths the ADR names). Report where the code contradicts the
    decision, where the ADR still describes a mechanism, option, file or
    command that no longer exists or works differently, and where the index
    status disagrees with the ADR's own status line.'';
  docsDrift = scope: ''
    Documentation drift. Scope: ${scope}. Report where they name a path, host,
    option, command, flag or procedure that the repository no longer has or
    that works differently from what they describe, and documents that
    contradict each other.'';
  staleMechanisms = scope: ''
    Stale mechanisms and dead code. Scope: ${scope}. Report: options or
    settings that nothing reads; scripts, assets or functions that nothing
    installs or calls; logic duplicated between files that has already
    diverged; and safeguards whose premise an ADR or a later change has
    removed (the repository rule is to remove mechanisms built on a disproved
    premise).'';
  outsideTree = ''
    Some referenced material lives in private repositories that are not
    checked out; do not report a reference as broken only because its target
    is outside this tree.'';

  revkitConfig =
    {
      schemaVersion = 1;
      inherit (rr) reviewers;
      timeoutSeconds = rr.timeout;
      # NixOS's /etc/zshenv resets PATH unless this is set, which would point
      # Codex's shell at profile directories in its empty home.
      environment = ["__NIXOS_SET_ENVIRONMENT_DONE"];
      # The managed Codex guard hook finds the guard in the user's profile.
      homeLinks = [".nix-profile"];
      # Reviewer commands such as rg, git and nix live in the store.
      readablePaths = ["/nix/store"];
      repositories = mapAttrsToList (name: repo:
        {
          inherit name;
          inherit (repo) context;
          lenses =
            mapAttrsToList (lens: prompt: {
              name = lens;
              inherit prompt;
            })
            repo.lenses;
        }
        # Filing needs both a tracker and the bot's token.
        // optionalAttrs (repo.issues != null && rr.issueTokenFile != null) {
          issues = repo.issues // {tokenFile = rr.issueTokenFile;};
        })
      rr.repositories;
    }
    // optionalAttrs (rr.matcher != null) {inherit (rr) matcher;};

  # The configuration is checked at build time: every repository is planned
  # with revkit against an empty repository of its name, so a schema or
  # validation error fails the build instead of a review.
  revkitConfigFile =
    pkgs.runCommand "revkit.json" {
      nativeBuildInputs = [pkgs.revkit pkgs.git];
      config = builtins.toJSON revkitConfig;
      passAsFile = ["config"];
    } ''
      cp "$configPath" "$out"
      # A dry run creates no state; the path only has to be outside /tmp,
      # which revkit refuses for Codex reviewers.
      export HOME="$TMPDIR/home" XDG_STATE_HOME=/nonexistent/revkit-check GIT_CONFIG_NOSYSTEM=1
      ${concatMapStrings (name: ''
        repo="$TMPDIR/repos/"${escapeShellArg name}
        git init -q "$repo"
        git -C "$repo" -c user.name=check -c user.email=check@example.invalid commit -q --allow-empty -m check
        revkit repo-review --config "$out" --repository ${escapeShellArg name} --dry-run "$repo" >/dev/null
      '') (attrNames rr.repositories)}
    '';

  revkit = pkgs.writeShellApplication {
    name = "revkit";
    text = ''REVKIT_CONFIG=${revkitConfigFile} exec ${pkgs.revkit}/bin/revkit "$@"'';
  };
in {
  options.programs.ai.repoReview = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Install `revkit` for read-only whole-repository reviews, whose findings the operator may file (nix-packages ADR-0011).";
    };
    lenses = mkOption {
      type = types.attrsOf types.lines;
      description = ''
        Shared lenses included in both public repository defaults alongside
        their three scoped lenses. Without --lens, revkit runs all five;
        select code-audit or adr-review explicitly for a bounded audit.
        Extra attributes extend the built-ins; override one to replace it.
      '';
      default = {
        code-audit = ''
          Audit the whole repository, read-only. Read the code, documentation,
          tests and available Git history. Do not write files, run builds that
          need writes, or use the network. Find, in order of importance:
          1. Correctness bugs: logic errors, unhandled errors, races, data loss
             and wrong edge cases.
          2. Security problems: injection, authentication or permission gaps,
             unsafe input handling and secret handling.
          3. Important code paths without meaningful tests.
          4. Dependency risks visible in manifests and lock files. State what
             should be checked; do not guess CVEs or current package status
             without network evidence.
          5. Documentation that contradicts the code, dead code and unused
             configuration.

          Report only concrete findings supported by file and line evidence.
          Explain the impact and suggest a small fix suitable for one pull
          request. Skip style nits and generic advice. Do not open files that
          contain secret material, encrypted or plaintext; inspect only their
          paths and the surrounding wiring and configuration. Never reproduce
          secret values or private, client or personal details. If such data
          is committed, report only its path and kind of data.
        '';
        adr-review = ''
          Review the complete architecture decision record set, read-only.
          Read the ADR index (usually docs/adr/README.md) and every ADR, with
          no limit on their number. Check them against the current code,
          configuration and documentation. Do not write files or use the
          network. Look for:
          1. Drift: implementation that contradicts an accepted decision.
          2. Dead decisions: components or mechanisms that no longer exist,
             or decisions superseded in practice without a superseded status.
          3. Conflicts: contradictory decisions or later decisions that
             silently override earlier ones.
          4. Weak decisions: reasoning undermined by changes or disproved
             premises, or a clearly better alternative the decision missed.
             Explain what changed and what to reconsider; do not relitigate
             taste or assume an existing decision may be changed.
          5. Hygiene: wrong or missing status, broken references and index
             entries that disagree with their ADRs.
          6. Gaps: significant policy clearly enforced by the code that no
             ADR records.

          Support each finding with its ADR path and section, plus file and
          line evidence from the implementation where relevant. Explain
          whether the code or ADR should change, or a superseding decision
          needs consideration. Skip wording nits. Do not call external
          references broken merely because their targets are outside this
          tree. Do not guess CVEs or current dependency status without
          network evidence. Do not open files containing secret material,
          encrypted or plaintext; inspect only their paths and surrounding
          wiring and configuration. Never reproduce secret values or private,
          client or personal details. If such data is committed, report only
          its path and kind of data. If the repository has no ADRs, do not
          invent missing decisions without evidence of significant policy.
        '';
      };
    };
    reviewers = mkOption {
      # The same reviewer type as pr-review's, with its name check and effort
      # default.
      inherit (options.programs.ai.prReview.reviewers) type;
      default = cfg.prReview.reviewers;
      defaultText = literalExpression "config.programs.ai.prReview.reviewers";
      description = "Reviewers of each lens; each one's findings are verified by the next.";
    };
    matcher = mkOption {
      type = types.nullOr options.programs.ai.prReview.reviewers.type.nestedTypes.elemType;
      default =
        if cfg.roles ? light
        then {
          name = "matcher";
          client = "claude";
          inherit (cfg.roles.light.claude) model effort;
        }
        else null;
      defaultText = literalExpression "the `light` role's Claude model, or null";
      description = "Reviewer that matches findings by meaning with earlier runs (revkit 0.2 and later); null matches by lens and title.";
    };
    issueTokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Token file of the bot account `revkit findings file` files issues as, set by the private configuration; null disables filing.";
    };
    timeout = mkOption {
      type = types.ints.positive;
      default = 3600;
      description = "Seconds before a reviewer run is stopped and recorded as a missing review.";
    };
    repositories = mkOption {
      type = types.attrsOf repositoryType;
      description = "Repositories `revkit repo-review` knows, by the name of their checkout directory.";
      default = {
        nix-config = {
          context = ''
            The repository is a public NixOS / Home Manager configuration (nix-config).
            Architecture decisions are in docs/adr/ (index docs/adr/README.md); repository
            rules are in AGENTS.md. ${outsideTree}'';
          lenses =
            {
              adr-drift = adrDrift;
              stale-mechanisms = staleMechanisms "modules/home-manager/programs/ai/ and the checks in scripts/checks/ and flake/checks/ that test it";
              docs-drift = docsDrift "AGENTS.md, README.md, every Markdown file under docs/ except docs/adr/, and module READMEs";
            }
            // rr.lenses;
          issues = {
            owner = "alcxyz";
            repo = "nix-config";
          };
        };
        nix-packages = {
          context = ''
            The repository is a public Nix flake of packages and tools (nix-packages).
            Architecture decisions are in docs/adr/ (index docs/adr/README.md); repository
            rules are in AGENTS.md. ${outsideTree}'';
          lenses =
            {
              adr-drift = adrDrift;
              stale-mechanisms = staleMechanisms "tools/ and the CI scripts in scripts/ci/ and .forgejo/workflows/";
              docs-drift = docsDrift "AGENTS.md, README.md, every Markdown file under docs/ except docs/adr/, and the READMEs and changelogs under tools/ and pkgs/";
            }
            // rr.lenses;
          issues = {
            owner = "alcxyz";
            repo = "nix-packages";
          };
        };
      };
      defaultText = "Shared lenses plus adr-drift, docs-drift and stale-mechanisms for nix-config and nix-packages";
    };
  };

  config = mkMerge [
    {
      # Apply the default prompts per key, so adding a shared lens retains
      # the built-ins rather than replacing the attrsOf option's whole default.
      programs.ai.repoReview.lenses = mapAttrs (_: value: mkDefault value) options.programs.ai.repoReview.lenses.default;
    }
    (mkIf (cfg.enable && rr.enable) {
      home.packages = [revkit];
    })
  ];
}
