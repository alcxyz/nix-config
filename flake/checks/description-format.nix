{
  self,
  pkgs,
}: let
  lib = pkgs.lib;
  base = self.homeConfigurations.alc-xyz;
  off =
    (base.extendModules {
      modules = [{programs.ai.descriptionFormat.enable = lib.mkForce false;}];
    }).config;
  on =
    (base.extendModules {
      modules = [
        {
          programs.ai.descriptionFormat = {
            enable = lib.mkForce true;
            endAt = lib.mkForce "2099-01-01T00:00:00Z";
            repositories = lib.mkForce {
              "github.com/example/project" = {
                issue = false;
                pr = true;
              };
            };
          };
        }
      ];
    }).config;
  hooks = config: (builtins.fromJSON config.home.file.".codex/hooks.json".text).hooks.PreToolUse;
  commands = config: lib.concatMap (entry: map (hook: hook.command) entry.hooks) (hooks config);
  observer = command: lib.hasSuffix "/agent-description-format-observe --delivery codex-user" command;
  guards = config: builtins.filter (command: lib.hasSuffix "/agent-pr-review-guard" command) (commands config);
  observers = config: builtins.filter observer (commands config);
  package = config: name: lib.findFirst (item: item.name == name) null config.home.packages;
  system = self.nixosConfigurations.xyz.config;
  requirements = system.environment.etc."codex/requirements.toml".source;
  managedObserver = pkgs.writeText "description-observer-managed.sh" system.environment.etc."codex/hooks/agent-description-format-observe".text;
  badDate =
    (base.extendModules {
      modules = [{programs.ai.descriptionFormat.endAt = lib.mkForce "2026-11-05";}];
    }).config.programs.ai.descriptionFormat.endAt;
  subpath =
    (base.extendModules {
      modules = [
        {
          programs.ai.descriptionFormat.enable = lib.mkForce false;
          programs.ai.forgejoMcp.url = lib.mkForce "https://forge.example.test/code";
        }
      ];
    }).config;
in
  assert observers off == [];
  assert builtins.length (observers on) == 2;
  assert guards on == guards off;
  assert lib.all (entry: lib.all (hook: !observer hook.command || hook.timeout == 5) entry.hooks) (
    hooks on
  );
  assert on.programs.ai.descriptionFormat.repositories."github.com/example/project".issue == false;
  assert !(builtins.tryEval badDate).success;
    pkgs.runCommand "description-format-wiring-contract"
    {
      nativeBuildInputs = [
        pkgs.python3
        pkgs.bash
      ];
    }
    ''
      # Validate with the actual packaged command, without a hook or event write.
      cat <<'BODY' | ${package on "description-format"}/bin/description-format validate --kind pr
      **What:** Synthetic package check.

      **Why:** Exercise the installed command.

      **Risk:** No forge writes.

      **Verification:** Offline package fixture.

      **After merge:** None.
      BODY
      bash -n ${package on "agent-description-format-observe"}/bin/agent-description-format-observe
      # A disabled observer must not break an existing subpath Forgejo consumer.
      test -x ${package subpath "agent-description-format-observe"}/bin/agent-description-format-observe
      bash -n ${managedObserver}
      python3 - ${requirements} <<'PY'
      import sys, tomllib
      with open(sys.argv[1], 'rb') as stream:
          policy = tomllib.load(stream)
      assert policy['features']['hooks'] is True
      entries = policy['hooks']['PreToolUse']
      assert [entry['matcher'] for entry in entries[:2]] == ['^Bash$', '^mcp__forgejo__']
      assert all(entry['hooks'][0]['command'].endswith('/agent-pr-review-guard') for entry in entries[:2])
      observer = entries[2]
      assert observer['matcher'] == '^(Bash$|mcp__forgejo__)'
      assert observer['hooks'][0]['command'].endswith('/agent-description-format-observe')
      assert observer['hooks'][0]['timeout'] == 5
      PY
      # Existing review commands still build alongside the independent observer.
      test -x ${package on "agent-pr-review-guard"}/bin/agent-pr-review-guard
      touch "$out"
    ''
