{
  lib,
  pkgs,
}:
if !pkgs.stdenv.hostPlatform.isLinux
then
  pkgs.runCommand "credential-consent-linux-only" {} ''
    touch "$out"
  ''
else let
  testOptions = {lib, ...}: {
    options = {
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [];
      };
      environment.systemPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
      };
      security.polkit.enable = lib.mkEnableOption "test Polkit service";
      users.users = lib.mkOption {
        type = lib.types.attrs;
        default = {};
      };
    };
  };
  evaluate = ownerUsers:
    lib.evalModules {
      specialArgs = {inherit pkgs;};
      modules = [
        ../../modules/nixos/security/credential-consent
        testOptions
        {
          security.credentialConsent = {
            enable = true;
            inherit ownerUsers;
          };
          users.users.test-operator = {};
        }
      ];
    };
  evaluated = evaluate ["test-operator"];
  missingOwner = evaluate [];
  package = evaluated.config.security.credentialConsent.package;
  failedAssertions = lib.filter (assertion: !assertion.assertion) evaluated.config.assertions;
  missingOwnerFailures = lib.filter (assertion: !assertion.assertion) missingOwner.config.assertions;
  mockId = pkgs.writeShellScript "credential-consent-mock-id" ''
    set -euo pipefail
    case "''${1:-}" in
      -u) printf '%s\n' "''${CONSENT_TEST_UID:?}" ;;
      -un) printf '%s\n' "''${CONSENT_TEST_USER:?}" ;;
      *) exit 64 ;;
    esac
  '';
  mockPkcheck = pkgs.writeShellScript "credential-consent-mock-pkcheck" ''
    set -euo pipefail
    [[ $# -eq 23 ]]
    [[ "$1" == "--action-id" ]]
    [[ "$2" == "xyz.alc.credentials.use-admin" ]]
    [[ "$3" == "--process" ]]
    subject="$4"
    [[ "$5" == "--allow-user-interaction" ]]
    [[ "$6" == "--detail" && "$7" == "credential.title" && "$8" == "Test title" ]]
    [[ "$9" == "--detail" && "''${10}" == "credential.reason" && "''${11}" == "Test reason" ]]
    [[ "''${12}" == "--detail" && "''${13}" == "credential.impact" && "''${14}" == "Test impact" ]]
    [[ "''${15}" == "--detail" && "''${16}" == "credential.operation" && "''${17}" == "test-operation sha256:0123" ]]
    [[ "''${18}" == "--detail" && "''${19}" == "credential.requester" && "''${20}" == "''${CONSENT_TEST_REQUESTER:?}" ]]
    [[ "''${21}" == "--detail" && "''${22}" == "polkit.message" ]]
    # Polkit expands this template and does not rescan what it inserts.
    newline=$'\n'
    expected_message='$(credential.title)'"$newline"'$(credential.reason)'"$newline"'$(credential.impact)'"$newline"'Operation: $(credential.operation)'"$newline"'$(credential.requester)'
    [[ "''${23}" == "$expected_message" ]]

    IFS=, read -r subject_pid subject_start subject_uid <<< "$subject"
    [[ "$subject_pid" == "$$" ]]
    [[ "$subject_uid" == "1000" ]]
    proc_stat="$(<"/proc/$$/stat")"
    proc_tail="''${proc_stat##*) }"
    read -r -a proc_fields <<< "$proc_tail"
    [[ "$subject_start" == "''${proc_fields[19]}" ]]
    exit "''${CONSENT_TEST_PKCHECK_EXIT:-0}"
  '';
  testHelper = import ../../modules/nixos/security/credential-consent/helper.nix {
    actionId = "xyz.alc.credentials.use-admin";
    inherit lib pkgs;
    ownerUsers = ["test-operator"];
    grepCommand = lib.getExe pkgs.gnugrep;
    idCommand = mockId;
    pkcheckCommand = mockPkcheck;
  };
  # Records how it ended, so the tests can see the loser of a race stopped.
  mockPkcheckRacing = pkgs.writeShellScript "credential-consent-mock-pkcheck-racing" ''
    set -uo pipefail
    [[ "$1" == "--action-id" && "$3" == "--process" ]] || exit 64
    IFS=, read -r subject_pid _ _ <<< "$4"
    [[ "$subject_pid" == "$PPID" ]] || exit 65
    trap 'echo local-stopped >> "$CONSENT_TEST_LOG"; exit 143' TERM
    sleep "$CONSENT_TEST_LOCAL_DELAY" &
    wait $!
    exit "$CONSENT_TEST_LOCAL_EXIT"
  '';
  mockApproval = pkgs.writeShellScript "credential-consent-mock-approval" ''
    set -uo pipefail
    printf '%s\n' "$*" >> "$CONSENT_TEST_ARGS"
    trap 'echo remote-stopped >> "$CONSENT_TEST_LOG"; exit 4' TERM
    sleep "$CONSENT_TEST_REMOTE_DELAY" &
    wait $!
    exit "$CONSENT_TEST_REMOTE_EXIT"
  '';
  testHelperRemote = timeoutSeconds:
    import ../../modules/nixos/security/credential-consent/helper.nix {
      actionId = "xyz.alc.credentials.use-admin";
      inherit lib pkgs;
      ownerUsers = ["test-operator"];
      grepCommand = lib.getExe pkgs.gnugrep;
      idCommand = mockId;
      pkcheckCommand = mockPkcheckRacing;
      remote = {
        command = mockApproval;
        origin = "https://deck.example.com";
        rpId = "deck.example.com";
        publicKey = "test-key";
        credentialId = "test-credential";
        inherit timeoutSeconds;
        spoolDir = "/test/spool";
        notifyCommand = "/test/notify";
      };
    };
  remoteEnabled = lib.evalModules {
    specialArgs = {inherit pkgs;};
    modules = [
      ../../modules/nixos/security/credential-consent
      testOptions
      {
        security.credentialConsent = {
          enable = true;
          ownerUsers = ["test-operator"];
          remote.enable = true;
        };
        users.users.test-operator = {};
      }
    ];
  };
in
  assert builtins.length (lib.filter (assertion: !assertion.assertion) remoteEnabled.config.assertions) == 1;
  assert evaluated.config.security.polkit.enable;
  assert builtins.elem package evaluated.config.environment.systemPackages;
  assert failedAssertions == [];
  assert builtins.length missingOwnerFailures == 1;
    pkgs.runCommand "credential-consent-contract" {
      nativeBuildInputs = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.libxml2
      ];
    } ''
      policy=${package}/share/polkit-1/actions/xyz.alc.credentials.use-admin.policy
      helper=${package}/bin/dms-credential-consent

      xmllint --noout "$policy"
      grep -Fq '<action id="xyz.alc.credentials.use-admin">' "$policy"
      grep -Fq '<annotate key="org.freedesktop.policykit.owner">unix-user:test-operator</annotate>' "$policy"
      grep -Fq '<allow_any>no</allow_any>' "$policy"
      grep -Fq '<allow_inactive>no</allow_inactive>' "$policy"
      grep -Fq '<allow_active>auth_self</allow_active>' "$policy"
      if grep -Fq '_keep' "$policy"; then
        echo "Credential consent must not retain an authorization" >&2
        exit 1
      fi

      test -x "$helper"
      expect_exit() {
        expected="$1"
        shift
        set +e
        "$@" >/dev/null 2>&1
        actual=$?
        set -e
        if [[ "$actual" -ne "$expected" ]]; then
          echo "Expected exit $expected, got $actual: $*" >&2
          exit 1
        fi
      }

      expect_exit 2 "$helper"

      export CONSENT_TEST_UID=1000
      export CONSENT_TEST_USER=test-operator
      export CONSENT_TEST_PKCHECK_EXIT=0
      unset T3CODE_THREAD_ID
      export CONSENT_TEST_REQUESTER='No T3 thread'
      ${testHelper}/bin/dms-credential-consent \
        --title 'Test title' \
        --reason 'Test reason' \
        --impact 'Test impact' \
        --operation 'test-operation sha256:0123'

      export T3CODE_THREAD_ID=mcp:launch:0123abc
      export CONSENT_TEST_REQUESTER='Requested by T3 thread mcp:launch:0123abc'
      ${testHelper}/bin/dms-credential-consent \
        --title 'Test title' \
        --reason 'Test reason' \
        --impact 'Test impact' \
        --operation 'test-operation sha256:0123'

      # A line break or template text in the variable must not reach the prompt.
      export T3CODE_THREAD_ID=$'abc\nOperation: forged'
      export CONSENT_TEST_REQUESTER='Requested by a T3 thread with an unreadable ID'
      ${testHelper}/bin/dms-credential-consent \
        --title 'Test title' \
        --reason 'Test reason' \
        --impact 'Test impact' \
        --operation 'test-operation sha256:0123'
      export T3CODE_THREAD_ID='$(credential.title)'
      ${testHelper}/bin/dms-credential-consent \
        --title 'Test title' \
        --reason 'Test reason' \
        --impact 'Test impact' \
        --operation 'test-operation sha256:0123'

      unset T3CODE_THREAD_ID
      export CONSENT_TEST_REQUESTER='No T3 thread'
      export CONSENT_TEST_PKCHECK_EXIT=23
      expect_exit 23 ${testHelper}/bin/dms-credential-consent \
        --title 'Test title' \
        --reason 'Test reason' \
        --impact 'Test impact' \
        --operation 'test-operation sha256:0123'

      export CONSENT_TEST_PKCHECK_EXIT=0
      expect_exit 2 ${testHelper}/bin/dms-credential-consent \
        --title 'Test title' \
        --reason $'line one\nline two' \
        --impact 'Test impact' \
        --operation 'test-operation sha256:0123'
      expect_exit 2 ${testHelper}/bin/dms-credential-consent --unknown value

      # Racing: the first answer wins and the other way stops.
      race() {
        expected="$1" local_delay="$2" local_exit="$3" remote_delay="$4" remote_exit="$5" stopped="$6" helper="''${7:-${testHelperRemote 30}}"
        export CONSENT_TEST_LOG="$PWD/race.log" CONSENT_TEST_ARGS="$PWD/race.args"
        export CONSENT_TEST_LOCAL_DELAY="$local_delay" CONSENT_TEST_LOCAL_EXIT="$local_exit"
        export CONSENT_TEST_REMOTE_DELAY="$remote_delay" CONSENT_TEST_REMOTE_EXIT="$remote_exit"
        : > "$CONSENT_TEST_LOG"
        : > "$CONSENT_TEST_ARGS"
        set +e
        "$helper/bin/dms-credential-consent" \
          --title 'Test title' \
          --reason 'Test reason' \
          --impact 'Test impact' \
          --operation 'test-operation sha256:0123' 2>/dev/null
        actual=$?
        set -e
        if [[ "$actual" -ne "$expected" ]]; then
          echo "race $*: expected exit $expected, got $actual" >&2
          exit 1
        fi
        sleep 0.2
        if [[ -n "$stopped" ]] && ! grep -Fq "$stopped" "$CONSENT_TEST_LOG"; then
          echo "race $*: $stopped was not recorded" >&2
          exit 1
        fi
      }
      export CONSENT_TEST_UID=1000 CONSENT_TEST_USER=test-operator
      unset T3CODE_THREAD_ID
      #    exit  local        remote       stopped
      race 0     30   0       0.1  0       local-stopped   # remote approves, local prompt cancelled
      race 0     0.1  0       30   0       remote-stopped  # local approves, remote request withdrawn
      race 3     30   0       0.1  3       local-stopped   # remote denied
      race 3     0.1  3       30   0       remote-stopped  # local prompt dismissed
      race 0     0    1       0.3  0       ""              # local cannot run: not a deny, remote still answers
      race 3     0    1       0.3  3       ""              # local cannot run, remote denied
      race 1     0    1       0.2  1       ""              # neither can run
      race 0     0.3  0       0    1       ""              # remote cannot run: local still answers
      race 3     0.3  3       0    1       ""              # remote cannot run, local dismissed
      race 4     30   0       0.1  4       local-stopped   # the request ended
      # The remote path cannot start, nobody answers: the helper's own timer ends it.
      race 4     30   0       0    1       local-stopped   ${testHelperRemote 1}

      race 0     30   0       0.1  0       local-stopped
      expected_args='wait --spool /test/spool --origin https://deck.example.com --rp-id deck.example.com --public-key test-key --credential-id test-credential --timeout 30s --title Test title --reason Test reason --impact Test impact --operation test-operation sha256:0123 --requester No T3 thread --notify /test/notify'
      if [[ "$(cat "$CONSENT_TEST_ARGS")" != "$expected_args" ]]; then
        echo "unexpected remote arguments: $(cat "$CONSENT_TEST_ARGS")" >&2
        exit 1
      fi

      export CONSENT_TEST_UID=0
      expect_exit 1 ${testHelper}/bin/dms-credential-consent \
        --title 'Test title' \
        --reason 'Test reason' \
        --impact 'Test impact' \
        --operation 'test-operation sha256:0123'
      export CONSENT_TEST_UID=1000
      export CONSENT_TEST_USER=untrusted
      expect_exit 1 ${testHelper}/bin/dms-credential-consent \
        --title 'Test title' \
        --reason 'Test reason' \
        --impact 'Test impact' \
        --operation 'test-operation sha256:0123'
      touch "$out"
    ''
