{lib}: let
  secretsSource = "/nix/store/00000000000000000000000000000000-source";
  check = configurations:
    import ./secrets-source-isolation.nix {
      inherit lib secretsSource;
      configurations =
        {
          nixos = {};
          home = {};
          darwin = {};
        }
        // configurations;
    };
  fails = configurations: !(builtins.tryEval (check configurations)).success;
  copied = "/nix/store/11111111111111111111111111111111-hosts-host-secrets.yaml";
  inSource = "${secretsSource}/hosts/host/secrets.yaml";
in
  assert check {
    nixos.host.config = {
      sops.secrets.token.sopsFile = copied;
      environment.etc."app.conf".source = "/nix/store/22222222222222222222222222222222-app.conf";
    };
    home.user.config.home.file.".config/app".source = copied;
  };
  assert check {nixos.host.config = {};};
  assert fails {nixos.host.config.sops.secrets.token.sopsFile = inSource;};
  assert fails {darwin.host.config.environment.etc."app.conf".source = inSource;};
  assert fails {nixos.host.config.home-manager.users.user.home.file.".config/app".source = inSource;};
  assert fails {home.user.config.home.file.".config/app".source = secretsSource;};
  assert fails {
    home.user.config.home.file.".config/app".source = {
      type = "derivation";
      outPath = "/nix/store/33333333333333333333333333333333-app";
      drvAttrs.buildCommand = "ln -s ${inSource} $out";
    };
  }; true
