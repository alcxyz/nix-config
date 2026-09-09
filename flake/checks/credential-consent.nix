{
  lib,
  pkgs,
}:
if !pkgs.stdenv.isLinux
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
    [[ $# -eq 17 ]]
    [[ "$1" == "--action-id" ]]
    [[ "$2" == "xyz.alc.credentials.use-admin" ]]
    [[ "$3" == "--process" ]]
    subject="$4"
    [[ "$5" == "--allow-user-interaction" ]]
    [[ "$6" == "--detail" && "$7" == "credential.title" && "$8" == "Test title" ]]
    [[ "$9" == "--detail" && "''${10}" == "credential.reason" && "''${11}" == "Test reason" ]]
    [[ "''${12}" == "--detail" && "''${13}" == "credential.impact" && "''${14}" == "Test impact" ]]
    [[ "''${15}" == "--detail" && "''${16}" == "credential.operation" && "''${17}" == "test-operation sha256:0123" ]]

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
in
  assert evaluated.config.security.polkit.enable;
  assert builtins.elem package evaluated.config.environment.systemPackages;
  assert failedAssertions == [];
  assert builtins.length missingOwnerFailures == 1;
    pkgs.runCommand "credential-consent-contract" {
      nativeBuildInputs = [
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
      ${testHelper}/bin/dms-credential-consent \
        --title 'Test title' \
        --reason 'Test reason' \
        --impact 'Test impact' \
        --operation 'test-operation sha256:0123'

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
