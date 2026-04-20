# modules/home-manager/programs/karabiner/default.nix
#
# Declarative Karabiner Elements config that mirrors kanata-mac-builtin.kbd.
# Generates karabiner.json and deploys it via activation script (Karabiner
# needs a writable file — a nix-store symlink would break its auto-save).
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf;

  # ── Shared parameters (mirror kanata defvar) ──────────────────────────
  tap  = 150;
  hold = 150;
  tapNav  = 100;  # shorter for nav layer triggers
  holdNav = 100;

  # ── Helpers ───────────────────────────────────────────────────────────
  # Tap-hold: tap produces a character, hold produces a modifier.
  mkTapHold = { key, tapKey ? key, holdKey, holdMods ? [], timeout ? tap }:
    {
      type = "basic";
      from = { key_code = key; modifiers.optional = [ "any" ]; };
      to_if_alone = [{ key_code = tapKey; halt = true; }];
      to_if_held_down = [
        ({ key_code = holdKey; } // lib.optionalAttrs (holdMods != []) { modifiers = holdMods; })
      ];
      to_delayed_action = {
        to_if_canceled = [{ key_code = tapKey; }];
        to_if_invoked  = [{ key_code = "vk_none"; }];
      };
      parameters = {
        "basic.to_if_alone_timeout_milliseconds"     = timeout;
        "basic.to_if_held_down_threshold_milliseconds" = timeout;
      };
    };

  # Nav layer trigger: tap = key, hold = set variable.
  mkNavTrigger = { key, timeout ? tapNav }:
    {
      type = "basic";
      from = { key_code = key; modifiers.optional = [ "any" ]; };
      to = [{ set_variable = { name = "nav_layer"; value = 1; }; }];
      to_after_key_up = [{ set_variable = { name = "nav_layer"; value = 0; }; }];
      to_if_alone = [{ key_code = key; }];
      parameters = {
        "basic.to_if_alone_timeout_milliseconds"     = timeout;
        "basic.to_if_held_down_threshold_milliseconds" = timeout;
      };
    };

  navCondition = [{ type = "variable_if"; name = "nav_layer"; value = 1; }];

  # Nav layer arrow mapping.
  mkNavArrow = from: to:
    {
      type = "basic";
      conditions = navCondition;
      from = { key_code = from; modifiers.optional = [ "any" ]; };
      to = [{ key_code = to; }];
    };

  # Nav layer Norwegian character (Option key sequence).
  # unshifted: Option+optKey (+ optional second key for dead-key combos)
  # shifted:   Option+Shift+optKey (+ optional Shift+second key)
  mkNorwegianChar = { from, optKey, secondKey ? null }:
    let
      baseTo = [{ key_code = optKey; modifiers = [ "left_option" ]; }]
        ++ lib.optionals (secondKey != null) [{ key_code = secondKey; }];
      shiftTo = [{ key_code = optKey; modifiers = [ "left_option" "left_shift" ]; }]
        ++ lib.optionals (secondKey != null) [{ key_code = secondKey; modifiers = [ "left_shift" ]; }];
    in [
      # Shifted variant (must come first — more specific match)
      {
        type = "basic";
        conditions = navCondition;
        from = { key_code = from; modifiers.mandatory = [ "shift" ]; modifiers.optional = [ "any" ]; };
        to = shiftTo;
      }
      # Unshifted variant
      {
        type = "basic";
        conditions = navCondition;
        from = { key_code = from; modifiers.optional = [ "any" ]; };
        to = baseTo;
      }
    ];

  # ── Rules ─────────────────────────────────────────────────────────────
  rules = [
    # 1. Caps Lock: tap = Escape, hold = Left Control
    {
      description = "Caps Lock → Escape / Left Control";
      manipulators = [{
        type = "basic";
        from = { key_code = "caps_lock"; modifiers.optional = [ "any" ]; };
        to = [{ key_code = "left_control"; }];
        to_if_alone = [{ key_code = "escape"; }];
        parameters."basic.to_if_alone_timeout_milliseconds" = tap;
      }];
    }

    # 2. Tab: tap = Tab, hold = Left Option
    {
      description = "Tab → Tab / Left Option";
      manipulators = [
        (mkTapHold { key = "tab"; holdKey = "left_option"; })
      ];
    }

    # 3–4. Nav layer triggers (backtick + ISO < key)
    {
      description = "Backtick / ISO< → Nav layer toggle";
      manipulators = [
        (mkNavTrigger { key = "grave_accent_and_tilde"; })
        (mkNavTrigger { key = "non_us_backslash"; })
      ];
    }

    # 5. Nav layer: hjkl → arrows
    {
      description = "Nav layer: hjkl → arrows";
      manipulators = [
        (mkNavArrow "h" "left_arrow")
        (mkNavArrow "j" "down_arrow")
        (mkNavArrow "k" "up_arrow")
        (mkNavArrow "l" "right_arrow")
      ];
    }

    # 6. Nav layer: Norwegian characters (é ø æ å)
    #    Uses macOS Option key sequences (requires US/ABC input source)
    {
      description = "Nav layer: Norwegian characters (éøæå)";
      manipulators =
        (mkNorwegianChar { from = "e";         optKey = "e"; secondKey = "e"; })  # é / É
        ++ (mkNorwegianChar { from = "hyphen";    optKey = "o"; })                 # ø / Ø
        ++ (mkNorwegianChar { from = "quote";     optKey = "quote"; })             # æ / Æ
        ++ (mkNorwegianChar { from = "semicolon"; optKey = "a"; });                # å / Å
    }

    # 7. Home row mods — left hand
    {
      description = "Home row mods (left): a=Hyper s=Alt d=Ctrl f=Shift";
      manipulators = [
        (mkTapHold { key = "a"; holdKey = "left_shift";
                     holdMods = [ "left_control" "left_command" "left_option" ]; })  # Hyper
        (mkTapHold { key = "s"; holdKey = "left_option"; })
        (mkTapHold { key = "d"; holdKey = "left_control"; })
        (mkTapHold { key = "f"; holdKey = "left_shift"; })
      ];
    }

    # 8. Home row mods — right hand (mirrored)
    {
      description = "Home row mods (right): j=Shift k=Ctrl l=Alt ;=Meh";
      manipulators = [
        (mkTapHold { key = "j"; holdKey = "right_shift"; })
        (mkTapHold { key = "k"; holdKey = "right_control"; })
        (mkTapHold { key = "l"; holdKey = "right_option"; })
        (mkTapHold { key = "semicolon"; tapKey = "semicolon"; holdKey = "right_shift";
                     holdMods = [ "right_control" "right_option" ]; })  # Meh (Ctrl+Shift+Alt, no Cmd)
      ];
    }
  ];

  # ── Full config ───────────────────────────────────────────────────────
  karabinerConfig = {
    profiles = [{
      name = "Default profile";
      selected = true;
      complex_modifications = {
        parameters."basic.to_if_held_down_threshold_milliseconds" = hold;
        inherit rules;
      };
      virtual_hid_keyboard = {
        country_code = 0;
        keyboard_type_v2 = "iso";
      };
    }];
  };

  configJSON = builtins.toJSON karabinerConfig;
  configFile = pkgs.writeText "karabiner.json" configJSON;

in {
  options.programs.karabiner.managed = {
    enable = mkEnableOption "Declarative Karabiner Elements configuration (mirrors kanata-mac-builtin.kbd)";
  };

  config = mkIf config.programs.karabiner.managed.enable {
    home.activation.karabinerConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      karabiner_dir="$HOME/.config/karabiner"
      karabiner_json="$karabiner_dir/karabiner.json"

      mkdir -p "$karabiner_dir"

      if [ ! -f "$karabiner_json" ] || ! diff -q "${configFile}" "$karabiner_json" >/dev/null 2>&1; then
        cp "${configFile}" "$karabiner_json"
        chmod 644 "$karabiner_json"
        echo "Karabiner config updated"
      fi
    '';
  };
}
