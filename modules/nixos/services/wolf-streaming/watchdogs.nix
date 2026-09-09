{
  hostPublicCoordinator,
  isolatedProtectedBackend,
  protectedPort,
  protectedRuntimeDirectory,
  publicRuntimeDirectory,
  readPythonSource,
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.wolf-streaming;
  nvidiaSmi = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";
  mkWolfVramWatchdog = {
    name,
    containerName,
    serviceName,
    stateFile,
  }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.docker
        pkgs.gawk
        pkgs.systemd
      ];
      text = ''
          state_file=${lib.escapeShellArg stateFile}

        if ! systemctl --quiet is-active ${lib.escapeShellArg serviceName}; then
          rm -f "$state_file"
          exit 0
        fi
        if ! docker inspect ${lib.escapeShellArg containerName} >/dev/null 2>&1; then
          # The OCI unit becomes active just before `docker run` creates the
          # named container. Treat that short startup window as healthy.
          rm -f "$state_file"
          exit 0
        fi

        total_mib="$(
            ${nvidiaSmi} \
              --query-gpu=memory.total \
              --format=csv,noheader,nounits \
              | awk -F, 'NR == 1 { gsub(/[[:space:]]/, "", $1); print $1 }'
          )"
          wolf_pid="$(
            docker top ${lib.escapeShellArg containerName} -eo pid,comm \
              | awk '$2 == "wolf" { print $1; exit }'
          )"
          wolf_mib="$(
            ${nvidiaSmi} \
              --query-compute-apps=pid,used_memory \
              --format=csv,noheader,nounits \
              | awk -F, -v wolf_pid="$wolf_pid" '
                  {
                    gsub(/[[:space:]]/, "", $1)
                  }
                  $1 == wolf_pid {
                    gsub(/[[:space:]]/, "", $2)
                    total += $2
                  }
                  END { print total + 0 }
                '
          )"

          if ! [[ "$total_mib" =~ ^[1-9][0-9]*$ && "$wolf_mib" =~ ^[0-9]+$ ]]; then
            echo "Wolf VRAM watchdog could not parse the NVIDIA memory sample" >&2
            exit 1
          fi

          threshold_mib=$((total_mib * ${toString cfg.vramWatchdog.maxUsedPercent} / 100))
          if [ "$wolf_mib" -lt "$threshold_mib" ]; then
            rm -f "$state_file"
            exit 0
          fi

          count=0
          if [ -r "$state_file" ]; then
            read -r count < "$state_file" || count=0
          fi
          [[ "$count" =~ ^[0-9]+$ ]] || count=0
          count=$((count + 1))
          printf '%s\n' "$count" > "$state_file"

          if [ "$count" -lt ${toString cfg.vramWatchdog.consecutiveSamples} ]; then
            echo "Wolf VRAM remains high: $wolf_mib MiB of $total_mib MiB (sample $count/${toString cfg.vramWatchdog.consecutiveSamples})" >&2
            exit 0
          fi

          rm -f "$state_file"
          echo "Restarting Wolf after sustained VRAM growth: $wolf_mib MiB of $total_mib MiB" >&2
          systemctl restart ${lib.escapeShellArg serviceName}
      '';
    };
  mkWolfPipelineWatchdog = {
    name,
    containerName,
    serviceName,
    socketPath,
    stateDirectory,
    controlPort,
  }: let
    activeSessionCount =
      readPythonSource "wolf-active-session-count.py"
      ./active-session-count.py;
  in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.docker
        pkgs.gnugrep
        pkgs.iproute2
        pkgs.systemd
      ];
      text = ''
                state_dir=${lib.escapeShellArg stateDirectory}
                cursor_file="$state_dir/log-cursor"
                pending_file="$state_dir/recovery-pending"

        if ! systemctl --quiet is-active ${lib.escapeShellArg serviceName}; then
          exit 0
        fi
        if ! docker inspect ${lib.escapeShellArg containerName} >/dev/null 2>&1; then
          # The OCI unit becomes active just before `docker run` creates the
          # named container. The next timer tick will inspect the live service.
          exit 0
        fi

        now="$(date --iso-8601=seconds)"
                if [ -r "$cursor_file" ]; then
                  read -r since < "$cursor_file"
                else
                  since="$(docker inspect --format '{{.State.StartedAt}}' ${lib.escapeShellArg containerName})"
                fi
                printf '%s\n' "$now" > "$cursor_file"

                log_sample="$(mktemp)"
                trap 'rm -f "$log_sample"' EXIT
                docker logs --since "$since" ${lib.escapeShellArg containerName} > "$log_sample" 2>&1 || true

                # Both signatures leave Wolf running while its video path can no longer
                # produce frames.  They are deliberately narrower than generic
                # GStreamer warnings, which are common during normal disconnects.
                if grep -aEq \
                  'Failed to map input buffer|Unhandled exception: stoull' \
                  "$log_sample"; then
                  touch "$pending_file"
                fi

                if [ ! -e "$pending_file" ]; then
                  exit 0
                fi

                # Never destroy a healthy concurrent stream.  Once Moonlight has timed
                # out the poisoned stream, the API reports no active sessions and it is
                # safe to rebuild Wolf's coordinator and encoder state.  Persistent app
                # homes remain on disk; docker-wolf's pre-start removes only unusable
                # runner containers.
                if ! active_sessions="$(
                  docker exec -i ${lib.escapeShellArg containerName} \
                    python3 - ${lib.escapeShellArg socketPath} \
                    < ${activeSessionCount}
                )"; then
                  echo "Wolf pipeline recovery deferred: session API unavailable" >&2
                  exit 1
                fi

                if ! [[ "$active_sessions" =~ ^[0-9]+$ ]]; then
                  echo "Wolf pipeline recovery deferred: invalid session count" >&2
                  exit 1
                fi
                if [ "$active_sessions" -ne 0 ]; then
                  stale_control_connections="$(
                    ss -Hnt state close-wait ${lib.escapeShellArg "sport = :${toString controlPort}"} \
                      | wc -l \
                      | tr -d '[:space:]'
                  )"
                  [[ "$stale_control_connections" =~ ^[0-9]+$ ]] || stale_control_connections=0

                  # A poisoned coordinator can retain session records while leaking
                  # already-closed HTTP control connections. In that state, waiting for
                  # the API session count to reach zero can deadlock recovery forever.
                  # A deliberately high threshold distinguishes that failure from the
                  # handful of transient control requests seen during normal launches.
                  if [ "$stale_control_connections" -lt ${toString cfg.pipelineWatchdog.staleControlConnectionThreshold} ]; then
                    echo "Wolf pipeline recovery pending behind $active_sessions active session(s)" >&2
                    exit 0
                  fi

                  echo "Wolf pipeline recovery overriding $active_sessions stale session record(s) after detecting $stale_control_connections abandoned control connections" >&2
                fi

                echo "Restarting Wolf after an unrecoverable video-pipeline failure" >&2
                systemctl restart ${lib.escapeShellArg serviceName}
                rm -f "$pending_file"
      '';
    };
  wolfVramWatchdog = mkWolfVramWatchdog {
    name = "wolf-vram-watchdog";
    containerName = "wolf";
    serviceName = "docker-wolf.service";
    stateFile = "/run/wolf-streaming/vram-high-count";
  };
  protectedWolfVramWatchdog = mkWolfVramWatchdog {
    name = "wolf-protected-vram-watchdog";
    containerName = "wolf-protected";
    serviceName = "docker-wolf-protected.service";
    stateFile = "/run/wolf-streaming/protected-vram-high-count";
  };
  wolfPipelineWatchdog = mkWolfPipelineWatchdog {
    name = "wolf-pipeline-watchdog";
    containerName = "wolf";
    serviceName = "docker-wolf.service";
    socketPath = "${publicRuntimeDirectory}/wolf.sock";
    stateDirectory = "/var/lib/wolf-pipeline-watchdog";
    controlPort = 47989;
  };
  protectedWolfPipelineWatchdog = mkWolfPipelineWatchdog {
    name = "wolf-protected-pipeline-watchdog";
    containerName = "wolf-protected";
    serviceName = "docker-wolf-protected.service";
    socketPath = "${protectedRuntimeDirectory}/wolf.sock";
    stateDirectory = "/var/lib/wolf-protected-pipeline-watchdog";
    controlPort = protectedPort 47989;
  };
