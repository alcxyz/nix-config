{
  lib,
  pkgs,
}:
if !pkgs.stdenv.hostPlatform.isLinux
then pkgs.runCommand "home-cache-trim-linux-only" {} ''touch "$out"''
else let
  evaluate = cacheDirectories:
    (lib.evalModules {
      specialArgs = {inherit pkgs;};
      modules = [
        ../../modules/home-manager/services/home-cache-trim/default.nix
        {
          options.home.packages = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [];
          };
          options.systemd.user = {
            services = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = {};
            };
            timers = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = {};
            };
          };
          config.services.home-cache-trim = {
            enable = true;
            inherit cacheDirectories;
            podmanImageMaxAgeDays = 30;
          };
        }
      ];
    }).config;
  config = evaluate ["BraveSoftware" "missing-dir"];
  service = config.systemd.user.services.home-cache-trim.Service;
  script = lib.getExe (lib.head config.home.packages);
in
  assert service.Nice == 15;
  assert service.IOSchedulingClass == "idle";
  assert lib.hasInfix "/run/wrappers/bin" service.Environment;
    pkgs.runCommand "home-cache-trim-contract" {} ''
      set -eu
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME/.cache/BraveSoftware" "$HOME/.cache/unlisted" "$TMPDIR/bin"
      touch -d '60 days ago' "$HOME/.cache/BraveSoftware/old"
      touch "$HOME/.cache/BraveSoftware/young"
      touch -d '60 days ago' "$HOME/.cache/unlisted/old"

      # Records its arguments and fails when PODMAN_FAIL is set.
      cat > "$TMPDIR/bin/podman" <<'EOF'
      #!/bin/sh
      printf '%s\n' "$*" >> "$PODMAN_LOG"
      if [ -n "$PODMAN_FAIL" ]; then exit 1; fi
      EOF
      chmod +x "$TMPDIR/bin/podman"
      export PATH="$TMPDIR/bin:$PATH"
      export PODMAN_LOG="$TMPDIR/podman.log"

      if ! ${script} > "$TMPDIR/run.log" 2>&1; then
        cat "$TMPDIR/run.log"
        echo "home-cache-trim failed on a clean run" >&2
        exit 1
      fi
      test ! -e "$HOME/.cache/BraveSoftware/old"
      test -e "$HOME/.cache/BraveSoftware/young"
      test -e "$HOME/.cache/unlisted/old"
      grep -Fxq 'image prune --all --force --filter until=720h' "$PODMAN_LOG"

      # The directories are trimmed before the failing prune makes the run fail.
      touch -d '60 days ago' "$HOME/.cache/BraveSoftware/old-again"
      if PODMAN_FAIL=1 ${script} > "$TMPDIR/run2.log" 2>&1; then
        cat "$TMPDIR/run2.log"
        echo "a failing podman image prune must fail the script" >&2
        exit 1
      fi
      test ! -e "$HOME/.cache/BraveSoftware/old-again"
      grep -Fq 'podman image prune failed' "$TMPDIR/run2.log"
      touch "$out"
    ''
