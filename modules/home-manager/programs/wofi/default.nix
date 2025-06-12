# modules/home-manager/programs/wofi/default.nix
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
with lib;

let
  cfg = config.programs.wofi.managed;

  # --- Theming (Unchanged) ---
  colorscheme = inputs.nix-colors.colorschemes.${config.colorscheme.name};
  colors = colorscheme.palette;
  substituteColors = text:
    let
      colorPlaceholders = [
        "@base00@" "@base01@" "@base02@" "@base03@" "@base04@" "@base05@"
        "@base06@" "@base07@" "@base08@" "@base09@" "@base0a@" "@base0b@"
        "@base0c@" "@base0d@" "@base0e@" "@base0f@"
      ];
      colorValues = [
        colors.base00 colors.base01 colors.base02 colors.base03 colors.base04
        colors.base05 colors.base06 colors.base07 colors.base08 colors.base09
        colors.base0A colors.base0B colors.base0C colors.base0D colors.base0E
        colors.base0F
      ];
    in builtins.replaceStrings colorPlaceholders colorValues text;
  styleTemplate = builtins.readFile ./style.css.template;
  processedStyle = substituteColors styleTemplate;

  # --- Declarative Script Generation ---
  intelligentRunner =
    let
      promptModes = concatStringsSep " | " (
        map (mode: "${mode.prefix}:${mode.description}")
        (attrValues cfg.intelligentModes)
      );
      promptStr = "Run: ${promptModes} | (math) | <app>";
      elifBlocks = concatMapStringsSep "\n" (mode: ''
        elif [[ "$query" == "${mode.prefix}" || "$query" == "${mode.prefix} "* ]]; then
            sub_query=$(echo "$query" | sed -E 's/^${mode.prefix} ?//')
            ${mode.command}
      '') (attrValues cfg.intelligentModes);
    in
    pkgs.writeShellScriptBin "wofi-intelligent-runner" ''
      #!${pkgs.bash}/bin/bash
      query=$( ${pkgs.wofi}/bin/wofi --dmenu --prompt "${promptStr}" )

      if [[ -z "$query" ]]; then exit 0; fi

      if [[ "$query" == *[+\-\*\/\^\(\)]* && "$query" != "-" ]]; then
        if echo "scale=4; $query" | ${pkgs.bc}/bin/bc -l >/dev/null 2>&1; then
          ${cfg.calculatorMode.command}
          exit 0
        fi
      fi

      if false; then
        :
      ${elifBlocks}
      else
          ${cfg.defaultMode.command}
      fi
    '';
