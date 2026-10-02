# modules/home-manager/programs/ai/roles.nix
#
# Agent model roles (ADR-0079): instructions and tools name a role, and this
# module generates each client's native role configuration from one table.
# Imported for every user that receives the shared agent instructions,
# independent of programs.ai.enable.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.programs.ai;
  roles = cfg.roles;
  home = config.home.homeDirectory;
  toml = pkgs.formats.toml {};

  # Built-in agent types of Claude Code and Codex that roles must not shadow.
  reservedNames = ["explore" "plan" "general-purpose" "claude" "statusline-setup" "default" "explorer" "awaiter" "worker"];

  clientOptions = client: efforts: {
    model = mkOption {
      type = types.str;
      description = "Model for ${client}. Claude accepts aliases such as `opus`; Codex needs an exact model.";
    };
    effort = mkOption {
      type = types.enum efforts;
      default = "medium";
      description = "Reasoning effort for ${client}.";
    };
  };

  codexRoleFile = name: role:
    toml.generate "codex-role-${name}.toml" {
      model = role.codex.model;
      model_reasoning_effort = role.codex.effort;
    };

  claudeAgent = name: role: ''
    ---
    name: ${name}
    description: ${builtins.toJSON role.description}
    model: ${role.claude.model}
    effort: ${role.claude.effort}
    ---
    You are a general-purpose software engineering agent. Follow the user's
    and repository's instructions, use the available tools as needed, and
    report results concisely.
  '';

  codexRegistrations = pkgs.writeText "codex-roles.json" (builtins.toJSON (mapAttrs (name: role: {
      inherit (role) description;
      config_file = "${home}/.codex/${name}.config.toml";
    })
    roles));

  mergeCodexRoles = pkgs.writeShellApplication {
    name = "merge-codex-roles";
    runtimeInputs = [(pkgs.python3.withPackages (ps: [ps.tomlkit]))];
    text = ''exec python3 ${./codex-roles.py} "$@"'';
  };

  llmEntry = role: {
    provider = "openai";
    model = role.codex.model;
    transport = "cli";
    api_key_env = "OPENAI_API_KEY";
    # Claude aliases are Claude Code names, not API model IDs, so the backup
    # always uses the CLI transport.
    backup = {
      provider = "anthropic";
      model = role.claude.model;
      transport = "cli";
      api_key_env = "ANTHROPIC_API_KEY";
    };
  };
in {
  options.programs.ai = {
    roles = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          description = mkOption {
            type = types.str;
            description = "When to use this role; shown to agents choosing a subagent type.";
          };
          codex = clientOptions "Codex" ["minimal" "low" "medium" "high" "xhigh"];
          claude = clientOptions "Claude Code" ["low" "medium" "high" "xhigh" "max"];
        };
      });
      default = {};
      description = "Agent model roles (ADR-0079), keyed by role name.";
    };

    llmConfigRoles = mkOption {
      type = types.attrsOf types.str;
      default = {};
      example = {
        fast = "build";
        strong = "build";
      };
      description = "Shared LLM config roles (ADR-0029) mapped to agent roles; generates ~/.config/llm/config.toml when set.";
    };
  };

  config = mkMerge [
    (mkIf (roles != {}) {
      assertions = [
        {
          assertion = all (name: builtins.match "[a-z][a-z0-9-]*" name != null && !(elem name reservedNames)) (attrNames roles);
          message = "programs.ai.roles names must be lowercase and must not shadow built-in agent types (${concatStringsSep ", " reservedNames}).";
        }
      ];

      warnings = optional (cfg.llmConfigRoles == {}) "programs.ai.roles is set but programs.ai.llmConfigRoles is empty, so ~/.config/llm/config.toml is not generated.";

      home.file =
        mapAttrs' (name: role: nameValuePair ".codex/${name}.config.toml" {source = codexRoleFile name role;}) roles
        // mapAttrs' (name: role: nameValuePair ".claude/agents/${name}.md" {text = claudeAgent name role;}) roles;

      xdg.configFile."llm/config.toml" = mkIf (cfg.llmConfigRoles != {}) {
        source = toml.generate "llm-config.toml" {
          roles = mapAttrs (_: role: llmEntry roles.${role}) cfg.llmConfigRoles;
        };
      };
    })
    {
      assertions = [
        {
          assertion = all (role: hasAttr role roles) (attrValues cfg.llmConfigRoles);
          message = "programs.ai.llmConfigRoles must name roles defined in programs.ai.roles.";
        }
      ];

      # Runs even without roles, so registrations of removed roles are cleaned up.
      # A config the merge cannot safely change only loses subagent role
      # registrations (`codex exec -p <role>` keeps working), so warn rather
      # than stopping the whole activation.
      home.activation.codexAgentRoles = lib.hm.dag.entryAfter ["writeBoundary"] ''
        run ${mergeCodexRoles}/bin/merge-codex-roles \
          ${escapeShellArg "${home}/.codex/config.toml"} \
          ${escapeShellArg "${config.xdg.stateHome}/agent-roles/codex-managed.json"} \
          ${codexRegistrations} \
          || warnEcho "Codex agent role registrations were not updated; see the message above."
      '';
    }
  ];
}
