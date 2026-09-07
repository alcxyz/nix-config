let
  evaluate = self:
    (import ./configurations.nix {
      inherit self;
      pkgs.runCommand = _: _: _: true;
    })
    .configuration-evaluation;
  valid = {
    nixosConfigurations.host.config.system.build.toplevel.drvPath = "/nix/store/system.drv";
    homeConfigurations.user.activationPackage.drvPath = "/nix/store/home.drv";
    darwinConfigurations.host.system.drvPath = "/nix/store/darwin.drv";
  };
  fails = output: !(builtins.tryEval (evaluate (valid // output))).success;
in
  assert evaluate valid;
  assert fails {nixosConfigurations.host.config.system.build.toplevel.drvPath = throw "invalid NixOS deployment";};
  assert fails {homeConfigurations.user.activationPackage.drvPath = throw "invalid Home Manager deployment";};
  assert fails {darwinConfigurations.host.system.drvPath = throw "invalid Darwin deployment";};
  assert fails {homeConfigurations = valid.homeConfigurations // {alias.activationPackage.drvPath = throw "invalid alias";};}; true
