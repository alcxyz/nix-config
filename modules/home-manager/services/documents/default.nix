# modules/home-manager/services/documents/default.nix
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.documents;

  organizerScript = pkgs.writeShellApplication {
    name = "documents-organizer";
    runtimeInputs = [ pkgs.inotify-tools pkgs.coreutils pkgs.libnotify ];
    text = ''
      DOCUMENTS_DIR="$1"

      echo "documents-organizer: watching $DOCUMENTS_DIR"

      inotifywait -m -e close_write,moved_to \
        --format '%f' \
        "$DOCUMENTS_DIR" \
      | while IFS= read -r filename; do
          filepath="$DOCUMENTS_DIR/$filename"

          # Skip directories
          if [ -d "$filepath" ]; then
            continue
          fi

          # Skip if file no longer exists
          if [ ! -f "$filepath" ]; then
            continue
          fi

          # Skip dotfiles and empty files
          if [ "''${filename:0:1}" = "." ] || [ ! -s "$filepath" ]; then
            continue
          fi

          # Get lowercase extension
          ext="''${filename##*.}"
          ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"

          # If no extension (no dot, or dot is first char), treat as misc
          basename_noext="''${filename%.*}"
          if [ "$basename_noext" = "$filename" ] || [ -z "$ext" ]; then
            ext=""
          fi

          # Determine bucket
          case "$ext" in
            pdf)
              bucket="pdf"
              ;;
            jpg|jpeg|png|gif|webp|tiff|tif)
              bucket="images"
              ;;
            docx|doc|odt|rtf)
              bucket="docx"
              ;;
            xlsx|xls|ods)
              bucket="xlsx"
              ;;
            *)
              bucket="misc"
              ;;
          esac

          # Get year and month from file modification time
          year="$(date -r "$filepath" +%Y)"
          month="$(date -r "$filepath" +%m)"

          dest_dir="$DOCUMENTS_DIR/$bucket/$year/$month"
          mkdir -p "$dest_dir"

          echo "documents-organizer: moving $filename -> $bucket/$year/$month/"
          mv "$filepath" "$dest_dir/$filename"
          notify-send -a "Documents" "Sorted" "$filename → $bucket/$year/$month/"
        done
    '';
  };

  ingestScript = pkgs.writeShellApplication {
    name = "documents-ingest";
    runtimeInputs = [ pkgs.inotify-tools pkgs.coreutils pkgs.libnotify ];
    text = ''
      DOCUMENTS_DIR="$1"
      INGEST_DIR="$2"

      echo "documents-ingest: watching $DOCUMENTS_DIR recursively, ingesting to $INGEST_DIR"

      inotifywait -m -r -e close_write,moved_to \
        --format '%w%f' \
        "$DOCUMENTS_DIR" \
      | while IFS= read -r filepath; do

          # Skip directories
          if [ -d "$filepath" ]; then
            continue
          fi

          # Skip if file no longer exists
          if [ ! -f "$filepath" ]; then
            continue
          fi

          filename="$(basename "$filepath")"

          # Get lowercase extension
          ext="''${filename##*.}"
          ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"

          # If no extension, skip
          basename_noext="''${filename%.*}"
          if [ "$basename_noext" = "$filename" ] || [ -z "$ext" ]; then
            continue
          fi

          # Only proceed for ingest-eligible extensions
          case "$ext" in
            pdf|jpg|jpeg|png|gif|webp|tiff|tif|docx|odt|xlsx)
              ;;
            *)
              continue
              ;;
          esac

          # Skip files in /misc/ subtree
          if printf '%s' "$filepath" | grep -q '/misc/'; then
            continue
          fi

          # Get relative path from documentsDir
          rel_path="''${filepath#"$DOCUMENTS_DIR"/}"
          rel_dir="$(dirname "$rel_path")"

          # Create destination directory preserving relative path
          dest_dir="$INGEST_DIR/$rel_dir"
          mkdir -p "$dest_dir"

          echo "documents-ingest: copying $rel_path -> $INGEST_DIR/$rel_dir/"
          cp "$filepath" "$dest_dir/$filename"
          notify-send -a "Paperless" "Ingesting" "$rel_path"
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
      description = "Path to the documents directory to watch and organise";
    };

    ingestDir = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/paperless-ingest";
      description = "Path to the Paperless ingest directory";
    };
  };

  config = mkIf cfg.enable {
    systemd.user.tmpfiles.rules = [
      "d ${cfg.ingestDir} 0755 - - -"
    ];

    systemd.user.services = {
      documents-organizer = {
        Unit = {
          Description = "Watch Documents root and sort files into typed subdirectories";
        };
        Service = {
          Type = "simple";
          ExecStart = "${organizerScript}/bin/documents-organizer ${cfg.documentsDir}";
          Restart = "on-failure";
          RestartSec = "5s";
          StandardOutput = "journal";
          StandardError = "journal";
        };
        Install.WantedBy = [ "default.target" ];
      };

      documents-ingest = {
        Unit = {
          Description = "Watch Documents recursively and copy ingest-eligible files to Paperless";
        };
        Service = {
          Type = "simple";
          ExecStart = "${ingestScript}/bin/documents-ingest ${cfg.documentsDir} ${cfg.ingestDir}";
          Restart = "on-failure";
          RestartSec = "5s";
          StandardOutput = "journal";
          StandardError = "journal";
        };
        Install.WantedBy = [ "default.target" ];
      };
    };
  };
}