in {
  options.programs.wofi.managed = {
    enable = mkEnableOption "Managed Wofi configuration";
    package = mkOption {
      type = types.package;
      readOnly = true;
    };
    terminal = mkOption {
      type = types.str;
      default = "${pkgs.foot}/bin/foot";
      description = "The terminal command to use for launching TUI apps.";
    };
    intelligentModes = mkOption {
      type = with types;
        attrsOf (submodule {
          options = {
            prefix = mkOption { type = str; };
            description = mkOption { type = str; };
            command = mkOption { type = lines; };
            packages = mkOption {
              type = listOf package;
              default = [];
            };
          };
        });
    };
    calculatorMode = mkOption {
      type = with types; submodule {
        options = {
          command = mkOption { type = lines; };
          packages = mkOption {
            type = listOf package;
            default = [];
          };
        };
      };
    };
    defaultMode = mkOption {
      type = with types; submodule {
        options = {
          command = mkOption { type = lines; };
          packages = mkOption {
            type = listOf package;
            default = [];
          };
        };
      };
    };
  };

  config = mkIf cfg.enable {
    programs.wofi.managed.package = intelligentRunner;
    home.packages =
      (concatMap (mode: mode.packages) (attrValues cfg.intelligentModes))
      ++ cfg.calculatorMode.packages
      ++ cfg.defaultMode.packages
      ++ [ cfg.package ];

    programs.wofi.enable = true;
    xdg.configFile."wofi/config".source = ./config;
    xdg.configFile."wofi/style.css".text = processedStyle;

    programs.wofi.managed.intelligentModes = {
      files = {
        prefix = "f";
        description = "Files";
        packages = with pkgs; [ fd xdg-utils ];
        command =
          ''${pkgs.fd}/bin/fd "$sub_query" ~ | ${pkgs.wofi}/bin/wofi --dmenu | xargs --no-run-if-empty xdg-open'';
      };
      bitwarden = {
        prefix = "bw";
        description = "PWs";
        packages = with pkgs; [ rbw rofi-rbw ];
        command =
          ''${pkgs.rofi-rbw}/bin/rofi-rbw --rofi-args "-filter $sub_query"'';
      };
      web-search = {
        prefix = "?";
        description = "Web";
        packages = with pkgs; [ python3 xdg-utils ];
        command = ''
          engine="https://duckduckgo.com/?q="
          encoded_query=$(${pkgs.python3}/bin/python -c "import urllib.parse; print(urllib.parse.quote_plus('''$sub_query'''))")
          ${pkgs.xdg-utils}/bin/xdg-open "$engine$encoded_query"
        '';
      };
      # UPDATED: Spotify Control with F2 Global Search
      spotify = {
        prefix = "sp";
        description = "Spotify Search";
        packages = with pkgs; [ ncspot wtype ];
        command = ''
          # Launch ncspot in the background
          ${cfg.terminal} ${pkgs.ncspot}/bin/ncspot &
          sleep 0.5 # Give ncspot a moment to launch

          if [[ -n "$sub_query" ]]; then
            # 1. Press F2 to open the global search prompt
            ${pkgs.wtype}/bin/wtype -k F2
            sleep 0.1
            # 2. Type the search query
            ${pkgs.wtype}/bin/wtype -s 10 "$sub_query"
            sleep 0.1
            # 3. Press Enter to execute the search
            ${pkgs.wtype}/bin/wtype -M shift -P enter -m shift
          fi
        '';
      };
      translate = {
        prefix = "tr";
        description = "Translate";
        packages = with pkgs; [ translate-shell wl-clipboard libnotify ];
        command = ''
          target_lang="en"
          text_to_translate="$sub_query"

          first_word=$(echo "$sub_query" | awk '{print $1}')
          if [[ ''${#first_word} -eq 2 ]]; then
            target_lang="$first_word"
            text_to_translate=$(echo "$sub_query" | cut -d' ' -f2-)
          fi

          translation=$(${pkgs.translate-shell}/bin/trans -brief -t "$target_lang" "$text_to_translate")
          chosen_line=$(echo "$translation" | ${pkgs.wofi}/bin/wofi --dmenu --prompt="Enter to copy, Esc to close")
          if [[ -n "$chosen_line" ]]; then
            echo -n "$chosen_line" | ${pkgs.wl-clipboard}/bin/wl-copy
            ${pkgs.libnotify}/bin/notify-send "Translator" "Copied to clipboard:\n$chosen_line"
          fi
        '';
      };
    };

    programs.wofi.managed.calculatorMode = {
      packages = with pkgs; [ bc wl-clipboard libnotify ];
      command = ''
        result=$(echo "scale=4; $query" | ${pkgs.bc}/bin/bc -l)
        chosen_line=$(echo "$result" | ${pkgs.wofi}/bin/wofi --dmenu --prompt="Enter to copy, Esc to close")
        if [[ -n "$chosen_line" ]]; then
          echo -n "$chosen_line" | ${pkgs.wl-clipboard}/bin/wl-copy
          ${pkgs.libnotify}/bin/notify-send "Calculator" "Copied to clipboard:\n$chosen_line"
        fi
      '';
    };

    programs.wofi.managed.defaultMode = {
      packages = with pkgs; [ wofi ];
      command = ''${pkgs.wofi}/bin/wofi --show drun --term "$query"'';
    };
  };
}
