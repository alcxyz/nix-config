{
  lib,
  pkgs,
}: let
  evaluate = extra:
    (lib.evalModules {
      specialArgs = {inherit pkgs;};
      modules = [
        ../../modules/home-manager/programs/git/default.nix
        ({lib, ...}: {
          options = {
            home.homeDirectory = lib.mkOption {default = "/home/fixture";};
            xdg.configHome = lib.mkOption {default = "/home/fixture/.config";};
            home.file = lib.mkOption {
              type = lib.types.attrs;
              default = {};
            };
            assertions = lib.mkOption {
              type = lib.types.listOf lib.types.attrs;
              default = [];
            };
            programs.git.enable = lib.mkEnableOption "Git";
            programs.git.signing = lib.mkOption {type = lib.types.attrs;};
            programs.git.settings = lib.mkOption {type = lib.types.attrs;};
            programs.delta = lib.mkOption {type = lib.types.attrs;};
          };
          config.programs.git.managed = {
            enable = true;
            extraConfig.core.editor = "fixture-editor";
          };
        })
        extra
      ];
    }).config;
  unguarded = evaluate {};
  guarded = evaluate {
    programs.git.managed.identityProtection = {
      enable = true;
      package = pkgs.emptyDirectory;
      policyFile = "/fixture/policy.json";
    };
  };
  missingPolicy = evaluate {
    programs.git.managed.identityProtection = {
      enable = true;
      package = pkgs.emptyDirectory;
    };
  };
in
  assert unguarded.programs.git.settings.user.email == "6753563+alcxyz@users.noreply.github.com";
  assert unguarded.programs.git.settings.user.useConfigOnly;
  assert !(unguarded.programs.git.settings.core ? hooksPath);
  assert guarded.programs.git.settings.core.editor == "fixture-editor";
  assert guarded.programs.git.settings.core.hooksPath == "${pkgs.emptyDirectory}/share/git-identity-guard/hooks";
  assert guarded.programs.git.settings.identityGuard.policyFile == "/fixture/policy.json";
  assert lib.all (a: a.assertion) guarded.assertions;
  assert !(lib.all (a: a.assertion) missingPolicy.assertions);
    pkgs.runCommand "git-identity-configuration-contract" {} ''
      touch "$out"
    ''
