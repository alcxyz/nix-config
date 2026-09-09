{
  lib,
  pkgs,
}: let
  evaluate = settings:
    (lib.evalModules {
      specialArgs = {inherit pkgs;};
      modules = [
        ../../modules/nixos/hardware/display-device-guard.nix
        {
          options.services.udev.extraRules = lib.mkOption {
            type = lib.types.lines;
            default = "";
          };
          options.systemd.services = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = {};
          };
          config.hardware.displayDeviceGuard = settings;
        }
      ];
    }).config;
  settings = {
    enable = true;
    pciAddress = "0000:01:02.3";
    pciId = "ABCD:1234";
    driver = "test_gpu";
    deviceName = "fixture-display";
    requiredBy = ["fixture-greeter.service"];
  };
  enabled = evaluate settings;
  disabled = evaluate {};
  service = enabled.systemd.services.gpu-display-guard;
  invalidAddress = builtins.tryEval (evaluate (settings // {pciAddress = "invalid;command";})).hardware.displayDeviceGuard.pciAddress;
  invalidAlias = builtins.tryEval (evaluate (settings // {deviceName = "../escape";})).hardware.displayDeviceGuard.deviceName;
  fixture = pkgs.writeText "display-device-guard-fixture.json" (builtins.toJSON {
    inherit (service) script;
    inherit settings;
    udevadm = "${pkgs.systemd}/bin/udevadm";
  });
in
  assert disabled.systemd.services == {};
  assert disabled.services.udev.extraRules == "";
  assert service.requiredBy == settings.requiredBy;
  assert service.before == settings.requiredBy;
  assert service.serviceConfig.Type == "oneshot";
  assert lib.hasInfix ''ATTRS{vendor}=="0xabcd"'' enabled.services.udev.extraRules;
  assert lib.hasInfix ''ATTRS{device}=="0x1234"'' enabled.services.udev.extraRules;
  assert lib.hasInfix ''DEVPATH=="*/0000:01:02.3/drm/card[0-9]*"'' enabled.services.udev.extraRules;
  assert lib.hasInfix ''DRIVERS=="test_gpu"'' enabled.services.udev.extraRules;
  assert lib.hasInfix ''SYMLINK+="dri/fixture-display"'' enabled.services.udev.extraRules;
  assert !invalidAddress.success;
  assert !invalidAlias.success;
    pkgs.runCommand "display-device-guard-contract" {
      nativeBuildInputs = [pkgs.python3 pkgs.bash];
    } ''
      python3 ${../../scripts/checks/test-display-device-guard.py} ${fixture}
      touch "$out"
    ''
