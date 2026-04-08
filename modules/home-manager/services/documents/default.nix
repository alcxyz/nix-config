# modules/home-manager/services/documents/default.nix
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.documents;
  isDarwin = pkgs.stdenv.isDarwin;

  # Shared bucket logic as a shell function
  bucketFunction = ''
    get_bucket() {
      local ext="$1"
      case "$ext" in
        pdf) echo "pdf" ;;
        jpg|jpeg|png|gif|webp|tiff|tif) echo "images" ;;
        docx|doc|odt|rtf) echo "docx" ;;
        xlsx|xls|ods) echo "xlsx" ;;
        *) echo "misc" ;;
      esac
    }

    is_ingestible() {
      local ext="$1"
      case "$ext" in
        pdf|jpg|jpeg|png|gif|webp|tiff|tif|docx|odt|xlsx) return 0 ;;
        *) return 1 ;;
      esac
    }
  '';

  # --- Organizer scripts (platform-specific watcher, shared sort logic) ---

  organizerScriptLinux = pkgs.writeShellApplication {
    name = "documents-organizer";
    runtimeInputs = [ pkgs.inotify-tools pkgs.coreutils pkgs.libnotify ];
    text = ''
      DOCUMENTS_DIR="$1"
      INGEST_DIR="$2"

      ${bucketFunction}

      echo "documents-organizer: watching $DOCUMENTS_DIR"

      flush_batch() {
        if [ "''${#sorted_batch[@]}" -eq 0 ]; then return; fi
        local count="''${#sorted_batch[@]}"
        if [ "$count" -eq 1 ]; then
          notify-send -a "Documents" "Sorted" "''${sorted_batch[0]}"
        else
          notify-send -a "Documents" "Sorted $count files" "$(printf '%s\n' "''${sorted_batch[@]}")"
        fi
        sorted_batch=()
      }

      sorted_batch=()

      inotifywait -m -e close_write,moved_to \
        --format '%f' \
        "$DOCUMENTS_DIR" \
      | {
        while true; do
          if IFS= read -r -t 3 filename; then
            filepath="$DOCUMENTS_DIR/$filename"

            [ -d "$filepath" ] && continue
            [ ! -f "$filepath" ] && continue
            [ "''${filename:0:1}" = "." ] || [ ! -s "$filepath" ] && continue

            ext="''${filename##*.}"
            ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
            basename_noext="''${filename%.*}"
            if [ "$basename_noext" = "$filename" ] || [ -z "$ext" ]; then
              ext=""
            fi

            bucket="$(get_bucket "$ext")"
            year="$(date -r "$filepath" +%Y)"
            month="$(date -r "$filepath" +%m)"

            dest_dir="$DOCUMENTS_DIR/$bucket/$year/$month"
            mkdir -p "$dest_dir"

            dest="$dest_dir/$filename"
            if [ -e "$dest" ]; then
              stamp="$(date +%s)"
              if [ -n "$ext" ]; then
                dest="$dest_dir/''${basename_noext}_$stamp.$ext"
                filename="''${basename_noext}_$stamp.$ext"
              else
                dest="$dest_dir/''${filename}_$stamp"
                filename="''${filename}_$stamp"
              fi
            fi

            echo "documents-organizer: moving $filename -> $bucket/$year/$month/"
            mv "$filepath" "$dest"
            sorted_batch+=("$filename → $bucket/$year/$month/")

            if is_ingestible "$ext"; then
              mkdir -p "$INGEST_DIR"
              ingest_dest="$INGEST_DIR/$filename"
              if [ -e "$ingest_dest" ]; then
                stamp="$(date +%s)"
                ingest_dest="$INGEST_DIR/''${basename_noext}_$stamp.$ext"
              fi
              cp "$dest" "$ingest_dest"
              echo "documents-organizer: queued $filename for Paperless ingest"
            fi
          else
            rc=$?
            flush_batch
            [ "$rc" -le 128 ] && break
          fi
        done
      }
    '';
  };

  organizerScriptDarwin = pkgs.writeShellApplication {
    name = "documents-organizer";
    runtimeInputs = [ pkgs.fswatch pkgs.coreutils ];
    text = ''
      DOCUMENTS_DIR="$1"

      ${bucketFunction}

      echo "documents-organizer: watching $DOCUMENTS_DIR"

      fswatch -0 --event Created --event Updated --event MovedTo \
        --exclude '.*/' \
        "$DOCUMENTS_DIR" \
      | while IFS= read -r -d "" filepath; do
          [ -d "$filepath" ] && continue
          [ ! -f "$filepath" ] && continue

          filename="$(basename "$filepath")"
          [ "''${filename:0:1}" = "." ] && continue
          [ ! -s "$filepath" ] && continue

          # Only process files at the root of Documents
          parent="$(dirname "$filepath")"
          if [ "$parent" != "$DOCUMENTS_DIR" ]; then
            continue
          fi

          ext="''${filename##*.}"
          ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
          basename_noext="''${filename%.*}"
          if [ "$basename_noext" = "$filename" ] || [ -z "$ext" ]; then
            ext=""
          fi

          bucket="$(get_bucket "$ext")"
          year="$(stat -f '%Sm' -t '%Y' "$filepath")"
          month="$(stat -f '%Sm' -t '%m' "$filepath")"

          dest_dir="$DOCUMENTS_DIR/$bucket/$year/$month"
          mkdir -p "$dest_dir"

          dest="$dest_dir/$filename"
          if [ -e "$dest" ]; then
            stamp="$(date +%s)"
            if [ -n "$ext" ]; then
              dest="$dest_dir/''${basename_noext}_$stamp.$ext"
              filename="''${basename_noext}_$stamp.$ext"
            else
              dest="$dest_dir/''${filename}_$stamp"
              filename="''${filename}_$stamp"
            fi
          fi

          echo "documents-organizer: moving $filename -> $bucket/$year/$month/"
          mv "$filepath" "$dest"
          osascript -e "display notification \"$filename → $bucket/$year/$month/\" with title \"Documents\" subtitle \"Sorted\""
        done
    '';
  };

  # --- Ingest scripts ---

  ingestScriptLinux = pkgs.writeShellApplication {
    name = "documents-ingest";
    runtimeInputs = [ pkgs.inotify-tools pkgs.coreutils pkgs.libnotify pkgs.gnugrep ];
    text = ''
      DOCUMENTS_DIR="$1"
      INGEST_DIR="$2"

      ${bucketFunction}

      echo "documents-ingest: watching $DOCUMENTS_DIR recursively, ingesting to $INGEST_DIR"

      flush_batch() {
        if [ "''${#ingest_batch[@]}" -eq 0 ]; then return; fi
        local count="''${#ingest_batch[@]}"
        if [ "$count" -eq 1 ]; then
          notify-send -a "Paperless" "Ingesting" "''${ingest_batch[0]}"
        else
          notify-send -a "Paperless" "Ingesting $count files" "$(printf '%s\n' "''${ingest_batch[@]}")"
        fi
        ingest_batch=()
      }

      ingest_batch=()

      inotifywait -m -r -e close_write,moved_to \
        --format '%w%f' \
        "$DOCUMENTS_DIR" \
      | {
        while true; do
          if IFS= read -r -t 3 filepath; then
            [ -d "$filepath" ] && continue
            [ ! -f "$filepath" ] && continue

            filename="$(basename "$filepath")"
            ext="''${filename##*.}"
            ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
            basename_noext="''${filename%.*}"
            if [ "$basename_noext" = "$filename" ] || [ -z "$ext" ]; then
              continue
            fi

            is_ingestible "$ext" || continue

            case "$filepath" in */misc/*) continue ;; esac

            rel_path="''${filepath#"$DOCUMENTS_DIR"/}"
            rel_dir="$(dirname "$rel_path")"
            dest_dir="$INGEST_DIR/$rel_dir"
            mkdir -p "$dest_dir"

            ingest_dest="$dest_dir/$filename"
            if [ -e "$ingest_dest" ]; then
              stamp="$(date +%s)"
              ingest_dest="$dest_dir/''${basename_noext}_$stamp.$ext"
            fi

            echo "documents-ingest: copying $rel_path -> $INGEST_DIR/$rel_dir/"
            cp "$filepath" "$ingest_dest"
            ingest_batch+=("$rel_path")
          else
            rc=$?
            flush_batch
            [ "$rc" -le 128 ] && break
          fi
        done
      }
    '';
  };

  ingestScriptDarwin = pkgs.writeShellApplication {
    name = "documents-ingest";
    runtimeInputs = [ pkgs.fswatch pkgs.coreutils pkgs.curl ];
    text = ''
      DOCUMENTS_DIR="$1"
      PAPERLESS_URL="$2"
      TOKEN_FILE="$3"

      ${bucketFunction}

      TOKEN="$(cat "$TOKEN_FILE")"

      echo "documents-ingest: watching $DOCUMENTS_DIR recursively, uploading to $PAPERLESS_URL"

      fswatch -0 -r --event Created --event Updated --event MovedTo \
        "$DOCUMENTS_DIR" \
      | while IFS= read -r -d "" filepath; do
          [ -d "$filepath" ] && continue
          [ ! -f "$filepath" ] && continue

          filename="$(basename "$filepath")"
          [ "''${filename:0:1}" = "." ] && continue

          ext="''${filename##*.}"
          ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
          basename_noext="''${filename%.*}"
          if [ "$basename_noext" = "$filename" ] || [ -z "$ext" ]; then
            continue
          fi

          is_ingestible "$ext" || continue

          case "$filepath" in */misc/*) continue ;; esac

          echo "documents-ingest: uploading $filename to Paperless"
          response="$(curl -s -w '%{http_code}' -o /dev/null \
            -X POST "$PAPERLESS_URL/api/documents/post_document/" \
            -H "Authorization: Token $TOKEN" \
            -F "document=@$filepath" \
            -F "title=$basename_noext")"

          if [ "$response" = "200" ]; then
            echo "documents-ingest: uploaded $filename"
            osascript -e "display notification \"$filename\" with title \"Paperless\" subtitle \"Uploaded\""
          else
            echo "documents-ingest: FAILED to upload $filename (HTTP $response)"
            osascript -e "display notification \"$filename (HTTP $response)\" with title \"Paperless\" subtitle \"Upload Failed\""
          fi
        done
    '';
  };

in
{
  options.services.documents = {
    enable = mkEnableOption "Documents organiser and Paperless ingest pipeline";

    documentsDir = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/Documents";
      description = "Path to the documents directory to watch and organise.";
    };

    ingestDir = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/paperless-ingest";
      description = "Path to the Paperless ingest directory (Linux only).";
    };

    paperlessUrl = mkOption {
      type = types.str;
      default = "";
      description = "Paperless-ngx base URL for API uploads (Darwin only).";
    };

    paperlessTokenFile = mkOption {
      type = types.str;
      default = "";
      description = "Path to file containing the Paperless API token (Darwin only).";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    # ---- Linux (systemd + inotifywait) ----
    (mkIf (!isDarwin) {
      systemd.user.tmpfiles.rules = [
        "d ${cfg.ingestDir} 0755 - - -"
      ];

      systemd.user.services = {
        documents-organizer = {
          Unit.Description = "Watch Documents root and sort files into typed subdirectories";
          Service = {
            Type = "simple";
            ExecStart = "${organizerScriptLinux}/bin/documents-organizer ${cfg.documentsDir} ${cfg.ingestDir}";
            Restart = "on-failure";
            RestartSec = "5s";
            StandardOutput = "journal";
            StandardError = "journal";
          };
          Install.WantedBy = [ "default.target" ];
        };

        documents-ingest = {
          Unit.Description = "Watch Documents recursively and copy ingest-eligible files to Paperless";
          Service = {
            Type = "simple";
            ExecStart = "${ingestScriptLinux}/bin/documents-ingest ${cfg.documentsDir} ${cfg.ingestDir}";
            Restart = "on-failure";
            RestartSec = "5s";
            StandardOutput = "journal";
            StandardError = "journal";
          };
          Install.WantedBy = [ "default.target" ];
        };
      };
    })

    # ---- Darwin (launchd + fswatch) ----
    (mkIf isDarwin {
      launchd.agents = {
        documents-organizer = {
          enable = true;
          config = {
            ProgramArguments = [
              "${organizerScriptDarwin}/bin/documents-organizer"
              cfg.documentsDir
            ];
            RunAtLoad = true;
            KeepAlive = true;
            StandardOutPath = "${config.home.homeDirectory}/Library/Logs/documents-organizer.log";
            StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/documents-organizer.log";
          };
        };

        documents-ingest = mkIf (cfg.paperlessUrl != "") {
          enable = true;
          config = {
            ProgramArguments = [
              "${ingestScriptDarwin}/bin/documents-ingest"
              cfg.documentsDir
              cfg.paperlessUrl
              cfg.paperlessTokenFile
            ];
            RunAtLoad = true;
            KeepAlive = true;
            StandardOutPath = "${config.home.homeDirectory}/Library/Logs/documents-ingest.log";
            StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/documents-ingest.log";
          };
        };
      };
    })
  ]);
}
