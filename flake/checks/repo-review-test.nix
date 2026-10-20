{
  lib,
  pkgs,
}: let
  evaluate = extra:
    lib.evalModules {
      specialArgs = {inherit pkgs;};
      modules = [
        ../../modules/home-manager/programs/ai/repo-review.nix
        {
          options = {
            programs.ai.enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            programs.ai.roles = lib.mkOption {
              type = lib.types.attrs;
              default = {};
            };
            programs.ai.prReview.reviewers = lib.mkOption {
              type = lib.types.listOf (lib.types.attrsOf lib.types.str);
              default = [];
            };
            home.packages = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [];
            };
          };
        }
        extra
      ];
    };
  baseline = (evaluate {}).config;
  extended = (evaluate {programs.ai.repoReview.lenses.extra = "fixture extra";}).config;
  overridden = (evaluate {programs.ai.repoReview.lenses.code-audit = "fixture override";}).config;
  scopedOverride = (evaluate {programs.ai.repoReview.lenses.docs-drift = "fixture scoped override";}).config;
  publicLenses = ["adr-drift" "adr-review" "code-audit" "docs-drift" "stale-mechanisms"];
in
  assert baseline.home.packages == [];
  assert lib.attrNames baseline.programs.ai.repoReview.lenses == ["adr-review" "code-audit"];
  assert lib.all (repo: lib.attrNames repo.lenses == publicLenses) (lib.attrValues baseline.programs.ai.repoReview.repositories);
  assert lib.attrNames extended.programs.ai.repoReview.lenses == ["adr-review" "code-audit" "extra"];
  assert extended.programs.ai.repoReview.repositories.nix-config.lenses.extra == "fixture extra";
  assert overridden.programs.ai.repoReview.lenses.code-audit == "fixture override";
  assert overridden.programs.ai.repoReview.lenses.adr-review == baseline.programs.ai.repoReview.lenses.adr-review;
  assert overridden.programs.ai.repoReview.repositories.nix-packages.lenses.code-audit == "fixture override";
  assert lib.all (repo: repo.lenses.docs-drift == "fixture scoped override") (lib.attrValues scopedOverride.programs.ai.repoReview.repositories); true
