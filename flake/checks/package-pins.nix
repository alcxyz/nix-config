# Evaluation contract for the package pins overlay (ADR-0110), on synthetic
# package sets so it does not depend on what nixpkgs currently ships.
{
  lib,
  pkgs,
}: let
  system = pkgs.stdenv.hostPlatform.system;
  primary = pkgs.writeText "primary" "primary";
  pinned = pkgs.writeText "pinned" "pinned";
  prev = {
    working = primary;
    removed = throw "removed from nixpkgs";
  };
  inputs.pinned-set.legacyPackages.${system} = {
    working = pinned;
    removed = pinned;
  };
  apply = pins:
    import ../overlays/pins.nix {
      inherit lib inputs system pins;
      warn = _message: value: value;
    } {}
    prev;
  pin = extra:
    {
      input = "pinned-set";
      reason = "test";
    }
    // extra;
  fails = pins: name: !(builtins.tryEval (apply pins).${name}.drvPath).success;

  expectations = {
    "a whileBroken pin applies while the primary package throws" =
      (apply {removed = pin {whileBroken = true;};}).removed == pinned;
    "a whileBroken pin yields the primary package once it evaluates" =
      (apply {working = pin {whileBroken = true;};}).working == primary;
    "a plain pin always applies" =
      (apply {working = pin {};}).working == pinned;
    "a pin without a reason fails" =
      fails {working = {input = "pinned-set";};} "working";
    "a pin naming an undeclared input fails" =
      fails {working = pin {input = "missing";};} "working";
    "a pin with an unknown field fails" =
      fails {working = pin {whilebroken = true;};} "working";
    "every entry in flake/pins.nix uses only known fields" =
      lib.all (entry: lib.subtractLists ["input" "reason" "whileBroken"] (builtins.attrNames entry) == [])
      (builtins.attrValues (import ../pins.nix));
  };
  holds = expectation: let
    result = builtins.tryEval expectation;
  in
    result.success && result.value;
  failed = lib.attrNames (lib.filterAttrs (_: expectation: !(holds expectation)) expectations);
in
  if failed == []
  then pkgs.runCommand "package-pins-contract" {} "touch $out"
  else throw "package-pins-contract failed: ${lib.concatStringsSep "; " failed}"
