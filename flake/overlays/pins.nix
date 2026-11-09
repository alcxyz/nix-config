# Applies the package pins in flake/pins.nix (ADR-0110).
{
  lib,
  inputs,
  system,
  pins,
  # The contract check passes a silent one, so only real pins warn.
  warn ? lib.warn,
}: _final: prev: let
  fields = ["input" "reason" "whileBroken"];

  # True when the primary package exists and evaluates to a derivation;
  # tryEval catches the `throw` of a removed or broken package.
  evaluates = name: let
    result = builtins.tryEval (prev ? ${name} && builtins.isString prev.${name}.drvPath);
  in
    result.success && result.value;

  pinned = name: pin: let
    unknown = lib.subtractLists fields (builtins.attrNames pin);
  in
    if unknown != []
    then throw "flake/pins.nix: ${name} has unknown fields: ${toString unknown}"
    else if (pin.reason or "") == ""
    then throw "flake/pins.nix: ${name} needs a reason"
    else if !(inputs ? ${pin.input or ""})
    then throw "flake/pins.nix: ${name} names input '${pin.input or ""}', which flake.nix does not declare"
    else if (pin.whileBroken or false) && evaluates name
    then warn "flake/pins.nix: ${name} evaluates in nixpkgs again, so its pin no longer applies; remove the entry" prev.${name}
    else inputs.${pin.input}.legacyPackages.${system}.${name};
in
  lib.mapAttrs pinned pins