in {
  config = lib.mkIf cfg.enable {
    systemd.services.wolf-vram-watchdog = lib.mkIf (cfg.vramWatchdog.enable && hostPublicCoordinator) {
      description = "Recover Wolf from sustained GPU-memory growth";
      after = ["docker-wolf.service"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe wolfVramWatchdog;
      };
    };

    systemd.timers.wolf-vram-watchdog = lib.mkIf (cfg.vramWatchdog.enable && hostPublicCoordinator) {
      description = "Periodically check Wolf GPU-memory usage";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = cfg.vramWatchdog.interval;
        OnUnitActiveSec = cfg.vramWatchdog.interval;
        Unit = "wolf-vram-watchdog.service";
      };
    };

    systemd.services.wolf-protected-vram-watchdog =
      lib.mkIf (cfg.vramWatchdog.enable && isolatedProtectedBackend)
      {
        description = "Recover protected Wolf from sustained GPU-memory growth";
        after = ["docker-wolf-protected.service"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe protectedWolfVramWatchdog;
        };
      };

    systemd.timers.wolf-protected-vram-watchdog =
      lib.mkIf (cfg.vramWatchdog.enable && isolatedProtectedBackend)
      {
        description = "Periodically check protected Wolf GPU-memory usage";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = cfg.vramWatchdog.interval;
          OnUnitActiveSec = cfg.vramWatchdog.interval;
          Unit = "wolf-protected-vram-watchdog.service";
        };
      };

    systemd.services.wolf-pipeline-watchdog = lib.mkIf (cfg.pipelineWatchdog.enable && hostPublicCoordinator) {
      description = "Recover Wolf from fatal video-pipeline failures";
      after = ["docker-wolf.service"];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "wolf-pipeline-watchdog";
        ExecStart = lib.getExe wolfPipelineWatchdog;
      };
    };

    systemd.timers.wolf-pipeline-watchdog = lib.mkIf (cfg.pipelineWatchdog.enable && hostPublicCoordinator) {
      description = "Periodically check Wolf video-pipeline health";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = cfg.pipelineWatchdog.interval;
        OnUnitActiveSec = cfg.pipelineWatchdog.interval;
        Unit = "wolf-pipeline-watchdog.service";
      };
    };

    systemd.services.wolf-protected-pipeline-watchdog =
      lib.mkIf (cfg.pipelineWatchdog.enable && isolatedProtectedBackend)
      {
        description = "Recover protected Wolf from fatal video-pipeline failures";
        after = ["docker-wolf-protected.service"];
        serviceConfig = {
          Type = "oneshot";
          StateDirectory = "wolf-protected-pipeline-watchdog";
          ExecStart = lib.getExe protectedWolfPipelineWatchdog;
        };
      };

    systemd.timers.wolf-protected-pipeline-watchdog =
      lib.mkIf (cfg.pipelineWatchdog.enable && isolatedProtectedBackend)
      {
        description = "Periodically check protected Wolf video-pipeline health";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = cfg.pipelineWatchdog.interval;
          OnUnitActiveSec = cfg.pipelineWatchdog.interval;
          Unit = "wolf-protected-pipeline-watchdog.service";
        };
      };
  };
}
