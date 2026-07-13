# modules/home-manager/programs/ai/default.nix
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

with lib;

let
  cfg = config.programs.ai;
  claudeManagedSettings = pkgs.writeText "claude-managed-settings.json" (
    builtins.toJSON {
      statusLine = {
        type = "command";
        command = "dankaiusage claude-statusline";
        padding = 0;
      };
    }
  );
in
{
  options.programs.ai = {
    enable = mkEnableOption "Module for vibe coding stuff";
  };

  config = mkIf cfg.enable {
    programs.opencode = {
      enable = true;
      tui = {
        theme = "opencode";
      };
    };

    # programs.gemini-cli = {
    #   enable = true;
    # };

    home.activation.claudeStatusline = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      settings_file="${config.home.homeDirectory}/.claude/settings.json"
      settings_tmp="$settings_file.tmp"

      mkdir -p "$(${pkgs.coreutils}/bin/dirname "$settings_file")"

      if [ -e "$settings_file" ] && ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$settings_file" "${claudeManagedSettings}" > "$settings_tmp"; then
        mv "$settings_tmp" "$settings_file"
      else
        cp "${claudeManagedSettings}" "$settings_file"
        rm -f "$settings_tmp"
      fi

      chmod 600 "$settings_file"
    '';
  };

}
