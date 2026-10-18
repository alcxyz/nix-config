# shellcheck shell=bash
# Shared by the T3 thread commands (ADR-0091). A thread ID goes into sqlite
# dot-commands and shell commands the user runs, so allow only the characters
# T3 uses in IDs.
t3_valid_id() {
  [[ $1 =~ ^[A-Za-z0-9:%._-]+$ ]]
}
