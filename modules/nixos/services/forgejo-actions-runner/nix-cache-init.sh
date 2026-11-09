# Create the bind sources of a fresh CI Nix store (ADR-0109): an empty
# store and an empty, valid database snapshot. Runs as the filler, with the
# filler's Nix configuration in the environment.
#
# Usage: forgejo-nix-cache-init ROOT
root=$1
mkdir -p -- "$root/nix/store" "$root/job"
if [[ ! -e $root/job/db && ! -L $root/job/db ]]; then
  scratch=$(mktemp -d)
  trap 'rm -rf -- "$scratch"' EXIT
  HOME=$scratch nix path-info --store "local?root=$scratch/root" --all >/dev/null
  mkdir -p -- "$root/job/db.0"
  sqlite3 "$scratch/root/nix/var/nix/db/db.sqlite" "VACUUM INTO '$root/job/db.0/db.sqlite'"
  cp -- "$scratch/root/nix/var/nix/db/schema" "$root/job/db.0/schema"
  ln -sfn -- db.0 "$root/job/db"
fi
