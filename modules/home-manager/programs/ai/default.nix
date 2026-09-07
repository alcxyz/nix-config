# modules/home-manager/programs/ai/default.nix
{
  config,
  lib,
  pkgs,
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
  mergeClaudeSettings = pkgs.writeShellApplication {
    name = "merge-claude-settings";
    runtimeInputs = [ pkgs.coreutils pkgs.jq ];
    text = builtins.readFile ./merge-settings.sh;
  };
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
      run ${mergeClaudeSettings}/bin/merge-claude-settings \
        "${config.home.homeDirectory}/.claude/settings.json" "${claudeManagedSettings}"
    '';
  };

}
